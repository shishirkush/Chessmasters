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
  computeBalance,
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
import { challengeStakeAmount } from "./challenge";

import { db } from "./init";
import { notify, notifyTx, deleteOfferNotifications } from "./notify";

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

  // Pre-validate the §5 cap against the ISSUER's current balance, so an
  // over-cap offer is rejected at PROPOSE time with a clear message — rather
  // than sailing through and failing only when the opponent tries to accept.
  // (The authoritative cap check against BOTH balances still runs at accept,
  // since the opponent's balance can change in between.)
  const issuerBalance = await computeBalance(issuerId);
  const issuerCap = Math.floor(issuerBalance * MAX_STAKE_FRACTION);
  if (amount > issuerCap) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      `Stake exceeds 30% of your balance. Your current max is ${issuerCap} CP.`
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
    tx.update(ref, {
      status: "cancelled",
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
    tx.update(ref, {
      status: "declined",
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
    const opponentRating = (oppSnap.get("rating") as number) ?? 1500;
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

    const ref = db.collection("stakes").doc();
    await ref.set({
      kind: "challenge_up", // distinguishes from peer stakes
      issuerId,
      opponentId,
      circleId, // the circle it was issued from (for the accept deep-link)
      status: "pending",
      gameId: null,
      pot: null,
      settledResult: null,
      settled: false,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

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
 * live rating gap and balances, validates each against the 30% cap and the
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

      // Live ratings (for the formula) and balances (for the cap).
      const issuerProfileSnap = await tx.get(
        db.collection("users").doc(issuerId)
      );
      const opponentProfileSnap = await tx.get(
        db.collection("users").doc(opponentId)
      );
      const issuerRating =
        (issuerProfileSnap.get("rating") as number) ?? 1500;
      const opponentRating =
        (opponentProfileSnap.get("rating") as number) ?? 1500;

      const issuerBal = await computeBalanceInTx(tx, issuerId);
      const opponentBal = await computeBalanceInTx(tx, opponentId);

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

      // Asymmetric stakes: each stakes their OWN challenge-up fraction, vs the
      // other's rating, against their OWN balance. Underdog (lower rating)
      // → larger fraction; favorite → smaller. (CP = the entry fee for the
      // rating shot.)
      const issuerStake = challengeStakeAmount(
        issuerRating,
        opponentRating,
        issuerBal
      );
      const opponentStake = challengeStakeAmount(
        opponentRating,
        issuerRating,
        opponentBal
      );

      if (issuerStake < MIN_STAKE || opponentStake < MIN_STAKE) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          `Both stakes must be at least ${MIN_STAKE} CP.`
        );
      }
      if (issuerBal < issuerStake) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "The challenger no longer has enough CP."
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

      // Asymmetric escrow locks.
      appendEntry(tx, {
        account: issuerId,
        amount: -issuerStake,
        type: "stake_lock",
        gameId: gameRef.id,
        meta: { stakeId, kind: "challenge_up" },
      });
      appendEntry(tx, {
        account: opponentId,
        amount: -opponentStake,
        type: "stake_lock",
        gameId: gameRef.id,
        meta: { stakeId, kind: "challenge_up" },
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
