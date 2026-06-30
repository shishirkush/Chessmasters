/**
 * Chess Masters — Slice 3c-1: within-circle peer staking (propose / accept).
 *
 * THE MODEL (locked V1 §5, with this session's decisions):
 *   - Peer staking is between two members of the SAME circle.
 *   - The issuer proposes an ABSOLUTE CP amount; the opponent accepts or
 *     declines. (Equal fixed CP from both — symmetric pot.)
 *   - At ACCEPT (not propose) we validate against LIVE balances: each player
 *     must hold the stake AND the stake must be ≤ 40% of each player's balance
 *     (the §5 hard cap, computed on current balance so it scales down as you
 *     lose).
 *   - Accepting LOCKS both stakes into escrow ATOMICALLY and creates an active
 *     game. CP leaves spendable the instant both are locked — no double-spend.
 *
 * WHY CP MOVES ONLY AT ACCEPT (not propose):
 *   A proposal is a free, cancellable invitation. Locking at propose would
 *   freeze the issuer's CP on an offer the opponent might never answer. Locking
 *   only at accept means CP leaves spendable exactly when a game is about to
 *   start, against balances that are current at that moment.
 *
 * ESCROW IN THE PURE-LEDGER MODEL:
 *   A lock is just a NEGATIVE ledger entry (type "stake_lock"). Balance = sum
 *   of entries, so the locked CP automatically leaves spendable. Settlement
 *   (3c-2) writes the compensating entries. Summing every ledger entry tagged
 *   with a stakeId nets to ZERO across the system — a staked game only MOVES
 *   CP (and drains rake to the sink); it never mints or destroys supply.
 *
 * ATOMICITY:
 *   acceptStake does everything in ONE transaction: read both balances, validate
 *   the cap, create the active game, write both lock entries, flip the stake to
 *   "locked". Any failure rolls the whole thing back — never a half-locked state.
 */

import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import {
  appendEntry,
  readCpInTx,
  settlePot,
  SINK_ACCOUNT,
  MIN_STAKE,
  MAX_STAKE_FRACTION,
} from "./ledger";
import {
  getCountsInTx,
  bumpOpponent,
  SAME_OPPONENT_DAILY_CAP,
} from "./counters";
import {
  challengeStakeAmount,
  lobbyAccepterStake,
  validateLobbyPosterStake,
  LOBBY_ACCEPTER_FLOOR,
} from "./challenge";

import { db } from "./init";
import { notify, notifyTx, deleteOfferNotifications } from "./notify";

// Game constants — must match the engine's fresh-game shape (index.ts).
const STARTING_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const INITIAL_MS = 5 * 60 * 1000; // 5+3 blitz, same as casual games

/**
 * Cap on how many pending offers (stakes + challenge-ups) one issuer can have
 * open at once. With issuer-locking (Option 3) exposure is already self-limiting
 * — each open offer locks CP, so you can't promise more than you hold — but a cap
 * still bounds doc/query growth and keeps one player from spamming the system.
 */
const MAX_OPEN_OFFERS = 10;

function requireAuth(context: functions.https.CallableContext): string {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be signed in."
    );
  }
  return context.auth.uid;
}

// ---- proposeStake ----------------------------------------------------------
/**
 * Issuer proposes a peer stake to a circle-mate. Writes a `pending` stake doc.
 * NO CP moves here. Cheap structural validation only — the balance/cap checks
 * happen at accept against live balances.
 */
