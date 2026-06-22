/**
 * Chess Masters — Slice 1 (updated to current V1 spec)
 * Authoritative game engine running in Firebase Cloud Functions.
 *
 * CORE RULE: the client never decides game truth. The Flutter app only
 * sends "intents" (createGame / joinGame / makeMove / resign / claimTimeout).
 * These functions validate everything with chess.js and the SERVER clock,
 * and are the ONLY writers of game state. Firestore rules make game docs
 * read-only to clients, so a modified app cannot fake a move, a result,
 * or the time.
 *
 * V1 additions over the original slice 1:
 *  - 5+3 blitz clock, computed server-side (never trust client time).
 *  - 90-second abandonment / disconnection rule (loss; draw if both gone).
 *  - gameType/context tag so later slices (CP, conquest) can attach
 *    consequences to a finished game without changing this engine.
 */

import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
// Import FieldValue directly — the admin.firestore.FieldValue static path
// can be undefined depending on the firebase-admin version, which caused
// "Cannot read properties of undefined (reading 'serverTimestamp')".
import { FieldValue } from "firebase-admin/firestore";
import { Chess } from "chess.js";
import {
  getCountsInTx,
  bumpQuickMatch,
  bumpOpponent,
  QUICK_MATCH_DAILY_CAP,
  SAME_OPPONENT_DAILY_CAP,
} from "./counters";

import { db } from "./init";

// ---- Constants (V1 spec) ---------------------------------------------------

const STARTING_FEN =
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

// Single fixed blitz control for the whole app: 5+3.
const INITIAL_MS = 5 * 60 * 1000; // 5 minutes per player
const INCREMENT_MS = 3 * 1000;    // +3 seconds per move

// Abandonment: if the player to move is unresponsive this long past their
// clock running out OR without interaction, the game can be resolved.
// (This is a disconnection/abandonment trigger, not a per-move cap.)
const ABANDON_MS = 90 * 1000;

// ---- Types -----------------------------------------------------------------

type GameStatus = "waiting" | "active" | "finished";
type Result = "white" | "black" | "draw" | null;

// What a game is FOR. Slice 1 only creates "casual" games; later slices
// (CP staking, conquest) create the others and read the result to apply
// consequences. Tagged here so the engine never needs to change.
type GameType =
  | "casual"        // quick-match / unstaked
  | "peer"          // within-circle symmetric stake
  | "challenge_up"  // asymmetric stake vs higher-rated
  | "outside"       // open-ladder staked
  | "breach"        // conquest: breach defense game
  | "gauntlet";     // conquest: a best-of-3 Gauntlet game

interface GameDoc {
  status: GameStatus;
  gameType: GameType;
  // Optional linkage for staked/conquest games (set by later slices; the
  // engine just carries it through untouched).
  contextId: string | null;   // e.g. challenge id / conquest id
  fen: string;                // canonical board state (source of truth)
  moves: string[];            // SAN move history
  turn: "w" | "b";            // whose move it is
  whiteId: string | null;
  blackId: string | null;
  players: string[];
  // ---- Clock (server-authoritative; all times in ms) ----
  whiteMs: number;            // white's remaining time
  blackMs: number;            // black's remaining time
  lastMoveAt: number | null;  // server epoch ms when the current turn began
  result: Result;
  resultReason: string | null; // checkmate|stalemate|draw|resign|timeout|abandon
  createdAt: any; // FieldValue sentinel
  updatedAt: any; // FieldValue sentinel
}

// ---- Helpers ---------------------------------------------------------------

function requireAuth(context: functions.https.CallableContext): string {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "You must be signed in.");
  }
  return context.auth.uid;
}

function now(): number {
  return Date.now();
}

function deriveOutcome(chess: Chess): { result: Result; reason: string } | null {
  if (chess.isCheckmate()) {
    const winner = chess.turn() === "w" ? "black" : "white";
    return { result: winner, reason: "checkmate" };
  }
  if (chess.isStalemate()) return { result: "draw", reason: "stalemate" };
  if (chess.isInsufficientMaterial())
    return { result: "draw", reason: "insufficient_material" };
  if (chess.isThreefoldRepetition())
    return { result: "draw", reason: "threefold_repetition" };
  if (chess.isDraw()) return { result: "draw", reason: "fifty_move_rule" };
  return null;
}

