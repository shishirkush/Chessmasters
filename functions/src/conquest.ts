/**
 * Chess Masters — Slice 4: Conquest (breach half).
 *
 * Conquest is how an OUTSIDER wins membership in a circle they don't belong to,
 * by beating its defenders over the board. CP gates the attempt; STANDING is the
 * prize (never CP). This file is the BREACH half (step 1-2 of the loop):
 *
 *   1. initiateBreach   — challenger locks a breach stake (challenge-up formula
 *                         vs the circle OWNER's rating, 40% cap) and a conquest
 *                         doc is created in `breach_pending`. Guarded by a
 *                         per-attacker-per-circle WEEKLY cooldown.
 *   2. acceptBreachDefense — the FIRST circle member to accept (first-come,
 *                         server-timestamp) defends; one breach game decides it.
 *   3. settleConquest (breach branch) — on the breach game finishing
 *         (Option B: per-game settlement, both outcomes terminal for the stake):
 *         challenger WINS    → breach stake RETURNS to the challenger (refund),
 *                              conquest advances to `gauntlet_pending`.
 *         challenger LOSES/DRAWS → breach FAILS; breach stake transfers WHOLE to
 *                              the defender (no rake); `breach_failed`.
 *
 * The Gauntlet half (best-of-3, owner-nominated defender, per-game defender
 * stake that BURNS on a challenger win) is built next and slots into
 * settleConquest's gauntlet branch.
 *
 * CHALLENGER CP EXPOSURE (Option B): the challenger risks CP ONLY on the breach
 * game. Win the breach → stake refunded; the rest of the conquest puts only the
 * DEFENDER's CP at risk (the Gauntlet). Lose/draw the breach → stake to the
 * defender. So a challenger's total CP downside is "the breach stake, refunded
 * unless they lose the breach game."
 *
 * ESCROW REUSE: the breach stake is a one-staker wager, reusing the proven
 * `stakes/{id}` + ledger `stake_lock` machinery (kind:"breach" marks it). Its
 * settlement is ONE-SIDED, so conquest gets its OWN settler here;
 * settleStakeForGame (symmetric two-staker) is untouched.
 *
 * TIME: the weekly cooldown is a PASSIVE server-clock check (Date.now() vs a
 * stored timestamp), read on-demand at initiate time — exactly like the daily
 * caps and the 90s abandon rule. No scheduler / no background job.
 */

import * as functions from "firebase-functions/v1";
import { FieldValue } from "firebase-admin/firestore";
import {
  appendEntry,
  computeBalance,
  readCpInTx,
  SINK_ACCOUNT,
} from "./ledger";
import { challengeStakeAmount } from "./challenge";

import { db } from "./init";
import {
  notify,
  notifyTx,
  notifyManyTx,
  deleteBreachNotifications,
  deleteConquestNotifications,
} from "./notify";

// Game constants — must match the engine's fresh active game (index.ts).
const STARTING_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const INITIAL_MS = 5 * 60 * 1000; // 5+3 blitz

// Per-attacker-per-circle breach cooldown: a given challenger may breach a
// given circle at most once every 7 days. Passive check at initiate time.
const BREACH_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;

// Gauntlet: best-of-3 (first to 2 decisive wins). Draws replay, don't count.
const GAUNTLET_WINS_TO_TAKE = 2;

// The defender's per-game Gauntlet stake is a DISCOUNTED fraction of a normal
// staked-game amount (25% — "25% of the equivalent 3-game stake", computed
// per game per the Model A decision). Recomputed each game vs current balance
// and the current rating gap.
const GAUNTLET_STAKE_DISCOUNT = 0.25;

export type ConquestStatus =
  | "breach_pending"
  | "breach_defense_active"
  | "gauntlet_pending"
  | "gauntlet_active"
  | "challenger_won"
  | "challenger_ejected"
  | "breach_failed"
  | "force_closed";

const ACTIVE_STATUSES: ConquestStatus[] = [
  "breach_pending",
  "breach_defense_active",
  "gauntlet_pending",
  "gauntlet_active",
];

function requireAuth(context: functions.https.CallableContext): string {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be signed in."
    );
  }
  return context.auth.uid;
}

function cooldownRef(circleId: string, attackerId: string) {
  return db.collection("conquestCooldowns").doc(`${circleId}_${attackerId}`);
}

// ---- getBreachEligibility (read-only preview) -----------------------------
/**
 * Read-only: can the caller breach this circle right now, and what would it
 * cost? Runs the SAME gate checks as initiateBreach (in the same order) but
 * mutates nothing — so the UI can show an accurate Breach button (enabled /
 * disabled-with-reason / cooldown days) and the authoritative stake estimate
 * BEFORE the player commits.
 *
 * IMPORTANT: this is a best-effort preview, not a lock. Eligibility can pass
 * here and then initiateBreach can still fail if state changes in the gap
 * (e.g. someone else mounts a breach first). The client must handle that.
 *
 * KEEP IN SYNC WITH initiateBreach: any guard added there must be mirrored
 * here, and vice versa.
 *
 * Returns:
 *   { eligible, reason, cooldownDaysLeft, estimatedStake,
 *     ownerRating, myRating, myBalance }
 * reason ∈ null | "own_circle" | "already_member" | "active_conquest"
 *            | "circle_under_breach" | "cooldown" | "insufficient_cp"
 */