export const proposeStake = functions.https.onCall(async (data, context) => {
  const issuerId = requireAuth(context);
  const opponentId: string | undefined = data?.opponentId;
  const circleId: string | undefined = data?.circleId;
  const amount: number | undefined = data?.amount;

  if (!opponentId || !circleId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "opponentId and circleId are required."
    );
  }
  if (opponentId === issuerId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "You can't stake against yourself."
    );
  }
  if (
    typeof amount !== "number" ||
    !Number.isInteger(amount) ||
    amount < MIN_STAKE
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Stake must be a whole number of at least ${MIN_STAKE} CP.`
    );
  }

  // Both players must be members of the circle (peer staking is within-circle).
  const circleSnap = await db.collection("circles").doc(circleId).get();
  if (!circleSnap.exists) {
    throw new functions.https.HttpsError("not-found", "Circle not found.");
  }
  const members: string[] = circleSnap.get("members") || [];
  if (!members.includes(issuerId) || !members.includes(opponentId)) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Both players must be members of this circle."
    );
  }

  // One pending proposal per (issuer, opponent) pair in this circle — avoid
  // duplicate offers stacking up. (Cheap pre-check outside the tx for a clear
  // early error; the authoritative dupe + count guard runs in the tx below.)
  const dupe = await db
    .collection("stakes")
    .where("circleId", "==", circleId)
    .where("issuerId", "==", issuerId)
    .where("opponentId", "==", opponentId)
    .where("status", "==", "pending")
    .limit(1)
    .get();
  if (!dupe.empty) {
    throw new functions.https.HttpsError(
      "already-exists",
      "You already have a pending stake offer to this player."
    );
  }

  // OPTION 3 — lock the issuer's CP at PROPOSE time (not accept). This makes
  // offered CP genuinely reserved: a player can never have more pending offers
  // than they can afford, and an accepted offer can't bounce on the issuer's
  // balance. The opponent's leg still locks at ACCEPT (they haven't consented
  // yet and may not have the CP). Refund paths: cancel / decline / expire.
  //
  // The whole thing must be ONE transaction: read the issuer's escrow-netted
  // balance, enforce the 40% cap and the open-offer cap, then lock + create
  // atomically — otherwise two concurrent proposes could both read the same
  // balance and over-lock.
  const stakeRef = db.collection("stakes").doc();
  await db.runTransaction(async (tx) => {
    // Live, escrow-netted balance (already reflects any CP locked by other open
    // offers / games). This is what makes over-promising structurally impossible.
    const issuerBal = await readCpInTx(tx, issuerId);

    // 40% cap against the CURRENT spendable balance.
    const issuerCap = Math.floor(issuerBal * MAX_STAKE_FRACTION);
    if (amount > issuerCap) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Stake exceeds ${Math.round(MAX_STAKE_FRACTION * 100)}% of your spendable balance. Your current max is ${issuerCap} CP.`
      );
    }
    // Affordability (redundant given the cap for amount>0, but explicit).
    if (issuerBal < amount) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You don't have enough spendable CP for this stake."
      );
    }

    // Open-offer cap: count this issuer's current pending offers in `stakes`.
    const openSnap = await tx.get(
      db
        .collection("stakes")
        .where("issuerId", "==", issuerId)
        .where("status", "==", "pending")
    );
    if (openSnap.size >= MAX_OPEN_OFFERS) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `You can have at most ${MAX_OPEN_OFFERS} open offers at once. ` +
          `Resolve some before making more.`
      );
    }

    // Lock the issuer's leg now — a negative ledger entry (cp cache decrements
    // through the appendEntry chokepoint, so spendable balance drops immediately).
    appendEntry(tx, {
      account: issuerId,
      amount: -amount,
      type: "stake_lock",
      meta: { stakeId: stakeRef.id, kind: "offer", leg: "issuer" },
    });

    // Create the offer, recording that the issuer's leg is locked. The opponent
    // leg locks at accept.
    tx.set(stakeRef, {
      issuerId,
      opponentId,
      circleId,
      amount, // the proposed absolute CP each side will stake
      status: "pending",
      issuerLocked: true, // OPTION 3: issuer's CP is held in escrow now
      gameId: null,
      pot: null,
      settledResult: null,
      settled: false,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  const ref = stakeRef;

  // Notify the opponent that they have a stake offer to accept/decline.
  await notify({
    recipientId: opponentId,
    type: "stake_offer",
    title: "New stake offer",
    body: `You've been offered a ${amount} CP stake game.`,
    data: { stakeId: ref.id, circleId, issuerId },
  });

  return { stakeId: ref.id };
});

// ---- cancelStake / declineStake -------------------------------------------
/** Issuer withdraws their own pending proposal. */
export const cancelStake = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const stakeId: string | undefined = data?.stakeId;
  if (!stakeId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "stakeId is required."
    );
  }
  const ref = db.collection("stakes").doc(stakeId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Stake not found.");
    }
    const s = snap.data()!;
    if (s.issuerId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Only the issuer can cancel this offer."
      );
    }
    if (s.status !== "pending") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Only a pending offer can be cancelled."
      );
    }
    // OPTION 3: refund the issuer's escrowed leg (locked at propose). The
    // locked amount differs by kind: peer stakes use `amount`; challenge-up
    // offers use the fixed `issuerStake`. Use whichever this offer carries.
    if (s.issuerLocked === true) {
      const issuerLeg: number =
        typeof s.issuerStake === "number" ? s.issuerStake : s.amount;
      if (typeof issuerLeg === "number" && issuerLeg > 0) {
        appendEntry(tx, {
          account: s.issuerId,
          amount: issuerLeg,
          type: "stake_return",
          meta: { stakeId, outcome: "offer_cancelled", leg: "issuer" },
        });
      }
    }
    tx.update(ref, {
      status: "cancelled",
      issuerLocked: false,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  await deleteOfferNotifications(stakeId);
  return { ok: true };
});

/** Opponent declines a pending proposal. */
export const declineStake = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const stakeId: string | undefined = data?.stakeId;
  if (!stakeId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "stakeId is required."
    );
  }
  const ref = db.collection("stakes").doc(stakeId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Stake not found.");
    }
    const s = snap.data()!;
    if (s.opponentId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Only the challenged player can decline."
      );
    }
    if (s.status !== "pending") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Only a pending offer can be declined."
      );
    }
    // OPTION 3: the opponent declined → refund the issuer's escrowed leg.
    // Peer stakes carry `amount`; challenge-up offers carry `issuerStake`.
    if (s.issuerLocked === true) {
      const issuerLeg: number =
        typeof s.issuerStake === "number" ? s.issuerStake : s.amount;
      if (typeof issuerLeg === "number" && issuerLeg > 0) {
        appendEntry(tx, {
          account: s.issuerId,
          amount: issuerLeg,
          type: "stake_return",
          meta: { stakeId, outcome: "offer_declined", leg: "issuer" },
        });
      }
    }
    tx.update(ref, {
      status: "declined",
      issuerLocked: false,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  // The offer is resolved → remove its now-stale notification.
  await deleteOfferNotifications(stakeId);
  return { ok: true };
});

// ---- acceptStake (THE critical transaction) -------------------------------
/**
 * Opponent accepts. In ONE transaction: validate both live balances against
 * the 40% cap, lock both stakes (negative ledger entries), create an ACTIVE
 * game wired to the engine, and flip the stake to "locked". All-or-nothing.
 */