function freshGame(uid: string, gameType: GameType, contextId: string | null): GameDoc {
  return {
    status: "waiting",
    gameType,
    contextId,
    fen: STARTING_FEN,
    moves: [],
    turn: "w",
    whiteId: uid,
    blackId: null,
    players: [uid],
    whiteMs: INITIAL_MS,
    blackMs: INITIAL_MS,
    lastMoveAt: null, // set when the game becomes active
    result: null,
    resultReason: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

// Compute how much time the player-to-move has used since their turn began,
// using the SERVER clock only. Returns the player's remaining ms (clamped at 0)
// and whether they have flagged (run out).
function clockState(g: GameDoc): { remainingMs: number; flagged: boolean; elapsed: number } {
  const remainingForMover = g.turn === "w" ? g.whiteMs : g.blackMs;
  if (g.lastMoveAt == null) {
    return { remainingMs: remainingForMover, flagged: false, elapsed: 0 };
  }
  const elapsed = now() - g.lastMoveAt;
  const remainingMs = Math.max(0, remainingForMover - elapsed);
  return { remainingMs, flagged: remainingMs <= 0, elapsed };
}

// ---- createGame ------------------------------------------------------------

export const createGame = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  // Slice 1: only casual games are created here. Later slices pass a
  // gameType + contextId when they spin up staked/conquest games.
  const gameType: GameType = (data?.gameType as GameType) || "casual";
  const contextId: string | null = data?.contextId ?? null;

  const ref = db.collection("games").doc();
  await ref.set(freshGame(uid, gameType, contextId));
  return { gameId: ref.id };
});

// ---- joinGame --------------------------------------------------------------
// Quick-match (no gameId) or join a specific game (gameId). Transactional so
// two joiners can't claim the same seat. Sets the clock running on activation.

export const joinGame = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const requestedId: string | undefined = data?.gameId;

  return db.runTransaction(async (tx) => {
    let ref: FirebaseFirestore.DocumentReference;
    let opponentId: string;

    // Read this user's daily counts up front (reads-before-writes).
    const myCounts = await getCountsInTx(tx, uid);

    if (requestedId) {
      ref = db.collection("games").doc(requestedId);
      const snap = await tx.get(ref);
      if (!snap.exists)
        throw new functions.https.HttpsError("not-found", "Game not found.");
      const g = snap.data() as GameDoc;
      if (g.status !== "waiting")
        throw new functions.https.HttpsError("failed-precondition", "Game is not open to join.");
      if (g.whiteId === uid)
        throw new functions.https.HttpsError("failed-precondition", "You cannot join your own game.");
      opponentId = g.whiteId as string;

      // Casual game → quick-match cap applies to the joiner.
      if (g.gameType === "casual" &&
          myCounts.quickMatchCount >= QUICK_MATCH_DAILY_CAP) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `Daily quick-match limit reached (${QUICK_MATCH_DAILY_CAP}/day).`
        );
      }
      // Anti-collusion cap: ≤3 games/day vs the same opponent.
      if ((myCounts.opponentCounts[opponentId] || 0) >= SAME_OPPONENT_DAILY_CAP) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `Daily limit reached against this opponent (${SAME_OPPONENT_DAILY_CAP}/day).`
        );
      }
    } else {
      // Quick match: enforce the casual cap up front.
      if (myCounts.quickMatchCount >= QUICK_MATCH_DAILY_CAP) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `Daily quick-match limit reached (${QUICK_MATCH_DAILY_CAP}/day).`
        );
      }
      // Find one waiting CASUAL game not created by this user.
      const q = await tx.get(
        db.collection("games")
          .where("status", "==", "waiting")
          .where("gameType", "==", "casual")
          .limit(10)
      );
      const candidate = q.docs.find((d) => (d.data() as GameDoc).whiteId !== uid);
      if (!candidate) {
        // No opponent waiting → create a waiting game. This consumes one of the
        // creator's quick-match slots (they've entered a casual game today).
        const newRef = db.collection("games").doc();
        tx.set(newRef, freshGame(uid, "casual", null));
        bumpQuickMatch(tx, uid);
        return { gameId: newRef.id, joined: false, waiting: true };
      }
      ref = candidate.ref;
      opponentId = (candidate.data() as GameDoc).whiteId as string;

      // Same-opponent cap against the waiting game's creator.
      if ((myCounts.opponentCounts[opponentId] || 0) >= SAME_OPPONENT_DAILY_CAP) {
        throw new functions.https.HttpsError(
          "resource-exhausted",
          `Daily limit reached against this opponent (${SAME_OPPONENT_DAILY_CAP}/day).`
        );
      }
    }

    // Activate: black joins, and the clock starts for white (turn 1).
    tx.update(ref, {
      status: "active",
      blackId: uid,
      players: FieldValue.arrayUnion(uid),
      lastMoveAt: now(), // white's clock starts now
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Count this casual game for the joiner (quick-match) and the same-opponent
    // tally for BOTH players (each counts the other).
    bumpQuickMatch(tx, uid);
    bumpOpponent(tx, uid, opponentId);
    bumpOpponent(tx, opponentId, uid);

    return { gameId: ref.id, joined: true, waiting: false };
  });
});