export const getBreachEligibility = functions.https.onCall(
  async (data, context) => {
    const challengerId = requireAuth(context);
    const circleId: string | undefined = data?.circleId;
    if (!circleId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "circleId is required."
      );
    }

    const circleSnap = await db.collection("circles").doc(circleId).get();
    if (!circleSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Circle not found.");
    }
    const c = circleSnap.data()!;
    const ownerId: string = c.ownerId;
    const members: string[] = Array.isArray(c.members) ? c.members : [];

    // Ratings + balance (for the stake estimate and the cap math).
    const [ownerSnap, challengerSnap] = await Promise.all([
      db.collection("users").doc(ownerId).get(),
      db.collection("users").doc(challengerId).get(),
    ]);
    const ownerRating = (ownerSnap.get("rating") as number) ?? 1500;
    const ownerRd = (ownerSnap.get("rd") as number) ?? 350;
    const myRating = (challengerSnap.get("rating") as number) ?? 1500;
    const myRd = (challengerSnap.get("rd") as number) ?? 350;
    const myBalance = await computeBalance(challengerId);

    const estimatedStake = challengeStakeAmount(
      { rating: myRating, rd: myRd },
      { rating: ownerRating, rd: ownerRd },
      myBalance
    );

    const base = {
      estimatedStake,
      ownerRating: Math.round(ownerRating),
      myRating: Math.round(myRating),
      myBalance,
    };

    const fail = (reason: string, cooldownDaysLeft: number | null = null) => ({
      eligible: false,
      reason,
      cooldownDaysLeft,
      ...base,
    });

    // Same gate order as initiateBreach.
    if (ownerId === challengerId) return fail("own_circle");
    if (members.includes(challengerId)) return fail("already_member");

    // Weekly cooldown.
    const cdSnap = await cooldownRef(circleId, challengerId).get();
    if (cdSnap.exists) {
      const last = (cdSnap.get("lastBreachAt") as number) ?? 0;
      const elapsed = Date.now() - last;
      if (elapsed < BREACH_COOLDOWN_MS) {
        const daysLeft = Math.ceil(
          (BREACH_COOLDOWN_MS - elapsed) / (24 * 60 * 60 * 1000)
        );
        return fail("cooldown", daysLeft);
      }
    }

    // NOTE (design #18, revised): concurrent conquests to different circles are
    // allowed, so there is no per-attacker active-conquest gate here anymore.
    // Only the per-circle breach lock applies.

    // One active breach per circle.
    const circleActive = await db
      .collection("conquests")
      .where("circleId", "==", circleId)
      .where("status", "in", ACTIVE_STATUSES)
      .limit(1)
      .get();
    if (!circleActive.empty) return fail("circle_under_breach");

    // Enough CP to lock the stake.
    if (estimatedStake <= 0 || myBalance < estimatedStake) {
      return fail("insufficient_cp");
    }

    return { eligible: true, reason: null, cooldownDaysLeft: null, ...base };
  }
);

