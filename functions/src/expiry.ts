/**
 * Chess Masters — scheduled expiry sweep.
 *
 * Some things, left alone, would sit forever and either clutter the UI or (worse)
 * keep a player's CP locked in escrow indefinitely:
 *
 *   1. PENDING OFFERS — a stake or challenge-up offer that's proposed but never
 *      accepted or declined. No CP is locked at propose time (locking happens at
 *      accept), so these just need to disappear. Pure cleanup, no refund.
 *
 *   2. WAITING-GAME NO-SHOWS — a pre-seated staked/conquest game that was accepted
 *      (so both stakes are LOCKED in escrow) but one player never readied up, so it
 *      never activated. Here CP IS escrowed, so expiring it must REFUND both stakers
 *      and release the game. This is the money-sensitive case.
 *
 * Mechanism: a single scheduled function (`onSchedule`, every 30 min) runs three
 * independent sweeps. Each item is handled in its OWN transaction with a status
 * re-check inside the tx, so:
 *   - a race (the offer gets accepted / the game gets readied between our query and
 *     our write) is safely skipped — we never expire something that just became live;
 *   - re-running the sweep can't double-refund (the status guard makes it idempotent);
 *   - refunds go through appendEntry, so the denormalized cp cache stays exactly in
 *     step with the ledger (the same invariant every other CP movement preserves).
 *
 * The ledger remains the source of truth; a refund is a normal positive entry
 * (`stake_return`), so conservation holds: locked CP simply comes back to its owner.
 */

import * as functions from "firebase-functions/v1";
import { FieldValue, Timestamp, Transaction } from "firebase-admin/firestore";

import { db } from "./init";
import { appendEntry } from "./ledger";
import { deleteOfferNotifications } from "./notify";

// ---- Dials ----------------------------------------------------------------

/**
 * Uniform expiry window: anything still pending/waiting older than this is swept.
 * 12 hours (locked V1 design). A single window for both offers and no-show games
 * keeps the rule simple and predictable for players ("offers last half a day").
 */
const EXPIRY_WINDOW_MS = 12 * 60 * 60 * 1000;

/**
 * SEPARATE, SHORTER window for OPEN LOBBY SEATS. A public lobby seat is unlike a
 * directed offer: if nobody grabs it within a short window the poster has almost
 * certainly moved on, and a lobby full of hours-old seats is bad UX (people tap
 * Join on seats whose poster is long gone). 30 minutes keeps the lobby fresh.
 * Lobby seats lock no CP, so a short window costs the poster nothing.
 *
 * ── TESTING: to watch a seat expire without waiting 30 min, temporarily set
 *    this to e.g. 60 * 1000 (1 min), rebuild, and run the sweep. RESTORE to
 *    30 * 60 * 1000 before launch. ──
 */
const LOBBY_SEAT_WINDOW_MS = 30 * 60 * 1000;

/** How many docs one sweep processes per run. A safety bound so a backlog can't
 * blow up a single invocation; the next scheduled run picks up the remainder.
 */
const SWEEP_BATCH_LIMIT = 200;

/** A Firestore Timestamp cutoff: items created at/before this are expired. */
function cutoffTs(): Timestamp {
  return Timestamp.fromMillis(Date.now() - EXPIRY_WINDOW_MS);
}

/** Cutoff for open lobby seats (uses the shorter lobby-specific window). */
function lobbyCutoffTs(): Timestamp {
  return Timestamp.fromMillis(Date.now() - LOBBY_SEAT_WINDOW_MS);
}

// ---- Sweep 1: pending offers (issuer leg locked → refund) -----------------

/**
 * Expire stale PENDING offers in the `stakes` collection (covers both peer stake
 * offers and challenge-up offers — both live in `stakes` with status "pending").
 * Under Option 3 the ISSUER's leg is LOCKED at propose, so expiring a
 * pending offer must REFUND that leg (peer: `amount`; challenge-up: `issuerStake`).
 * The opponent never locked anything on a pending offer, so there's only ever the
 * one issuer leg to return. Marks the offer "expired" and clears its notifications.
 *
 * Returns the count expired (for logging).
 */