// ---- makeMove --------------------------------------------------------------
// THE authority. Validates turn, legality, AND the server-side clock. Deducts
// the mover's elapsed time, flags them if they ran out, otherwise applies the
// move, adds the increment, and flips the clock to the opponent.

export const makeMove = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const gameId: string = data?.gameId;
  const from: string = data?.from;
  const to: string = data?.to;
  const promotion: string | undefined = data?.promotion;

  if (!gameId || !from || !to)
    throw new functions.https.HttpsError("invalid-argument", "gameId, from and to are required.");

  const ref = db.collection("games").doc(gameId);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists)
      throw new functions.https.HttpsError("not-found", "Game not found.");
    const g = snap.data() as GameDoc;

    if (g.status !== "active")
      throw new functions.https.HttpsError("failed-precondition", "Game is not active.");

    const sideToMove = g.turn;
    const expectedUid = sideToMove === "w" ? g.whiteId : g.blackId;
    if (uid !== expectedUid)
      throw new functions.https.HttpsError("permission-denied", "It is not your turn.");

    // --- Clock check FIRST (server-authoritative) ---
    const { remainingMs, flagged, elapsed } = clockState(g);
    if (flagged) {
      // The mover ran out of time before moving: they lose on time.
      const winner = sideToMove === "w" ? "black" : "white";
      tx.update(ref, {
        status: "finished",
        result: winner,
        resultReason: "timeout",
        whiteMs: sideToMove === "w" ? 0 : g.whiteMs,
        blackMs: sideToMove === "b" ? 0 : g.blackMs,
        updatedAt: FieldValue.serverTimestamp(),
      });
      throw new functions.https.HttpsError(
        "deadline-exceeded",
        "Your time expired — you lost on time."
      );
    }

    // --- Validate and apply the move ---
    const chess = new Chess(g.fen);
    const move = chess.move({ from, to, promotion: promotion as any });
    if (!move)
      throw new functions.https.HttpsError("failed-precondition", "Illegal move.");

    // Deduct elapsed, add the 3s increment, to the mover's clock.
    const newRemaining = remainingMs + INCREMENT_MS;
    const outcome = deriveOutcome(chess);

    const update: Partial<GameDoc> = {
      fen: chess.fen(),
      moves: FieldValue.arrayUnion(move.san) as any,
      turn: chess.turn(),
      whiteMs: sideToMove === "w" ? newRemaining : g.whiteMs,
      blackMs: sideToMove === "b" ? newRemaining : g.blackMs,
      lastMoveAt: now(), // opponent's clock starts now
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (outcome) {
      update.status = "finished";
      update.result = outcome.result;
      update.resultReason = outcome.reason;
      update.lastMoveAt = null; // clock stops on a finished game
    }
    tx.update(ref, update);

    return {
      ok: true,
      san: move.san,
      fen: chess.fen(),
      whiteMs: update.whiteMs,
      blackMs: update.blackMs,
      finished: !!outcome,
      result: outcome?.result ?? null,
      reason: outcome?.reason ?? null,
    };
  });
});