// ---- initiateBreach --------------------------------------------------------
export const initiateBreach = functions.https.onCall(async (data, context) => {
  const challengerId = requireAuth(context);
  const circleId: string | undefined = data?.circleId;
  if (!circleId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "circleId is required."
    );
  }

  const circleRef = db.collection("circles").doc(circleId);
  const challengerRef = db.collection("users").doc(challengerId);
  const conquestRef = db.collection("conquests").doc();
  const stakeRef = db.collection("stakes").doc();
  const cdRef = cooldownRef(circleId, challengerId);

  const result = await db.runTransaction(async (tx) => {
    // ---- READS FIRST (Firestore: all reads before any write) ----
    const circleSnap = await tx.get(circleRef);
    if (!circleSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Circle not found.");
    }
    const c = circleSnap.data()!;
    const ownerId: string = c.ownerId;
    // Defensive: a corrupted circle doc or malformed query could leave
    // null / undefined / empty entries in members. Filter to valid non-empty
    // string uids before the membership check or notification fan-out.
    // (notifyManyTx also guards internally — this is defense in depth.)
    const members: string[] = (
      Array.isArray(c.members) ? c.members : []
    ).filter((m: unknown): m is string => typeof m === "string" && m.length > 0);

    if (ownerId === challengerId) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You can't breach your own circle."
      );
    }
    if (members.includes(challengerId)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You're already a member of this circle."
      );
    }

    // Weekly per-attacker-per-circle cooldown (passive timestamp check).
    const cdSnap = await tx.get(cdRef);
    if (cdSnap.exists) {
      const last = (cdSnap.get("lastBreachAt") as number) ?? 0;
      const elapsed = Date.now() - last;
      if (elapsed < BREACH_COOLDOWN_MS) {
        const daysLeft = Math.ceil(
          (BREACH_COOLDOWN_MS - elapsed) / (24 * 60 * 60 * 1000)
        );
        throw new functions.https.HttpsError(
          "failed-precondition",
          `You breached this circle recently. Try again in ${daysLeft} day(s).`
        );
      }
    }

    // Owner rating drives the breach stake formula; challenger rating + balance.
    const ownerSnap = await tx.get(db.collection("users").doc(ownerId));
    const challengerSnap = await tx.get(challengerRef);
    const ownerRating = (ownerSnap.get("rating") as number) ?? 1500;
    const ownerRd = (ownerSnap.get("rd") as number) ?? 350;
    const challengerRating = (challengerSnap.get("rating") as number) ?? 1500;
    const challengerRd = (challengerSnap.get("rd") as number) ?? 350;
    const challengerBal = await readCpInTx(tx, challengerId);

    // NOTE (design #18, revised): a challenger MAY hold multiple concurrent
    // conquests against DIFFERENT circles — the per-attacker limit was removed
    // to support aggressive play during the breach-accept window. Over-extension
    // is bounded naturally: each breach locks its OWN stake, so a challenger can
    // only mount as many as their CP balance covers. The one-active-breach-PER-
    // CIRCLE guard below still stands (two challengers can't breach one circle).

    // One active breach per CIRCLE (first-come holds it; no displacement in V1).
    const circleActive = await tx.get(
      db
        .collection("conquests")
        .where("circleId", "==", circleId)
        .where("status", "in", ACTIVE_STATUSES)
        .limit(1)
    );
    if (!circleActive.empty) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This circle is already under an active breach. Try again later."
      );
    }

    // Breach stake: challenge-up fraction of the CHALLENGER's balance vs the
    // OWNER's rating (Glicko-2, RD-weighted). Formula clamps at 40%.
    const breachStake = challengeStakeAmount(
      { rating: challengerRating, rd: challengerRd },
      { rating: ownerRating, rd: ownerRd },
      challengerBal
    );
    if (breachStake <= 0 || challengerBal < breachStake) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You don't have enough CP to mount a breach."
      );
    }

    // ---- WRITES ----
    tx.set(stakeRef, {
      kind: "breach",
      issuerId: challengerId,
      opponentId: null, // defender unknown until acceptBreachDefense
      circleId,
      conquestId: conquestRef.id,
      amount: breachStake,
      issuerStake: breachStake,
      opponentStake: 0, // defender stakes nothing in the breach
      pot: breachStake,
      status: "locked",
      gameId: null,
      settled: false,
      settledResult: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    appendEntry(tx, {
      account: challengerId,
      amount: -breachStake,
      type: "stake_lock",
      meta: { stakeId: stakeRef.id, kind: "breach", conquestId: conquestRef.id },
    });

    tx.set(conquestRef, {
      challengerId,
      circleId,
      ownerId,
      status: "breach_pending" as ConquestStatus,
      breachStakeId: stakeRef.id,
      breachDefenderId: null,
      breachGameId: null,
      gauntlet: {
        defenderId: null,
        gameIds: [],
        challengerWins: 0,
        defenderWins: 0,
        currentGameId: null,
        currentStakeId: null,
      },
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Stamp the cooldown ONLY now that all guards passed and a breach mounted.
    tx.set(
      cdRef,
      {
        circleId,
        attackerId: challengerId,
        lastBreachAt: Date.now(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    // Notify every circle member (esp. the owner) that their circle is under
    // breach and can be defended — otherwise they'd never know unless on the
    // circle page.
    notifyManyTx(
      tx,
      members,
      {
        type: "breach_initiated",
        title: "Your circle is under breach",
        body: `A challenger is breaching ${c.name ?? "your circle"}. Defend to stop them.`,
        data: { circleId, conquestId: conquestRef.id },
      },
      challengerId
    );

    return { conquestId: conquestRef.id, breachStake };
  });

  return result;
});

// ---- acceptBreachDefense ---------------------------------------------------
export const acceptBreachDefense = functions.https.onCall(
  async (data, context) => {
    const defenderId = requireAuth(context);
    const conquestId: string | undefined = data?.conquestId;
    if (!conquestId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "conquestId is required."
      );
    }

    const conquestRef = db.collection("conquests").doc(conquestId);

    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(conquestRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "Conquest not found.");
      }
      const q = snap.data()!;

      if (q.status !== "breach_pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "This breach is not open for defense."
        );
      }
      if (q.breachDefenderId !== null) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "This breach is already being defended."
        );
      }

      const challengerId: string = q.challengerId;
      const circleId: string = q.circleId;

      if (defenderId === challengerId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "The challenger can't defend their own breach."
        );
      }

      const circleSnap = await tx.get(db.collection("circles").doc(circleId));
      if (!circleSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Circle not found.");
      }
      const members: string[] = Array.isArray(circleSnap.get("members"))
        ? (circleSnap.get("members") as string[])
        : [];
      if (!members.includes(defenderId)) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only a member of this circle can defend it."
        );
      }

      // ---- WRITES ----
      const challengerIsWhite = Math.random() < 0.5;
      const whiteId = challengerIsWhite ? challengerId : defenderId;
      const blackId = challengerIsWhite ? defenderId : challengerId;

      const gameRef = db.collection("games").doc();
      tx.set(gameRef, {
        status: "waiting",
        gameType: "breach",
        contextId: conquestId,
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

      tx.update(db.collection("stakes").doc(q.breachStakeId), {
        opponentId: defenderId,
        gameId: gameRef.id,
        whiteId,
        blackId,
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(conquestRef, {
        status: "breach_defense_active" as ConquestStatus,
        breachDefenderId: defenderId,
        breachGameId: gameRef.id,
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Both players: the breach game is waiting to start.
      notifyTx(tx, {
        recipientId: challengerId,
        type: "game_ready",
        title: "Breach game ready",
        body: "Your breach is being defended. Enter to play.",
        data: { gameId: gameRef.id, conquestId },
      });
      notifyTx(tx, {
        recipientId: defenderId,
        type: "game_ready",
        title: "Breach game ready",
        body: "Enter the board to defend against the breach.",
        data: { gameId: gameRef.id, conquestId },
      });

      return { gameId: gameRef.id };
    });

    return result;
  }
);

// ---- Gauntlet helpers ------------------------------------------------------
/**
 * Compute + lock the defender's per-game Gauntlet stake and create the next
 * Gauntlet game, all inside an existing transaction. Returns the new game and
 * stake ids. Used by BOTH nominateGauntletDefender (game 1) and the auto-chain
 * in settleConquest (games 2, 3, replays).
 *
 * Per-game stake (recomputed fresh each call): the defender's normal staked
 * amount vs the challenger, discounted to 25%. Challenger stakes NOTHING.
 * One-sided escrow: a single negative stake_lock on the defender.
 *
 * IMPORTANT: all reads happen before the writes (the caller's tx may have
 * already written; Firestore requires reads-before-writes within a tx, so this
 * helper must be called BEFORE any write that depends on its result, and the
 * caller must not have done reads it needs after this point). We do the rating
 * + balance reads here, then write.
 */
async function createGauntletGameInTx(
  tx: FirebaseFirestore.Transaction,
  conquestId: string,
  circleId: string,
  challengerId: string,
  defenderId: string
): Promise<{ gameId: string; stakeId: string; stake: number }> {
  // Live ratings + defender balance for the discounted stake.
  const challengerSnap = await tx.get(
    db.collection("users").doc(challengerId)
  );
  const defenderSnap = await tx.get(db.collection("users").doc(defenderId));
  const challengerRating = (challengerSnap.get("rating") as number) ?? 1500;
  const challengerRd = (challengerSnap.get("rd") as number) ?? 350;
  const defenderRating = (defenderSnap.get("rating") as number) ?? 1500;
  const defenderRd = (defenderSnap.get("rd") as number) ?? 350;
  const defenderBal = await readCpInTx(tx, defenderId);

  const normalStake = challengeStakeAmount(
    { rating: defenderRating, rd: defenderRd },
    { rating: challengerRating, rd: challengerRd },
    defenderBal
  );
  const stake = Math.floor(normalStake * GAUNTLET_STAKE_DISCOUNT);
  if (stake <= 0 || defenderBal < stake) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "The defender doesn't have enough CP to stake this Gauntlet game."
    );
  }

  // Coin-flip colors per game.
  const challengerIsWhite = Math.random() < 0.5;
  const whiteId = challengerIsWhite ? challengerId : defenderId;
  const blackId = challengerIsWhite ? defenderId : challengerId;

  const gameRef = db.collection("games").doc();
  const stakeRef = db.collection("stakes").doc();

  tx.set(gameRef, {
    status: "waiting",
    gameType: "gauntlet",
    contextId: conquestId,
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

  // One-sided escrow: only the defender stakes. Reuse a stakes/{id} doc.
  tx.set(stakeRef, {
    kind: "gauntlet",
    issuerId: defenderId, // the sole staker
    opponentId: challengerId,
    circleId,
    conquestId,
    amount: stake,
    issuerStake: stake,
    opponentStake: 0, // challenger stakes nothing in the Gauntlet
    pot: stake,
    status: "locked",
    gameId: gameRef.id,
    whiteId,
    blackId,
    settled: false,
    settledResult: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  appendEntry(tx, {
    account: defenderId,
    amount: -stake,
    type: "stake_lock",
    gameId: gameRef.id,
    meta: { stakeId: stakeRef.id, kind: "gauntlet", conquestId },
  });

  return { gameId: gameRef.id, stakeId: stakeRef.id, stake };
}

// ---- nominateGauntletDefender ---------------------------------------------
/**
 * Owner nominates the Gauntlet defender for a conquest sitting at
 * `gauntlet_pending` (challenger won the breach). The owner may nominate
 * themselves. The nominee must be a current circle member and not the
 * challenger. Locks the defender's first per-game stake, creates Gauntlet game
 * 1, and flips the conquest to `gauntlet_active`.
 *
 * V1 SCOPE: no online-detection / auto-cascade (deferred post-V1). The owner
 * picks a specific member; if they never show, the existing 90s abandon rule
 * resolves the game as a defender loss. (The "nominated defender never shows →
 * challenger accepted" fallback is a post-V1 refinement that needs presence.)
 */
export const nominateGauntletDefender = functions.https.onCall(
  async (data, context) => {
    const callerId = requireAuth(context);
    const conquestId: string | undefined = data?.conquestId;
    const defenderId: string | undefined = data?.defenderId;
    if (!conquestId || !defenderId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "conquestId and defenderId are required."
      );
    }

    const conquestRef = db.collection("conquests").doc(conquestId);

    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(conquestRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError("not-found", "Conquest not found.");
      }
      const q = snap.data()!;

      if (q.status !== "gauntlet_pending") {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "This conquest is not awaiting a Gauntlet nomination."
        );
      }

      const challengerId: string = q.challengerId;
      const circleId: string = q.circleId;
      const ownerId: string = q.ownerId;

      // Only the owner nominates.
      if (callerId !== ownerId) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "Only the circle owner can nominate the Gauntlet defender."
        );
      }
      // The challenger can't be the defender.
      if (defenderId === challengerId) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "The challenger can't be nominated as the defender."
        );
      }

      // Nominee must be a current member.
      const circleSnap = await tx.get(db.collection("circles").doc(circleId));
      if (!circleSnap.exists) {
        throw new functions.https.HttpsError("not-found", "Circle not found.");
      }
      const members: string[] = Array.isArray(circleSnap.get("members"))
        ? (circleSnap.get("members") as string[])
        : [];
      if (!members.includes(defenderId)) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "The nominated defender must be a member of the circle."
        );
      }

      // Create Gauntlet game 1 + lock the first defender stake.
      const first = await createGauntletGameInTx(
        tx,
        conquestId,
        circleId,
        challengerId,
        defenderId
      );

      tx.update(conquestRef, {
        status: "gauntlet_active" as ConquestStatus,
        "gauntlet.defenderId": defenderId,
        "gauntlet.currentGameId": first.gameId,
        "gauntlet.currentStakeId": first.stakeId,
        "gauntlet.challengerWins": 0,
        "gauntlet.defenderWins": 0,
        "gauntlet.gameIds": [],
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Notify the nominated defender they're in the gauntlet, and both players
      // that the first gauntlet game is waiting to start.
      notifyTx(tx, {
        recipientId: defenderId,
        type: "gauntlet_nominated",
        title: "You're defending the gauntlet",
        body: "You've been nominated to defend. Enter to start the first game.",
        data: { conquestId, gameId: first.gameId },
      });
      notifyTx(tx, {
        recipientId: defenderId,
        type: "game_ready",
        title: "Gauntlet game ready",
        body: "Enter the board to start your gauntlet game.",
        data: { gameId: first.gameId },
      });
      notifyTx(tx, {
        recipientId: challengerId,
        type: "game_ready",
        title: "Gauntlet game ready",
        body: "Enter the board to start your gauntlet game.",
        data: { gameId: first.gameId },
      });

      return { gameId: first.gameId, defenderStake: first.stake };
    });

    return result;
  }
);