export const acceptStake = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const stakeId: string | undefined = data?.stakeId;
  if (!stakeId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "stakeId is required."
    );
  }

  const stakeRef = db.collection("stakes").doc(stakeId);

  const result = await db.runTransaction(async (tx) => {
    // ---- READS FIRST (Firestore requires all reads before writes) ----
    const snap = await tx.get(stakeRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Stake not found.");
    }
    const s = snap.data()!;
    if (s.status !== "pending") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This stake offer is no longer open."
      );
    }
    if (s.opponentId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Only the challenged player can accept."
      );
    }

    const issuerId: string = s.issuerId;
    const opponentId: string = s.opponentId;
    const amount: number = s.amount;

    // OPTION 3: the issuer's leg was locked at PROPOSE time. Here we only need
    // to validate and lock the OPPONENT's leg. (Guard against an offer that
    // somehow lacks the issuer lock — pre-Option-3 data — so we never create a
    // half-funded game.)
    if (s.issuerLocked !== true) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This offer is missing its issuer escrow and can't be accepted."
      );
    }

    // Live, transaction-consistent spendable balance for the OPPONENT.
    const opponentBal = await readCpInTx(tx, opponentId);

    // Anti-collusion cap: ≤3 games/day vs the same opponent (any game type).
    const issuerCounts = await getCountsInTx(tx, issuerId);
    const opponentCounts = await getCountsInTx(tx, opponentId);
    if ((issuerCounts.opponentCounts[opponentId] || 0) >= SAME_OPPONENT_DAILY_CAP ||
        (opponentCounts.opponentCounts[issuerId] || 0) >= SAME_OPPONENT_DAILY_CAP) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `Daily limit reached against this opponent (${SAME_OPPONENT_DAILY_CAP}/day).`
      );
    }

    // Validate the §5 cap against the OPPONENT's current balance only.
    if (opponentBal < amount) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You don't have enough CP for this stake."
      );
    }
    if (amount > Math.floor(opponentBal * MAX_STAKE_FRACTION)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Stake exceeds ${Math.round(MAX_STAKE_FRACTION * 100)}% of your balance.`
      );
    }

    // ---- WRITES ----
    // Coin-flip colors for fairness.
    const issuerIsWhite = Math.random() < 0.5;
    const whiteId = issuerIsWhite ? issuerId : opponentId;
    const blackId = issuerIsWhite ? opponentId : issuerId;

    // Create the game in the READY-GATE waiting state. Both players are known
    // at accept, but the clock must NOT start until BOTH have arrived at the
    // board (markReady). Shape matches the engine; gameType "peer", contextId =
    // stakeId so settlement (3c-2) can find the stake from the finished game.
    // Stakes lock NOW (at accept); the clock waits for both players.
    const gameRef = db.collection("games").doc();
    tx.set(gameRef, {
      status: "waiting",
      gameType: "peer",
      contextId: stakeId,
      fen: STARTING_FEN,
      moves: [],
      turn: "w",
      whiteId,
      blackId,
      players: [whiteId, blackId],
      ready: [], // ready-gate: both must markReady before the clock starts
      whiteMs: INITIAL_MS,
      blackMs: INITIAL_MS,
      lastMoveAt: null, // frozen until both players ready up
      result: null,
      resultReason: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Lock the OPPONENT's stake — negative ledger entry. The ISSUER's leg is
    // already locked (from propose), so we don't lock it again here; doing so
    // would double-charge the issuer. The offer's escrow `meta.kind:"offer"`
    // issuer lock now becomes part of this game's pot.
    appendEntry(tx, {
      account: opponentId,
      amount: -amount,
      type: "stake_lock",
      gameId: gameRef.id,
      meta: { stakeId, leg: "opponent" },
    });

    // Flip the stake to locked, record the resolved amounts + game link.
    tx.update(stakeRef, {
      status: "locked",
      issuerStake: amount,
      opponentStake: amount,
      pot: amount * 2,
      gameId: gameRef.id,
      whiteId,
      blackId,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Count this game toward the same-opponent cap for BOTH players.
    bumpOpponent(tx, issuerId, opponentId);
    bumpOpponent(tx, opponentId, issuerId);

    // Tell the proposer their offer was accepted, and tell BOTH players the
    // game is waiting for them to ready up (the global banner also surfaces
    // this, but a notification persists in the bell/center).
    notifyTx(tx, {
      recipientId: issuerId,
      type: "stake_accepted",
      title: "Stake accepted",
      body: "Your stake offer was accepted. Enter to start the game.",
      data: { stakeId, gameId: gameRef.id },
    });
    notifyTx(tx, {
      recipientId: issuerId,
      type: "game_ready",
      title: "Game ready to start",
      body: "Enter the board to start your staked game.",
      data: { gameId: gameRef.id },
    });
    notifyTx(tx, {
      recipientId: opponentId,
      type: "game_ready",
      title: "Game ready to start",
      body: "Enter the board to start your staked game.",
      data: { gameId: gameRef.id },
    });

    return { gameId: gameRef.id };
  });

  // Offer resolved (accepted) → remove the now-stale stake_offer notification.
  await deleteOfferNotifications(stakeId);

  return result;
});

// ---- settleStakeForGame (3c-2: the payout) --------------------------------
/**
 * Settle the peer stake attached to a finished game. Called from
 * onGameFinished for games whose gameType is "peer". Idempotent via the
 * stake's `settled` flag, set inside the settlement transaction — a stake pays
 * out EXACTLY once no matter how many times the trigger fires.
 *
 * THE PAYOUT (conservation-exact, all integers):
 *   Let pot = issuerStake + opponentStake. rake = round(pot * 5%).
 *   - Decisive: winner gets (pot - rake); sink gets rake.
 *   - Draw: each player gets back their stake minus their half of the rake;
 *           sink gets rake. (§21: draw returns stakes minus the normal rake.)
 *
 * The escrow locks (negative entries written at accept) already removed the
 * pot from circulation. These settlement entries put exactly `pot` back —
 * split between the winner (or both, on a draw) and the sink. Summing ALL
 * ledger entries tagged with this stakeId nets to zero: a staked game only
 * moves CP and drains the rake to the sink; supply is never minted or lost.
 *
 * @param result the game's final result: "white" | "black" | "draw"
 */
export async function settleStakeForGame(
  gameId: string,
  stakeId: string,
  result: string
): Promise<void> {
  const stakeRef = db.collection("stakes").doc(stakeId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(stakeRef);
    if (!snap.exists) {
      console.error("settleStake: stake not found", stakeId);
      return;
    }
    const s = snap.data()!;

    // Idempotency: settle exactly once.
    if (s.settled === true) return;
    // Only settle a locked stake whose game matches.
    if (s.status !== "locked") {
      console.error("settleStake: stake not in locked state", stakeId, s.status);
      return;
    }
    if (s.gameId !== gameId) {
      console.error("settleStake: gameId mismatch", stakeId, gameId, s.gameId);
      return;
    }

    const issuerId: string = s.issuerId;
    const opponentId: string = s.opponentId;
    const whiteId: string = s.whiteId;
    const blackId: string = s.blackId;
    const pot: number = s.pot;
    const issuerStake: number = s.issuerStake;
    const opponentStake: number = s.opponentStake;

    if (result === "draw") {
      // Return each player's OWN stake minus the rake. For asymmetric stakes
      // (challenge-up) the rake is split in proportion to each stake, floored
      // per player; any rounding residual lands in the sink so the books
      // reconcile exactly (refunds + sink == pot).
      const { rake } = settlePot(pot);
      const issuerRake = pot > 0 ? Math.floor((rake * issuerStake) / pot) : 0;
      const opponentRake = pot > 0 ? Math.floor((rake * opponentStake) / pot) : 0;
      const issuerRefund = issuerStake - issuerRake;
      const opponentRefund = opponentStake - opponentRake;
      // Residual (rounding) goes to the sink so refunds + sink == pot exactly.
      const sinkAmount = pot - issuerRefund - opponentRefund;

      appendEntry(tx, {
        account: issuerId,
        amount: issuerRefund,
        type: "stake_return",
        gameId,
        meta: { stakeId, outcome: "draw" },
      });
      appendEntry(tx, {
        account: opponentId,
        amount: opponentRefund,
        type: "stake_return",
        gameId,
        meta: { stakeId, outcome: "draw" },
      });
      appendEntry(tx, {
        account: SINK_ACCOUNT,
        amount: sinkAmount,
        type: "rake",
        gameId,
        meta: { stakeId, outcome: "draw" },
      });

      tx.update(stakeRef, {
        status: "settled",
        settled: true,
        settledResult: "draw",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    // Decisive: map white/black result to the winner uid.
    const winnerId = result === "white" ? whiteId : blackId;
    const { winnerCredit, rake } = settlePot(pot);

    appendEntry(tx, {
      account: winnerId,
      amount: winnerCredit,
      type: "pot_win",
      gameId,
      meta: { stakeId, outcome: "win" },
    });
    appendEntry(tx, {
      account: SINK_ACCOUNT,
      amount: rake,
      type: "rake",
      gameId,
      meta: { stakeId, outcome: "win" },
    });

    tx.update(stakeRef, {
      status: "settled",
      settled: true,
      settledResult: winnerId === issuerId ? "issuer" : "opponent",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

// ---- Outside match (challenge-up, asymmetric) -----------------------------
/**
 * Propose a challenge-up against ANY player (typically higher-rated, outside
 * your circle — the open ladder). Unlike peer staking (equal fixed CP), the
 * stakes are ASYMMETRIC: each player stakes their own challenge-up fraction of
 * their balance, computed from the rating gap.
 *
 * THE MODEL (per the firewall, §5):
 *   CP is the ENTRY FEE for a shot at a rating climb — not the prize. The
 *   underdog stakes a LARGE fraction (an improbable upset is an expensive
 *   ticket) to buy a chance at a big rating jump (the real reward). The
 *   favorite stakes a SMALL fraction and accepts for the CP (compensation for
 *   risking their rating). Transfer-only, rake to sink — never mints CP.
 *
 * Stakes are computed at ACCEPT against live balances/ratings (like peer
 * staking), so this just records the proposal.
 */
export const proposeChallengeUp = functions.https.onCall(
  async (data, context) => {
    const issuerId = requireAuth(context);
    const opponentId: string | undefined = data?.opponentId;
    // Optional: the circle the challenge was issued from. Stored so the
    // opponent's notification can deep-link to that circle's page to accept.
    const circleId: string | null = (data?.circleId as string) ?? null;
    if (!opponentId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "opponentId is required."
      );
    }
    if (opponentId === issuerId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "You can't challenge yourself."
      );
    }

    // Opponent must exist.
    const oppSnap = await db.collection("users").doc(opponentId).get();
    if (!oppSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Player not found.");
    }

    // Challenge-UP direction (design): the challenger must be LOWER-rated than
    // the opponent — it's a shot at climbing against a stronger player. Equal
    // or higher-rated challengers are rejected (use a peer stake instead).
    const issuerSnap = await db.collection("users").doc(issuerId).get();
    const issuerRating = (issuerSnap.get("rating") as number) ?? 1500;
    const issuerRd = (issuerSnap.get("rd") as number) ?? 350;
    const opponentRating = (oppSnap.get("rating") as number) ?? 1500;
    const opponentRd = (oppSnap.get("rd") as number) ?? 350;
    if (issuerRating >= opponentRating) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Challenge-up only works against a higher-rated player. " +
          "Use a peer stake for someone at or below your rating."
      );
    }

    // One pending challenge per (issuer, opponent) pair.
    const dupe = await db
      .collection("stakes")
      .where("issuerId", "==", issuerId)
      .where("opponentId", "==", opponentId)
      .where("kind", "==", "challenge_up")
      .where("status", "==", "pending")
      .limit(1)
      .get();
    if (!dupe.empty) {
      throw new functions.https.HttpsError(
        "already-exists",
        "You already have a pending challenge to this player."
      );
    }

    // OPTION 3 for challenge-up: COMPUTE & FIX both asymmetric stakes NOW (at
    // propose) from the current rating gap + balances, then LOCK the issuer's
    // fixed leg. The opponent sees concrete terms and accepts/declines; their
    // leg locks at accept. This makes challenge-up over-subscription impossible
    // (each open challenge reserves real CP) and gives the opponent an honest,
    // concrete offer instead of "accept to discover the stakes". If ratings
    // drift before accept, the FIXED terms stand — it's an offer, not a live
    // quote. All in ONE transaction so concurrent proposes can't over-lock.
    const stakeRef = db.collection("stakes").doc();
    await db.runTransaction(async (tx) => {
      const issuerBal = await readCpInTx(tx, issuerId);
      // Opponent's balance feeds the formula for THEIR fixed leg (the favorite's
      // smaller fraction). Read it here at propose so both terms are fixed now.
      const opponentBal = await readCpInTx(tx, opponentId);

      // Compute both legs against propose-time ratings/balances and FIX them.
      // Glicko-2 win-probability (RD-weighted) drives the fraction; we snapshot
      // rating+rd below so the fixed terms are auditable.
      const issuerStake = challengeStakeAmount(
        { rating: issuerRating, rd: issuerRd },
        { rating: opponentRating, rd: opponentRd },
        issuerBal
      );
      const opponentStake = challengeStakeAmount(
        { rating: opponentRating, rd: opponentRd },
        { rating: issuerRating, rd: issuerRd },
        opponentBal
      );
      if (issuerStake < MIN_STAKE || opponentStake < MIN_STAKE) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Both stakes must be at least ${MIN_STAKE} CP.`
        );
      }
      // The issuer must be able to cover their fixed leg right now.
      if (issuerBal < issuerStake) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You don't have enough spendable CP to back this challenge."
        );
      }

      // Open-offer cap spans BOTH peer + challenge-up pending offers.
      const openSnap = await tx.get(
        db
          .collection("stakes")
          .where("issuerId", "==", issuerId)
          .where("status", "==", "pending")
      );
      if (openSnap.size >= MAX_OPEN_OFFERS) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `You can have at most ${MAX_OPEN_OFFERS} open offers at once. ` +
            `Resolve some before making more.`
        );
      }

      // Lock the issuer's fixed leg now.
      appendEntry(tx, {
        account: issuerId,
        amount: -issuerStake,
        type: "stake_lock",
        meta: { stakeId: stakeRef.id, kind: "offer", leg: "issuer" },
      });

      tx.set(stakeRef, {
        kind: "challenge_up", // distinguishes from peer stakes
        issuerId,
        opponentId,
        circleId, // the circle it was issued from (for the accept deep-link)
        status: "pending",
        issuerLocked: true, // OPTION 3: issuer's CP is held in escrow now
        // FIXED asymmetric terms, computed at propose:
        issuerStake,
        opponentStake,
        // Snapshot the ratings the terms were computed from (audit/debug).
        proposeIssuerRating: issuerRating,
        proposeOpponentRating: opponentRating,
        proposeIssuerRd: issuerRd,
        proposeOpponentRd: opponentRd,
        gameId: null,
        pot: null,
        settledResult: null,
        settled: false,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
    const ref = stakeRef;

    // Notify the opponent of the challenge so they can accept within the window.
    await notify({
      recipientId: opponentId,
      type: "challenge_up",
      title: "You've been challenged",
      body: "Someone challenged you up. Accept to set the stakes and play.",
      data: {
        stakeId: ref.id,
        issuerId,
        ...(circleId ? { circleId } : {}),
      },
    });

    return { stakeId: ref.id };
  }
);

