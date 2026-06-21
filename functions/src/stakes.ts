/**
 * Chess Masters — Slice 3c-1: within-circle peer staking (propose / accept).
 *
 * THE MODEL (locked V1 §5, with this session's decisions):
 *   - Peer staking is between two members of the SAME circle.
 *   - The issuer proposes an ABSOLUTE CP amount; the opponent accepts or
 *     declines. (Equal fixed CP from both — symmetric pot.)
 *   - At ACCEPT (not propose) we validate against LIVE balances: each player
 *     must hold the stake AND the stake must be ≤ 30% of each player's balance
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
  computeBalanceInTx,
  settlePot,
  SINK_ACCOUNT,
  MIN_STAKE,
  MAX_STAKE_FRACTION,
} from "./ledger";

const db = admin.firestore();

// Game constants — must match the engine's fresh-game shape (index.ts).
const STARTING_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
const INITIAL_MS = 5 * 60 * 1000; // 5+3 blitz, same as casual games

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
  // duplicate offers stacking up.
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

  const ref = db.collection("stakes").doc();
  await ref.set({
    issuerId,
    opponentId,
    circleId,
    amount, // the proposed absolute CP each side will stake
    status: "pending",
    gameId: null,
    pot: null,
    settledResult: null,
    settled: false,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
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
    tx.update(ref, {
      status: "cancelled",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
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
    tx.update(ref, {
      status: "declined",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  return { ok: true };
});

// ---- acceptStake (THE critical transaction) -------------------------------
/**
 * Opponent accepts. In ONE transaction: validate both live balances against
 * the 30% cap, lock both stakes (negative ledger entries), create an ACTIVE
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

    // Live, transaction-consistent spendable balances (escrow already netted).
    const issuerBal = await computeBalanceInTx(tx, issuerId);
    const opponentBal = await computeBalanceInTx(tx, opponentId);

    // Validate the §5 cap against BOTH players' current balances.
    if (issuerBal < amount) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "The issuer no longer has enough CP for this stake."
      );
    }
    if (opponentBal < amount) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You don't have enough CP for this stake."
      );
    }
    if (amount > Math.floor(issuerBal * MAX_STAKE_FRACTION)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Stake exceeds 30% of the issuer's balance."
      );
    }
    if (amount > Math.floor(opponentBal * MAX_STAKE_FRACTION)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Stake exceeds 30% of your balance."
      );
    }

    // ---- WRITES ----
    // Coin-flip colors for fairness.
    const issuerIsWhite = Math.random() < 0.5;
    const whiteId = issuerIsWhite ? issuerId : opponentId;
    const blackId = issuerIsWhite ? opponentId : issuerId;

    // Create the game ALREADY ACTIVE (both players known at accept; no waiting
    // seat). Shape matches the engine's fresh active game so makeMove/resign/
    // claimTimeout operate on it identically. gameType "peer", contextId =
    // stakeId so settlement (3c-2) can find the stake from the finished game.
    const gameRef = db.collection("games").doc();
    tx.set(gameRef, {
      status: "active",
      gameType: "peer",
      contextId: stakeId,
      fen: STARTING_FEN,
      moves: [],
      turn: "w",
      whiteId,
      blackId,
      players: [whiteId, blackId],
      whiteMs: INITIAL_MS,
      blackMs: INITIAL_MS,
      lastMoveAt: Date.now(), // white's clock starts now
      result: null,
      resultReason: null,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Lock both stakes — negative ledger entries. CP leaves spendable now.
    appendEntry(tx, {
      account: issuerId,
      amount: -amount,
      type: "stake_lock",
      gameId: gameRef.id,
      meta: { stakeId },
    });
    appendEntry(tx, {
      account: opponentId,
      amount: -amount,
      type: "stake_lock",
      gameId: gameRef.id,
      meta: { stakeId },
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

    return { gameId: gameRef.id };
  });

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
    const stake: number = s.issuerStake; // equal fixed CP, so == opponentStake

    if (result === "draw") {
      // Return each stake minus their half of the rake. With equal stakes the
      // pot is even and the rake splits cleanly; we still floor each player's
      // refund and let any residual land in the sink so totals reconcile.
      const { rake } = settlePot(pot);
      const halfRake = Math.floor(rake / 2);
      const issuerRefund = stake - halfRake;
      const opponentRefund = stake - halfRake;
      // Residual (if rake is odd) goes to the sink so refunds + sink == pot.
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