// ---- settleConquest (breach branch; Option B) -----------------------------
export async function settleConquest(
  gameId: string,
  conquestId: string,
  result: string // "white" | "black" | "draw"
): Promise<void> {
  const conquestRef = db.collection("conquests").doc(conquestId);

  // Set inside the tx when the breach branch resolves, so we can clean up the
  // breach_initiated member notifications afterward (non-transactional).
  let breachResolved = false;
  // Set when the gauntlet reaches a terminal state, so we can clear the stale
  // transient conquest notifications afterward (non-transactional).
  let conquestConcluded = false;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(conquestRef);
    if (!snap.exists) {
      console.error("settleConquest: conquest not found", conquestId);
      return;
    }
    const q = snap.data()!;

    // ---- BREACH branch ----
    if (q.breachGameId === gameId) {
      if (q.status !== "breach_defense_active") return; // idempotent no-op
      breachResolved = true;

      const challengerId: string = q.challengerId;
      const defenderId: string = q.breachDefenderId;

      const gameSnap = await tx.get(db.collection("games").doc(gameId));
      const whiteId: string = gameSnap.get("whiteId");
      const challengerIsWhite = whiteId === challengerId;
      const challengerWon =
        (result === "white" && challengerIsWhite) ||
        (result === "black" && !challengerIsWhite);

      const stakeRef = db.collection("stakes").doc(q.breachStakeId);
      const stakeSnap = await tx.get(stakeRef);
      if (!stakeSnap.exists) {
        console.error("settleConquest: breach stake missing", q.breachStakeId);
        return;
      }
      const s = stakeSnap.data()!;
      if (s.settled === true) return; // idempotent
      const breachStake: number = s.issuerStake;

      if (challengerWon) {
        // Option B: refund the breach stake to the challenger, advance.
        appendEntry(tx, {
          account: challengerId,
          amount: breachStake,
          type: "stake_return",
          gameId,
          meta: {
            stakeId: q.breachStakeId,
            conquestId,
            kind: "breach",
            outcome: "breach_win_refund",
          },
        });
        tx.update(stakeRef, {
          status: "settled",
          settled: true,
          settledResult: "challenger",
          updatedAt: FieldValue.serverTimestamp(),
        });
        tx.update(conquestRef, {
          status: "gauntlet_pending" as ConquestStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
        // Notify both: the challenger breached the wall and advances; the
        // defender's circle wall was breached.
        notifyTx(tx, {
          recipientId: challengerId,
          type: "breach_won",
          title: "Breach successful!",
          body: "You breached the wall. Your stake is refunded — on to the Gauntlet.",
          data: { conquestId, circleId: q.circleId, gameId },
        });
        notifyTx(tx, {
          recipientId: defenderId,
          type: "breach_lost",
          title: "Your wall was breached",
          body: "The challenger won the breach. The Gauntlet now defends your circle.",
          data: { conquestId, circleId: q.circleId, gameId },
        });
        // Prompt the circle OWNER to nominate a Gauntlet defender. Without this
        // the conquest sits at gauntlet_pending with no one told to act, so the
        // Gauntlet never starts. The owner taps this → Circle page → nominate.
        notifyTx(tx, {
          recipientId: q.ownerId,
          type: "gauntlet_nominated",
          title: "Nominate a Gauntlet defender",
          body: "Your wall was breached. Nominate a member to defend the Gauntlet.",
          data: { conquestId, circleId: q.circleId },
        });
        return;
      }

      // Challenger lost or drew → breach fails; stake transfers WHOLE to the
      // defender (no rake — one-sided).
      appendEntry(tx, {
        account: defenderId,
        amount: breachStake,
        type: "pot_win",
        gameId,
        meta: {
          stakeId: q.breachStakeId,
          conquestId,
          kind: "breach",
          outcome: result === "draw" ? "breach_draw" : "breach_loss",
        },
      });
      tx.update(stakeRef, {
        status: "settled",
        settled: true,
        settledResult: "defender",
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.update(conquestRef, {
        status: "breach_failed" as ConquestStatus,
        updatedAt: FieldValue.serverTimestamp(),
      });
      // Notify both: the challenger lost the breach (stake forfeited); the
      // defender successfully defended their circle.
      notifyTx(tx, {
        recipientId: challengerId,
        type: "breach_lost",
        title: "Breach failed",
        body:
          result === "draw"
            ? "The breach drew — the wall holds. Your stake went to the defender."
            : "You lost the breach. Your stake went to the defender.",
        data: { conquestId, circleId: q.circleId, gameId },
      });
      notifyTx(tx, {
        recipientId: defenderId,
        type: "breach_won",
        title: "Circle defended!",
        body: "You repelled the breach and kept your circle. The forfeited stake is yours.",
        data: { conquestId, circleId: q.circleId, gameId },
      });
      return;
    }

    // ---- GAUNTLET branch ----
    if (q.gauntlet?.currentGameId === gameId) {
      if (q.status !== "gauntlet_active") return; // idempotent no-op

      const g = q.gauntlet;
      const priorGameIds: string[] = Array.isArray(g.gameIds) ? g.gameIds : [];
      // Idempotency: already-processed game → no-op (no double settle/chain).
      if (priorGameIds.includes(gameId)) return;

      const challengerId: string = q.challengerId;
      const defenderId: string = g.defenderId;

      // ===== ALL READS FIRST (Firestore: reads before writes) =====
      const gameSnap = await tx.get(db.collection("games").doc(gameId));
      const whiteId: string = gameSnap.get("whiteId");
      const challengerIsWhite = whiteId === challengerId;
      const challengerWon =
        (result === "white" && challengerIsWhite) ||
        (result === "black" && !challengerIsWhite);
      const defenderWon =
        (result === "white" && !challengerIsWhite) ||
        (result === "black" && challengerIsWhite);
      const isDraw = result === "draw";

      const stakeRef = db.collection("stakes").doc(g.currentStakeId);
      const stakeSnap = await tx.get(stakeRef);
      if (!stakeSnap.exists) {
        console.error("settleConquest: gauntlet stake missing", g.currentStakeId);
        return;
      }
      const s = stakeSnap.data()!;
      const alreadySettled = s.settled === true;
      const gameStake: number = s.issuerStake; // defender is the sole staker

      // Compute the post-game win counts to decide the outcome BEFORE writing.
      const challengerWins: number =
        (g.challengerWins ?? 0) + (challengerWon ? 1 : 0);
      const defenderWins: number =
        (g.defenderWins ?? 0) + (defenderWon ? 1 : 0);
      const newGameIds = [...priorGameIds, gameId];

      const challengerTookSeries = challengerWins >= GAUNTLET_WINS_TO_TAKE;
      const defenderTookSeries = defenderWins >= GAUNTLET_WINS_TO_TAKE;
      const willChain = !challengerTookSeries && !defenderTookSeries;

      // Conditional reads, still BEFORE any write:
      //  - terminal challenger win → read the circle (to add membership)
      //  - chaining → read ratings + defender balance for the next stake
      let circleSnap: FirebaseFirestore.DocumentSnapshot | null = null;
      if (challengerTookSeries) {
        circleSnap = await tx.get(db.collection("circles").doc(q.circleId));
      }

      let nextStake = 0;
      let nextWhiteId = "";
      let nextBlackId = "";
      let defenderCantAfford = false;
      if (willChain) {
        const challengerSnap = await tx.get(
          db.collection("users").doc(challengerId)
        );
        const defenderSnap = await tx.get(
          db.collection("users").doc(defenderId)
        );
        const challengerRating =
          (challengerSnap.get("rating") as number) ?? 1500;
        const challengerRd = (challengerSnap.get("rd") as number) ?? 350;
        const defenderRating = (defenderSnap.get("rating") as number) ?? 1500;
        const defenderRd = (defenderSnap.get("rd") as number) ?? 350;
        const defenderBal = await readCpInTx(tx, defenderId);
        const normalStake = challengeStakeAmount(
          { rating: defenderRating, rd: defenderRd },
          { rating: challengerRating, rd: challengerRd },
          defenderBal
        );
        nextStake = Math.floor(normalStake * GAUNTLET_STAKE_DISCOUNT);

        if (nextStake <= 0 || defenderBal < nextStake) {
          // The defender can't stake the next game — they can't mount a
          // defense, so the challenger takes the series by default. (Rare:
          // the per-game stake scales down with balance, so this only hits a
          // nearly-broke defender. Pre-write, so read the circle now for the
          // membership add.)
          defenderCantAfford = true;
          circleSnap = await tx.get(db.collection("circles").doc(q.circleId));
        } else {
          const challengerIsWhiteNext = Math.random() < 0.5;
          nextWhiteId = challengerIsWhiteNext ? challengerId : defenderId;
          nextBlackId = challengerIsWhiteNext ? defenderId : challengerId;
        }
      }

      // ===== WRITES =====
      // 1) Settle THIS game's defender stake (one-sided, no rake).
      if (!alreadySettled) {
        if (challengerWon) {
          appendEntry(tx, {
            account: SINK_ACCOUNT,
            amount: gameStake,
            type: "rake",
            gameId,
            meta: {
              stakeId: g.currentStakeId,
              conquestId,
              kind: "gauntlet",
              outcome: "gauntlet_burn",
            },
          });
          tx.update(stakeRef, {
            status: "settled",
            settled: true,
            settledResult: "burned",
            updatedAt: FieldValue.serverTimestamp(),
          });
        } else {
          appendEntry(tx, {
            account: defenderId,
            amount: gameStake,
            type: "stake_return",
            gameId,
            meta: {
              stakeId: g.currentStakeId,
              conquestId,
              kind: "gauntlet",
              outcome: isDraw
                ? "gauntlet_draw_return"
                : "gauntlet_defender_hold",
            },
          });
          tx.update(stakeRef, {
            status: "settled",
            settled: true,
            settledResult: "defender",
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      }

      // 2) Terminal: challenger took the series (or defender can't afford to
      //    continue → can't defend → challenger takes it).
      if (challengerTookSeries || defenderCantAfford) {
        if (circleSnap && circleSnap.exists) {
          const members: string[] = Array.isArray(circleSnap.get("members"))
            ? (circleSnap.get("members") as string[])
            : [];
          if (!members.includes(challengerId)) {
            tx.update(db.collection("circles").doc(q.circleId), {
              members: FieldValue.arrayUnion(challengerId),
              memberCount:
                (circleSnap.get("memberCount") ?? members.length) + 1,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        }
        tx.update(conquestRef, {
          "gauntlet.challengerWins": challengerWins,
          "gauntlet.defenderWins": defenderWins,
          "gauntlet.gameIds": newGameIds,
          "gauntlet.currentGameId": null,
          "gauntlet.currentStakeId": null,
          status: "challenger_won" as ConquestStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
        // Conquest over — challenger took the circle. Notify both sides and the
        // owner, then flag the stale transient notifications for cleanup.
        notifyTx(tx, {
          recipientId: challengerId,
          type: "breach_won",
          title: "Conquest won!",
          body: "You won the Gauntlet and joined the circle.",
          data: { conquestId, circleId: q.circleId },
        });
        notifyTx(tx, {
          recipientId: defenderId,
          type: "breach_lost",
          title: "The Gauntlet fell",
          body: "The challenger won the Gauntlet and joined your circle.",
          data: { conquestId, circleId: q.circleId },
        });
        if (q.ownerId && q.ownerId !== defenderId) {
          notifyTx(tx, {
            recipientId: q.ownerId,
            type: "breach_lost",
            title: "Your circle was conquered",
            body: "The challenger won the Gauntlet and joined your circle.",
            data: { conquestId, circleId: q.circleId },
          });
        }
        conquestConcluded = true;
        return;
      }

      // 3) Terminal: challenger ejected.
      if (defenderTookSeries) {
        tx.update(conquestRef, {
          "gauntlet.challengerWins": challengerWins,
          "gauntlet.defenderWins": defenderWins,
          "gauntlet.gameIds": newGameIds,
          "gauntlet.currentGameId": null,
          "gauntlet.currentStakeId": null,
          status: "challenger_ejected" as ConquestStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
        // Conquest over — the Gauntlet held. Notify both sides and the owner,
        // then flag the stale transient notifications for cleanup.
        notifyTx(tx, {
          recipientId: defenderId,
          type: "breach_won",
          title: "Gauntlet defended!",
          body: "You held the Gauntlet and repelled the challenger.",
          data: { conquestId, circleId: q.circleId },
        });
        notifyTx(tx, {
          recipientId: challengerId,
          type: "breach_lost",
          title: "Conquest failed",
          body: "The Gauntlet held. Your conquest was repelled.",
          data: { conquestId, circleId: q.circleId },
        });
        if (q.ownerId && q.ownerId !== defenderId) {
          notifyTx(tx, {
            recipientId: q.ownerId,
            type: "breach_won",
            title: "Your circle held",
            body: "The Gauntlet defended your circle against the challenger.",
            data: { conquestId, circleId: q.circleId },
          });
        }
        conquestConcluded = true;
        return;
      }

      // 4) Not terminal → AUTO-CHAIN the next game (reads already done above).
      const nextGameRef = db.collection("games").doc();
      const nextStakeRef = db.collection("stakes").doc();

      tx.set(nextGameRef, {
        status: "waiting",
        gameType: "gauntlet",
        contextId: conquestId,
        fen: STARTING_FEN,
        moves: [],
        turn: "w",
        whiteId: nextWhiteId,
        blackId: nextBlackId,
        players: [nextWhiteId, nextBlackId],
        ready: [], // ready-gate: both must markReady before the clock starts
        whiteMs: INITIAL_MS,
        blackMs: INITIAL_MS,
        lastMoveAt: null, // frozen until both players ready up
        result: null,
        resultReason: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.set(nextStakeRef, {
        kind: "gauntlet",
        issuerId: defenderId,
        opponentId: challengerId,
        circleId: q.circleId,
        conquestId,
        amount: nextStake,
        issuerStake: nextStake,
        opponentStake: 0,
        pot: nextStake,
        status: "locked",
        gameId: nextGameRef.id,
        whiteId: nextWhiteId,
        blackId: nextBlackId,
        settled: false,
        settledResult: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      appendEntry(tx, {
        account: defenderId,
        amount: -nextStake,
        type: "stake_lock",
        gameId: nextGameRef.id,
        meta: { stakeId: nextStakeRef.id, kind: "gauntlet", conquestId },
      });

      tx.update(conquestRef, {
        "gauntlet.challengerWins": challengerWins,
        "gauntlet.defenderWins": defenderWins,
        "gauntlet.gameIds": newGameIds,
        "gauntlet.currentGameId": nextGameRef.id,
        "gauntlet.currentStakeId": nextStakeRef.id,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    console.error(
      "settleConquest: gameId matched neither breach nor current gauntlet game",
      conquestId,
      gameId,
      `breachGameId=${q.breachGameId}`,
      `gauntletCurrentGameId=${q.gauntlet?.currentGameId ?? "none"}`,
      `status=${q.status}`
    );
  });

  // After a resolved breach, remove the now-stale breach_initiated
  // notifications that were fanned out to all circle members.
  if (breachResolved) {
    await deleteBreachNotifications(conquestId);
  }
  // After the gauntlet concludes, clear the stale transient conquest
  // notifications (nomination prompt, per-game game_ready, any breach fan-out).
  if (conquestConcluded) {
    await deleteConquestNotifications(conquestId);
  }
}

// ---- forceCloseConquestsForCircle -----------------------------------------
/**
 * Force-close every active conquest mounted against a circle that is being
 * deleted (or otherwise orphaned). Per design checklist #14, a force-close
 * refunds the challenger's locked breach stake. Each conquest is settled in its
 * own transaction (idempotent on already-settled stakes), and the breach
 * notifications are cleaned up afterward.
 *
 * Handles the breach-phase stake (the only CP the challenger has locked in
 * breach_pending / breach_defense_active). If a Gauntlet is mid-flight the
 * gauntlet stake is the DEFENDER's; that is also refunded if present and
 * unsettled. Best-effort and safe to call even when there are no conquests.
 */
export async function forceCloseConquestsForCircle(
  circleId: string
): Promise<void> {
  if (!circleId) return;
  const activeSnap = await db
    .collection("conquests")
    .where("circleId", "==", circleId)
    .where("status", "in", ACTIVE_STATUSES)
    .get();
  if (activeSnap.empty) return;

  for (const cDoc of activeSnap.docs) {
    const conquestId = cDoc.id;
    const conquestRef = cDoc.ref;
    let challengerToNotify: string | null = null;
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(conquestRef);
        if (!snap.exists) return;
        const q = snap.data()!;
        if (!ACTIVE_STATUSES.includes(q.status)) return; // already resolved

        challengerToNotify = q.challengerId ?? null;

        // Refund the breach stake (challenger's locked CP) if unsettled.
        if (q.breachStakeId) {
          const bRef = db.collection("stakes").doc(q.breachStakeId);
          const bSnap = await tx.get(bRef);
          if (bSnap.exists && bSnap.data()!.settled !== true) {
            const amt = bSnap.data()!.issuerStake ?? 0;
            if (amt > 0) {
              appendEntry(tx, {
                account: q.challengerId,
                amount: amt,
                type: "stake_return",
                meta: {
                  stakeId: q.breachStakeId,
                  conquestId,
                  kind: "breach",
                  outcome: "force_close_refund",
                },
              });
            }
            tx.update(bRef, {
              status: "settled",
              settled: true,
              settledResult: "force_closed",
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        }

        // If a Gauntlet stake is live (the DEFENDER's CP), refund it too.
        const gStakeId = q.gauntlet?.currentStakeId;
        if (gStakeId) {
          const gRef = db.collection("stakes").doc(gStakeId);
          const gSnap = await tx.get(gRef);
          if (gSnap.exists && gSnap.data()!.settled !== true) {
            const gAmt = gSnap.data()!.issuerStake ?? 0;
            const gAccount = gSnap.data()!.issuerId;
            if (gAmt > 0 && gAccount) {
              appendEntry(tx, {
                account: gAccount,
                amount: gAmt,
                type: "stake_return",
                meta: {
                  stakeId: gStakeId,
                  conquestId,
                  kind: "gauntlet",
                  outcome: "force_close_refund",
                },
              });
            }
            tx.update(gRef, {
              status: "settled",
              settled: true,
              settledResult: "force_closed",
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        }

        tx.update(conquestRef, {
          status: "force_closed" as ConquestStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
      });

      // Notify the challenger their conquest was force-closed (circle gone).
      if (challengerToNotify) {
        await notify({
          recipientId: challengerToNotify,
          type: "expired",
          title: "Conquest closed",
          body: "A circle you were breaching was removed. Your breach stake was refunded.",
          data: { conquestId, circleId },
        });
      }
      await deleteBreachNotifications(conquestId);
    } catch (e) {
      console.error("forceCloseConquestsForCircle failed", conquestId, e);
    }
  }
}