async function sweepPendingOffers(): Promise<number> {
  const snap = await db
    .collection("stakes")
    .where("status", "==", "pending")
    .where("createdAt", "<=", cutoffTs())
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  let expired = 0;
  for (const doc of snap.docs) {
    try {
      const did = await db.runTransaction(async (tx: Transaction) => {
        const fresh = await tx.get(doc.ref);
        const s = fresh.data();
        // Re-check INSIDE the tx: it may have been accepted/declined/cancelled
        // in the gap between the query and now. Only expire if still pending.
        if (!s || s.status !== "pending") return false;

        // Refund the issuer's escrowed leg (idempotent: only if still locked).
        if (s.issuerLocked === true) {
          const issuerLeg: number =
            typeof s.issuerStake === "number" ? s.issuerStake : s.amount;
          if (typeof issuerLeg === "number" && issuerLeg > 0) {
            appendEntry(tx, {
              account: s.issuerId,
              amount: issuerLeg,
              type: "stake_return",
              meta: { stakeId: doc.id, outcome: "offer_expired", leg: "issuer" },
            });
          }
        }

        tx.update(doc.ref, {
          status: "expired",
          issuerLocked: false,
          updatedAt: FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (did) {
        expired++;
        // Best-effort notification cleanup (outside the money path).
        try {
          await deleteOfferNotifications(doc.id);
        } catch (e) {
          console.error("[expiry] offer notif cleanup failed", doc.id, e);
        }
      }
    } catch (e) {
      console.error("[expiry] failed to expire offer", doc.id, e);
    }
  }
  return expired;
}

// ---- Sweep 3: waiting-game no-shows (CP locked → refund) -------------------

/**
 * Expire pre-seated WAITING games that never activated (a player never readied
 * within the window). These had both stakes LOCKED at accept time, so we refund
 * each staker exactly what they locked, mark the stake settled ("expired"), and
 * mark the game abandoned. Casual waiting games (blackId null, no stake) are left
 * to a separate, refund-free cleanup (see sweepStaleCasualGames).
 *
 * Refund amounts come from the STAKE doc (issuerStake / opponentStake), so this is
 * correct for both two-sided stakes (peer / challenge-up: both staked) and
 * one-sided stakes (breach / gauntlet: only the issuer staked, opponentStake 0).
 */
async function sweepWaitingNoShows(): Promise<number> {
  const snap = await db
    .collection("games")
    .where("status", "==", "waiting")
    .where("createdAt", "<=", cutoffTs())
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  let expired = 0;
  for (const doc of snap.docs) {
    const g = doc.data();
    // Only PRE-SEATED staked games escrow CP. Casual (blackId null / gameType
    // casual) waiting games have no stake — handled separately, no refund.
    if (!g || g.blackId == null || g.gameType === "casual") continue;
    const contextId: string | null = g.contextId ?? null;
    if (typeof contextId !== "string") {
      // A pre-seated game with no stake link shouldn't happen, but if it does,
      // don't guess — just abandon the game, refund nothing, and log it.
      try {
        await db.runTransaction(async (tx: Transaction) => {
          const fresh = await tx.get(doc.ref);
          const gg = fresh.data();
          if (!gg || gg.status !== "waiting") return;
          tx.update(doc.ref, {
            status: "finished",
            result: null,
            resultReason: "abandon",
            updatedAt: FieldValue.serverTimestamp(),
          });
        });
      } catch (e) {
        console.error("[expiry] abandon (no stake link) failed", doc.id, e);
      }
      continue;
    }

    try {
      const did = await db.runTransaction(async (tx: Transaction) => {
        // Read game + stake together; re-check status inside the tx.
        const gameSnap = await tx.get(doc.ref);
        const gg = gameSnap.data();
        if (!gg || gg.status !== "waiting") return false; // readied/expired meanwhile

        const stakeRef = db.collection("stakes").doc(contextId);
        const stakeSnap = await tx.get(stakeRef);
        const s = stakeSnap.data();

        // Refund only if the stake is still LOCKED (idempotency: a prior sweep or
        // a settle path may already have released it). If it's already settled,
        // we still release the game but refund nothing.
        const stakeLocked = !!s && s.status === "locked" && s.settled !== true;

        if (stakeLocked) {
          const issuerId: string = s!.issuerId;
          const opponentId: string = s!.opponentId;
          const issuerStake: number =
            typeof s!.issuerStake === "number" ? s!.issuerStake : 0;
          const opponentStake: number =
            typeof s!.opponentStake === "number" ? s!.opponentStake : 0;

          // Return exactly what each side locked (one-sided stakes have a 0 leg).
          if (issuerStake > 0) {
            appendEntry(tx, {
              account: issuerId,
              amount: issuerStake,
              type: "stake_return",
              gameId: doc.id,
              meta: { stakeId: contextId, outcome: "expired_no_show" },
            });
          }
          if (opponentStake > 0) {
            appendEntry(tx, {
              account: opponentId,
              amount: opponentStake,
              type: "stake_return",
              gameId: doc.id,
              meta: { stakeId: contextId, outcome: "expired_no_show" },
            });
          }

          tx.update(stakeRef, {
            status: "settled",
            settled: true,
            settledResult: "expired",
            updatedAt: FieldValue.serverTimestamp(),
          });
        }

        // Release the game either way.
        tx.update(doc.ref, {
          status: "finished",
          result: null,
          resultReason: "abandon",
          updatedAt: FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (did) expired++;
    } catch (e) {
      console.error("[expiry] failed to expire waiting game", doc.id, e);
    }
  }
  return expired;
}

// ---- Sweep 4: stale casual waiting games (no stake → cleanup only) ---------

/**
 * Casual quick-match games that sat waiting for an opponent past the window.
 * No CP is involved (blackId null, no stake), so this is pure cleanup: mark the
 * game abandoned so it stops showing as an open waiting game.
 */
async function sweepStaleCasualGames(): Promise<number> {
  const snap = await db
    .collection("games")
    .where("status", "==", "waiting")
    .where("gameType", "==", "casual")
    .where("createdAt", "<=", cutoffTs())
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  let expired = 0;
  for (const doc of snap.docs) {
    try {
      const did = await db.runTransaction(async (tx: Transaction) => {
        const fresh = await tx.get(doc.ref);
        const g = fresh.data();
        if (!g || g.status !== "waiting") return false;
        tx.update(doc.ref, {
          status: "finished",
          result: null,
          resultReason: "abandon",
          updatedAt: FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (did) expired++;
    } catch (e) {
      console.error("[expiry] failed to expire casual game", doc.id, e);
    }
  }
  return expired;
}

// ---- Sweep 4: stale breach_pending conquests (challenger leg locked) -------

/**
 * A breach is UNCANCELLABLE by design — once a challenger locks a breach stake
 * and the conquest enters `breach_pending`, they can't retract it. The safety
 * valve is here: if NO circle member accepts the defense within the window, this
 * sweep refunds the challenger's breach stake and closes the conquest, releasing
 * the per-circle breach lock (the lock is just "is there a conquest in an active
 * status for this circle", so moving to the terminal `force_closed` clears it).
 *
 * The breach stake is ONE-SIDED (only the challenger's `issuerStake` is locked;
 * the defender never staked — there is no defender yet), so we refund exactly
 * that one leg. Per-doc transaction with a status re-check makes it safe against
 * a defender accepting in the gap (we skip if it's no longer breach_pending) and
 * idempotent (skip if the stake is already settled).
 */
async function sweepStaleBreaches(): Promise<number> {
  const snap = await db
    .collection("conquests")
    .where("status", "==", "breach_pending")
    .where("createdAt", "<=", cutoffTs())
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  let expired = 0;
  for (const doc of snap.docs) {
    const q = doc.data();
    const breachStakeId: string | null = q?.breachStakeId ?? null;
    try {
      const did = await db.runTransaction(async (tx: Transaction) => {
        const fresh = await tx.get(doc.ref);
        const qq = fresh.data();
        // Re-check inside the tx: a defender may have accepted in the gap.
        if (!qq || qq.status !== "breach_pending") return false;

        if (typeof breachStakeId === "string") {
          const stakeRef = db.collection("stakes").doc(breachStakeId);
          const stakeSnap = await tx.get(stakeRef);
          const s = stakeSnap.data();
          // Refund only if still locked (idempotency).
          if (s && s.status === "locked" && s.settled !== true) {
            const challengerId: string = s.issuerId;
            const issuerStake: number =
              typeof s.issuerStake === "number" ? s.issuerStake : 0;
            if (issuerStake > 0) {
              appendEntry(tx, {
                account: challengerId,
                amount: issuerStake,
                type: "stake_return",
                meta: {
                  stakeId: breachStakeId,
                  kind: "breach",
                  outcome: "breach_expired_no_defender",
                },
              });
            }
            tx.update(stakeRef, {
              status: "settled",
              settled: true,
              settledResult: "expired",
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        }

        // Close the conquest → releases the per-circle breach lock.
        tx.update(doc.ref, {
          status: "force_closed",
          updatedAt: FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (did) expired++;
    } catch (e) {
      console.error("[expiry] failed to expire breach_pending", doc.id, e);
    }
  }
  return expired;
}

// ---- Sweep 5: stale open lobby seats (nothing locked → cleanup only) -------

/**
 * Open lobby seats (kind "outside", status "open") that nobody accepted within
 * the window. A seat locks NO CP at post (Resolution C — the asymmetric stake
 * isn't known until accepted), so this is pure cleanup: mark the seat "expired"
 * so it stops showing in the lobby. No refund. Per-doc tx with a status re-check
 * so a seat that gets accepted in the gap is skipped.
 */
async function sweepStaleLobbySeats(): Promise<number> {
  const snap = await db
    .collection("stakes")
    .where("kind", "==", "outside")
    .where("status", "==", "open")
    .where("createdAt", "<=", lobbyCutoffTs())
    .limit(SWEEP_BATCH_LIMIT)
    .get();

  let expired = 0;
  for (const doc of snap.docs) {
    try {
      const did = await db.runTransaction(async (tx: Transaction) => {
        const fresh = await tx.get(doc.ref);
        const s = fresh.data();
        if (!s || s.status !== "open") return false; // accepted/cancelled meanwhile
        tx.update(doc.ref, {
          status: "expired",
          updatedAt: FieldValue.serverTimestamp(),
        });
        return true;
      });
      if (did) expired++;
    } catch (e) {
      console.error("[expiry] failed to expire lobby seat", doc.id, e);
    }
  }
  return expired;
}

/**
 * Run all sweeps once. SHARED CORE: both the scheduled function and the
 * emulator-only test trigger call this, so testing exercises the real logic with
 * no divergence. Each sweep is independent and best-effort — a failure in one
 * doesn't abort the others.
 */
async function runAllSweeps(): Promise<{
  offers: number;
  noShows: number;
  casual: number;
  breaches: number;
  lobbySeats: number;
}> {
  const [offers, noShows, casual, breaches, lobbySeats] = await Promise.all([
    sweepPendingOffers().catch((e) => {
      console.error("[expiry] sweepPendingOffers threw", e);
      return 0;
    }),
    sweepWaitingNoShows().catch((e) => {
      console.error("[expiry] sweepWaitingNoShows threw", e);
      return 0;
    }),
    sweepStaleCasualGames().catch((e) => {
      console.error("[expiry] sweepStaleCasualGames threw", e);
      return 0;
    }),
    sweepStaleBreaches().catch((e) => {
      console.error("[expiry] sweepStaleBreaches threw", e);
      return 0;
    }),
    sweepStaleLobbySeats().catch((e) => {
      console.error("[expiry] sweepStaleLobbySeats threw", e);
      return 0;
    }),
  ]);
  console.log(
    `[expiry] swept: ${offers} offers, ${noShows} no-show staked games, ` +
      `${casual} casual waiting games, ${breaches} stale breaches, ` +
      `${lobbySeats} stale lobby seats`
  );
  return { offers, noShows, casual, breaches, lobbySeats };
}

/**
 * Runs every 10 minutes. The cron cadence + per-run batch limit means a backlog
 * drains across successive runs rather than in one long invocation.
 */
export const expireStaleItems = functions.pubsub
  .schedule("every 10 minutes")
  .onRun(async () => {
    await runAllSweeps();
    return null;
  });