/**
 * Accept a challenge-up. Computes BOTH players' asymmetric stakes from the
 * live rating gap and balances, validates each against the 40% cap and the
 * same-opponent daily cap, locks both (asymmetric escrow), creates the active
 * "challenge_up" game, and links it. All atomic — same guarantees as peer
 * accept, just with asymmetric amounts.
 */
export const acceptChallengeUp = functions.https.onCall(
  async (data, context) => {
    const uid = requireAuth(context);
    const stakeId: string | undefined = data?.stakeId;
    if (!stakeId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "stakeId is required."
      );
    }

    const stakeRef = db.collection("stakes").doc(stakeId);

    const result = await db.runTransaction(async (tx) => {
      // ---- READS ----
      const snap = await tx.get(stakeRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "Challenge not found.");
      }
      const s = snap.data()!;
      if (s.kind !== "challenge_up") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Not a challenge-up stake."
        );
      }
      if (s.status !== "pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "This challenge is no longer open."
        );
      }
      if (s.opponentId !== uid) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only the challenged player can accept."
        );
      }

      const issuerId: string = s.issuerId;
      const opponentId: string = s.opponentId;

      // OPTION 3: the asymmetric stakes were COMPUTED & FIXED at propose, and
      // the issuer's leg is already locked. We honor those fixed terms here
      // (we do NOT recompute against live ratings — the offer is a fixed deal).
      // Guard against a pre-Option-3 offer that lacks fixed terms / issuer lock.
      if (
        s.issuerLocked !== true ||
        typeof s.issuerStake !== "number" ||
        typeof s.opponentStake !== "number"
      ) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "This challenge is missing its fixed terms and can't be accepted."
        );
      }
      const issuerStake: number = s.issuerStake;
      const opponentStake: number = s.opponentStake;

      // Only the OPPONENT's balance needs validating now (issuer is escrowed).
      const opponentBal = await readCpInTx(tx, opponentId);

      // Same-opponent daily cap (both directions).
      const issuerCounts = await getCountsInTx(tx, issuerId);
      const opponentCounts = await getCountsInTx(tx, opponentId);
      if (
        (issuerCounts.opponentCounts[opponentId] || 0) >=
          SAME_OPPONENT_DAILY_CAP ||
        (opponentCounts.opponentCounts[issuerId] || 0) >=
          SAME_OPPONENT_DAILY_CAP
      ) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `Daily limit reached against this opponent (${SAME_OPPONENT_DAILY_CAP}/day).`
        );
      }

      if (issuerStake < MIN_STAKE || opponentStake < MIN_STAKE) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Both stakes must be at least ${MIN_STAKE} CP.`
        );
      }
      if (opponentBal < opponentStake) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "You don't have enough CP for this challenge."
        );
      }

      // ---- WRITES ----
      const issuerIsWhite = Math.random() < 0.5;
      const whiteId = issuerIsWhite ? issuerId : opponentId;
      const blackId = issuerIsWhite ? opponentId : issuerId;

      const gameRef = db.collection("games").doc();
      tx.set(gameRef, {
        status: "waiting",
        gameType: "challenge_up",
        contextId: stakeId,
        fen: STARTING_FEN,
        moves: [],
        turn: "w",
        whiteId,
        blackId,
        players: [whiteId, blackId],
        ready: [], // ready-gate: both must markReady before the clock starts
        whiteMs: INITIAL_MS,
        blackMs: INITIAL_MS,
        lastMoveAt: null, // frozen until both players ready up
        result: null,
        resultReason: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Lock ONLY the opponent's leg — the issuer's was locked at propose.
      // Locking the issuer again here would double-charge them.
      appendEntry(tx, {
        account: opponentId,
        amount: -opponentStake,
        type: "stake_lock",
        gameId: gameRef.id,
        meta: { stakeId, kind: "challenge_up", leg: "opponent" },
      });

      tx.update(stakeRef, {
        status: "locked",
        issuerStake,
        opponentStake,
        pot: issuerStake + opponentStake,
        gameId: gameRef.id,
        whiteId,
        blackId,
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Same-opponent counters for both.
      bumpOpponent(tx, issuerId, opponentId);
      bumpOpponent(tx, opponentId, issuerId);

      // Notify the challenger their challenge was accepted, and both players
      // that the game is waiting to start.
      notifyTx(tx, {
        recipientId: issuerId,
        type: "stake_accepted",
        title: "Challenge accepted",
        body: "Your challenge was accepted. Enter to start the game.",
        data: { stakeId, gameId: gameRef.id },
      });
      notifyTx(tx, {
        recipientId: issuerId,
        type: "game_ready",
        title: "Game ready to start",
        body: "Enter the board to start your challenge game.",
        data: { gameId: gameRef.id },
      });
      notifyTx(tx, {
        recipientId: opponentId,
        type: "game_ready",
        title: "Game ready to start",
        body: "Enter the board to start your challenge game.",
        data: { gameId: gameRef.id },
      });

      return {
        gameId: gameRef.id,
        issuerStake,
        opponentStake,
      };
    });

    // Challenge resolved (accepted) → remove the now-stale challenge_up
    // notification for the opponent.
    await deleteOfferNotifications(stakeId);

    return result;
  }
);

// ===========================================================================
// OPEN LOBBY (gameType "outside") — staked play with STRANGERS, no circle.
// ---------------------------------------------------------------------------
// The lobby lets any player post an OPEN SEAT that anyone else can accept,
// outside any circle. Stakes are asymmetric by rating (same formula as
// challenge-up): the underdog stakes less. Because the opponent is unknown at
// post time, the asymmetric amounts CANNOT be computed or locked until someone
// accepts — so (unlike Option-3 circle offers) a lobby seat locks NOTHING at
// post. To keep that safe from over-posting, a player may hold only ONE open
// seat at a time (MAX_OPEN_LOBBY_SEATS). Both legs lock at ACCEPT, with live
// affordability checks for both players.
//
// V2 NOTE (deferred guardrails): smurf/collusion defenses (provisional gate,
// rating-band limits) are intentionally NOT enforced yet. The seat doc records
// poster rating so they can be added later without a migration. The sink (rake)
// already makes pure CP-laundering lossy; the deferred gates would address
// smurfing of new users. See design discussion.
// ===========================================================================

/** A player may hold at most this many open lobby seats at once (Resolution C:
 *  the 1-seat cap is what keeps "lock nothing at post" safe from over-posting). */
const MAX_OPEN_LOBBY_SEATS = 1;

/**
 * Post an open lobby seat. Locks NOTHING (the asymmetric stake isn't known
 * until someone accepts). The POSTER chooses their exact stake S (200+, in 50s,
 * up to 40% of their balance — validateLobbyPosterStake enforces this). Nothing
 * is locked at post (the accepter's anchored amount isn't known until accept);
 * the one-open-seat cap keeps that safe. The chosen S and the poster's
 * rating+rd are stored so the accepter's stake can be computed (anchored to S,
 * scaled by the Glicko win odds) when someone takes the seat.
 */
export const postLobbySeat = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);

  // The poster's chosen stake S (the amount THEY will risk). Validated below
  // against the live balance (floor 200, ≤40% cap, steps of 50).
  const stake: number | undefined =
    typeof data?.stake === "number" ? data.stake : undefined;
  if (typeof stake !== "number" || !Number.isInteger(stake)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "A whole-number stake is required to post a lobby seat."
    );
  }

  // One open seat per player (Resolution C). Authoritative check is in the tx;
  // this is a fast early error.
  const existing = await db
    .collection("stakes")
    .where("issuerId", "==", uid)
    .where("kind", "==", "outside")
    .where("status", "==", "open")
    .limit(MAX_OPEN_LOBBY_SEATS)
    .get();
  if (existing.size >= MAX_OPEN_LOBBY_SEATS) {
    throw new functions.https.HttpsError(
      "resource-exhausted",
      "You already have an open lobby seat. Cancel it before posting another."
    );
  }

  const seatRef = db.collection("stakes").doc();
  await db.runTransaction(async (tx) => {
    // Validate the chosen stake against the poster's LIVE balance: ≥200,
    // ≤40% of balance, in steps of 50. (Also rejects posters whose 40% cap
    // can't reach the 200 floor — i.e. balance < 500.)
    const bal = await readCpInTx(tx, uid);
    const reason = validateLobbyPosterStake(stake, bal);
    if (reason) {
      throw new functions.https.HttpsError("failed-precondition", reason);
    }

    // Re-check the one-seat cap inside the tx (race-safe).
    const open = await tx.get(
      db
        .collection("stakes")
        .where("issuerId", "==", uid)
        .where("kind", "==", "outside")
        .where("status", "==", "open")
    );
    if (open.size >= MAX_OPEN_LOBBY_SEATS) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        "You already have an open lobby seat."
      );
    }

    // Snapshot the poster's rating AND rd: rating for display, rd so the
    // accepter's Glicko-odds stake can be computed at accept (and previewed
    // client-side). posterStake is the poster's fixed leg.
    const profile = await tx.get(db.collection("users").doc(uid));
    const posterRating = (profile.get("rating") as number) ?? 1500;
    const posterRd = (profile.get("rd") as number) ?? 350;

    tx.set(seatRef, {
      kind: "outside", // open lobby / stranger game
      issuerId: uid, // the poster (seat owner)
      opponentId: null, // unknown until accepted
      circleId: null, // circle-less
      status: "open", // open seat (distinct from "pending" directed offers)
      issuerLocked: false, // NOTHING locked at post (Resolution C)
      gameId: null,
      pot: null,
      settledResult: null,
      settled: false,
      posterStake: stake, // the poster's CHOSEN, fixed leg (S)
      posterRating, // for the lobby list + accepter odds + V2 rating-band checks
      posterRd, // for the accepter's Glicko-odds stake (compute + client preview)
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { seatId: seatRef.id };
});

/**
 * Accept an open lobby seat. This is where the real work happens: compute both
 * players' asymmetric stakes from the live rating gap (same formula as
 * challenge-up), check BOTH can afford their leg (live balance + 40% cap), lock
 * BOTH legs now, create the "outside" game, and mark the seat matched.
 */
export const acceptLobbySeat = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const seatId: string | undefined = data?.seatId;
  if (!seatId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "seatId is required."
    );
  }

  const seatRef = db.collection("stakes").doc(seatId);

  const result = await db.runTransaction(async (tx) => {
    // ---- READS ----
    const snap = await tx.get(seatRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Seat not found.");
    }
    const s = snap.data()!;
    if (s.kind !== "outside") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Not a lobby seat."
      );
    }
    if (s.status !== "open") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This seat is no longer open."
      );
    }
    const posterId: string = s.issuerId;
    if (posterId === uid) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You can't accept your own seat."
      );
    }

    // Live ratings + RD (for the Glicko odds) and balances (for the cap).
    const posterProfile = await tx.get(db.collection("users").doc(posterId));
    const accepterProfile = await tx.get(db.collection("users").doc(uid));
    const posterRating = (posterProfile.get("rating") as number) ?? 1500;
    const posterRd = (posterProfile.get("rd") as number) ?? 350;
    const accepterRating = (accepterProfile.get("rating") as number) ?? 1500;
    const accepterRd = (accepterProfile.get("rd") as number) ?? 350;

    const posterBal = await readCpInTx(tx, posterId);
    const accepterBal = await readCpInTx(tx, uid);

    // Same-opponent daily cap (both directions) — reuses the existing anti-
    // collusion limiter. (V2 will add stronger lobby-specific guardrails.)
    const posterCounts = await getCountsInTx(tx, posterId);
    const accepterCounts = await getCountsInTx(tx, uid);
    if (
      (posterCounts.opponentCounts[uid] || 0) >= SAME_OPPONENT_DAILY_CAP ||
      (accepterCounts.opponentCounts[posterId] || 0) >= SAME_OPPONENT_DAILY_CAP
    ) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `Daily limit reached against this opponent (${SAME_OPPONENT_DAILY_CAP}/day).`
      );
    }

    // POSTER's leg = the stake they CHOSE at post (fixed). Fall back to a live
    // computation only for legacy seats posted before posterStake existed (test
    // data is wiped, but this keeps a stray old seat from crashing).
    const posterStake: number =
      typeof s.posterStake === "number"
        ? s.posterStake
        : challengeStakeAmount(
            { rating: posterRating, rd: posterRd },
            { rating: accepterRating, rd: accepterRd },
            posterBal
          );

    // ACCEPTER's leg = anchored to the poster's stake, scaled by the Glicko win
    // odds, clamped (floor 200, ceiling min(3×S, 40% of balance)). A favorite
    // stakes up to 3×; an underdog down to 200.
    const accepterStake = lobbyAccepterStake(
      posterStake,
      { rating: accepterRating, rd: accepterRd },
      { rating: posterRating, rd: posterRd },
      accepterBal
    );

    if (posterStake < MIN_STAKE || accepterStake < MIN_STAKE) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Both stakes must be at least ${MIN_STAKE} CP.`
      );
    }
    // BOTH legs lock here, so BOTH must be able to afford their stake now.
    if (posterBal < posterStake) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "The seat poster no longer has enough CP — seat can't be filled."
      );
    }
    if (accepterBal < accepterStake) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You don't have enough CP for this game."
      );
    }
    if (posterStake > Math.floor(posterBal * MAX_STAKE_FRACTION)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Stake exceeds the poster's per-game limit — seat can't be filled."
      );
    }
    // The accepter's clamp already caps at 40% of balance; this guards the case
    // where the clamp's ceiling fell BELOW the 200 floor (40% of their balance
    // < 200), which lobbyAccepterStake signals by returning a sub-floor value:
    // they simply can't afford this seat at the required minimum.
    if (
      accepterStake > Math.floor(accepterBal * MAX_STAKE_FRACTION) ||
      accepterStake < LOBBY_ACCEPTER_FLOOR
    ) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `You need at least ${Math.ceil(
          LOBBY_ACCEPTER_FLOOR / MAX_STAKE_FRACTION
        )} CP to accept this seat.`
      );
    }

    // ---- WRITES ----
    const posterIsWhite = Math.random() < 0.5;
    const whiteId = posterIsWhite ? posterId : uid;
    const blackId = posterIsWhite ? uid : posterId;

    const gameRef = db.collection("games").doc();
    tx.set(gameRef, {
      status: "waiting",
      gameType: "outside",
      contextId: seatId,
      fen: STARTING_FEN,
      moves: [],
      turn: "w",
      whiteId,
      blackId,
      players: [whiteId, blackId],
      ready: [],
      whiteMs: INITIAL_MS,
      blackMs: INITIAL_MS,
      lastMoveAt: null,
      result: null,
      resultReason: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // BOTH legs lock now (nothing was locked at post — Resolution C).
    appendEntry(tx, {
      account: posterId,
      amount: -posterStake,
      type: "stake_lock",
      gameId: gameRef.id,
      meta: { stakeId: seatId, kind: "outside", leg: "poster" },
    });
    appendEntry(tx, {
      account: uid,
      amount: -accepterStake,
      type: "stake_lock",
      gameId: gameRef.id,
      meta: { stakeId: seatId, kind: "outside", leg: "accepter" },
    });

    tx.update(seatRef, {
      status: "locked",
      opponentId: uid, // the accepter
      issuerStake: posterStake, // poster's leg (issuer == poster)
      opponentStake: accepterStake, // accepter's leg
      pot: posterStake + accepterStake,
      gameId: gameRef.id,
      whiteId,
      blackId,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Same-opponent counters for both.
    bumpOpponent(tx, posterId, uid);
    bumpOpponent(tx, uid, posterId);

    // Notify the poster their seat was filled; both that the game is ready.
    notifyTx(tx, {
      recipientId: posterId,
      type: "stake_accepted",
      title: "Your seat was filled",
      body: "Someone joined your open game. Enter to start.",
      data: { stakeId: seatId, gameId: gameRef.id },
    });
    notifyTx(tx, {
      recipientId: posterId,
      type: "game_ready",
      title: "Game ready to start",
      body: "Enter the board to start your game.",
      data: { gameId: gameRef.id },
    });
    notifyTx(tx, {
      recipientId: uid,
      type: "game_ready",
      title: "Game ready to start",
      body: "Enter the board to start your game.",
      data: { gameId: gameRef.id },
    });

    return { gameId: gameRef.id, posterStake, accepterStake };
  });

  return result;
});

/**
 * Cancel (withdraw) your own open lobby seat. Nothing was locked at post, so
 * there's nothing to refund — just mark it cancelled.
 */
export const cancelLobbySeat = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const seatId: string | undefined = data?.seatId;
  if (!seatId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "seatId is required."
    );
  }

  const seatRef = db.collection("stakes").doc(seatId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(seatRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Seat not found.");
    }
    const s = snap.data()!;
    if (s.kind !== "outside") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Not a lobby seat."
      );
    }
    if (s.issuerId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Only the seat owner can cancel it."
      );
    }
    if (s.status !== "open") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Only an open seat can be cancelled."
      );
    }
    // Nothing locked at post → no refund. Just close the seat.
    tx.update(seatRef, {
      status: "cancelled",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { ok: true };
});