// ---- claimTimeout ----------------------------------------------------------
// Either player may ask the server to check whether the player-to-move has
// flagged (run out of time) or ABANDONED (unresponsive past the 90s window).
// The server decides from its own clock — the claim is just a prompt to check.
// This is how a waiting opponent resolves a stalled/disconnected game without
// trusting any client-reported time.

export const claimTimeout = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const gameId: string = data?.gameId;
  if (!gameId)
    throw new functions.https.HttpsError("invalid-argument", "gameId required.");

  const ref = db.collection("games").doc(gameId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists)
      throw new functions.https.HttpsError("not-found", "Game not found.");
    const g = snap.data() as GameDoc;
    if (g.status !== "active")
      throw new functions.https.HttpsError("failed-precondition", "Game is not active.");
    if (uid !== g.whiteId && uid !== g.blackId)
      throw new functions.https.HttpsError("permission-denied", "You are not in this game.");

    const { remainingMs, flagged, elapsed } = clockState(g);
    const mover = g.turn === "w" ? "white" : "black";

    // Case 1: the player to move has run out of time → they lose on time.
    if (flagged) {
      const winner = g.turn === "w" ? "black" : "white";
      tx.update(ref, {
        status: "finished",
        result: winner,
        resultReason: "timeout",
        whiteMs: g.turn === "w" ? 0 : g.whiteMs,
        blackMs: g.turn === "b" ? 0 : g.blackMs,
        lastMoveAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { resolved: true, result: winner, reason: "timeout" };
    }

    // Case 2: abandonment — the player to move has been unresponsive (no move)
    // for longer than the 90s window even though they still have clock time.
    // (This catches a disconnect/app-close where time hasn't fully run out.)
    if (elapsed >= ABANDON_MS) {
      const winner = g.turn === "w" ? "black" : "white";
      tx.update(ref, {
        status: "finished",
        result: winner,
        resultReason: "abandon",
        lastMoveAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { resolved: true, result: winner, reason: "abandon" };
    }

    // Nothing to resolve yet.
    return { resolved: false, remainingMs };
  });
});

// ---- resign ----------------------------------------------------------------

export const resign = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const gameId: string = data?.gameId;
  if (!gameId)
    throw new functions.https.HttpsError("invalid-argument", "gameId required.");

  const ref = db.collection("games").doc(gameId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists)
      throw new functions.https.HttpsError("not-found", "Game not found.");
    const g = snap.data() as GameDoc;
    if (g.status !== "active")
      throw new functions.https.HttpsError("failed-precondition", "Game is not active.");
    if (uid !== g.whiteId && uid !== g.blackId)
      throw new functions.https.HttpsError("permission-denied", "You are not a player in this game.");

    const winner = uid === g.whiteId ? "black" : "white";
    tx.update(ref, {
      status: "finished",
      result: winner,
      resultReason: "resign",
      lastMoveAt: null,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { ok: true, result: winner };
  });
});

// ---- Slice 2b: user profiles + rating -------------------------------------
// Profile creation trigger (onUserCreate) and rating helpers live in their
// own modules to keep this engine file focused. Re-exported here so the
// Functions runtime discovers and deploys them.
export { onUserCreate } from "./users";
export { onGameFinished } from "./rating";
export { createCircle, leaveCircle, deleteCircle } from "./circles";
export {
  requestJoin,
  cancelJoinRequest,
  approveJoin,
  rejectJoin,
} from "./circles";
export {
  proposeStake,
  acceptStake,
  cancelStake,
  declineStake,
  proposeChallengeUp,
  acceptChallengeUp,
} from "./stakes";
export {
  initiateBreach,
  acceptBreachDefense,
  getBreachEligibility,
} from "./conquest";
