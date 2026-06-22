/**
 * Chess Masters — Slice 2b step 2: apply Glicko-2 when a game finishes.
 *
 * Design: this is a Firestore onUpdate trigger on games/{gameId}, NOT code
 * inside the engine's transactions. Why decouple it:
 *   - The engine (makeMove/resign/claimTimeout) has FIVE places a game can
 *     become "finished". Wiring rating into each would duplicate logic and
 *     entangle rating reads/writes with the game transaction.
 *   - A trigger reacts to the single observable fact ("this game just became
 *     finished") in one place, no matter how it ended.
 *
 * Correctness guards:
 *   - Only act on the transition into status === "finished".
 *   - Mark the game with ratingApplied:true inside a transaction so a retry
 *     or a duplicate update can never rate the same game twice (idempotent).
 *   - Skip games with no real opponent (e.g. a waiting game that was
 *     cancelled) or unrated game types if we add them later.
 */

import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { updatePlayer, RatingState } from "./glicko";
import { START_RATING, START_RD, START_VOL } from "./users";
import { grantDailyAllotment } from "./ledger";
import { settleStakeForGame } from "./stakes";

import { db } from "./init";

// Below this RD we consider a player's rating "established" (not provisional).
// 110 is a common Glicko-2 threshold; tune later if needed.
const PROVISIONAL_RD = 110;

interface MiniProfile {
  rating: number;
  rd: number;
  vol: number;
  gamesPlayed: number;
  wins: number;
  losses: number;
  draws: number;
}

function readProfile(data: FirebaseFirestore.DocumentData | undefined): MiniProfile {
  // Defensive defaults: if a profile is somehow missing fields, fall back to
  // starting values rather than crash.
  return {
    rating: typeof data?.rating === "number" ? data.rating : START_RATING,
    rd: typeof data?.rd === "number" ? data.rd : START_RD,
    vol: typeof data?.vol === "number" ? data.vol : START_VOL,
    gamesPlayed: typeof data?.gamesPlayed === "number" ? data.gamesPlayed : 0,
    wins: typeof data?.wins === "number" ? data.wins : 0,
    losses: typeof data?.losses === "number" ? data.losses : 0,
    draws: typeof data?.draws === "number" ? data.draws : 0,
  };
}

export const onGameFinished = functions.firestore
  .document("games/{gameId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    // Only act on the transition INTO finished.
    if (!after) return;
    if (before?.status === "finished") return; // was already finished
    if (after.status !== "finished") return;   // not finished yet

    const whiteId: string | null = after.whiteId ?? null;
    const blackId: string | null = after.blackId ?? null;
    const result: string | null = after.result ?? null; // "white"|"black"|"draw"

    // Need two real players and a decisive/draw result to rate.
    if (!whiteId || !blackId || !result) return;

    const gameRef = change.after.ref;
    const whiteRef = db.collection("users").doc(whiteId);
    const blackRef = db.collection("users").doc(blackId);

    await db.runTransaction(async (tx) => {
      // Idempotency: re-read the game inside the tx and bail if already rated.
      const gameSnap = await tx.get(gameRef);
      const g = gameSnap.data();
      if (!g || g.ratingApplied === true) return;

      const whiteSnap = await tx.get(whiteRef);
      const blackSnap = await tx.get(blackRef);
      const white = readProfile(whiteSnap.data());
      const black = readProfile(blackSnap.data());

      // Scores from white's perspective; black is the mirror.
      const whiteScore = result === "white" ? 1 : result === "black" ? 0 : 0.5;
      const blackScore = 1 - whiteScore;

      // IMPORTANT: both players update against the OPPONENT'S PRE-GAME rating.
      // We snapshot both before applying either, so the order doesn't matter.
      const whiteBefore: RatingState = {
        rating: white.rating,
        rd: white.rd,
        vol: white.vol,
      };
      const blackBefore: RatingState = {
        rating: black.rating,
        rd: black.rd,
        vol: black.vol,
      };

      const whiteAfter = updatePlayer(
        whiteBefore,
        { rating: blackBefore.rating, rd: blackBefore.rd },
        whiteScore
      );
      const blackAfter = updatePlayer(
        blackBefore,
        { rating: whiteBefore.rating, rd: whiteBefore.rd },
        blackScore
      );

      // Enforce the rating floor (V1 spec: floor 500).
      const floor = (r: number) => (r < 500 ? 500 : r);

      tx.set(
        whiteRef,
        {
          rating: floor(whiteAfter.rating),
          rd: whiteAfter.rd,
          vol: whiteAfter.vol,
          gamesPlayed: white.gamesPlayed + 1,
          wins: white.wins + (whiteScore === 1 ? 1 : 0),
          losses: white.losses + (whiteScore === 0 ? 1 : 0),
          draws: white.draws + (whiteScore === 0.5 ? 1 : 0),
          provisional: whiteAfter.rd > PROVISIONAL_RD,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      tx.set(
        blackRef,
        {
          rating: floor(blackAfter.rating),
          rd: blackAfter.rd,
          vol: blackAfter.vol,
          gamesPlayed: black.gamesPlayed + 1,
          wins: black.wins + (blackScore === 1 ? 1 : 0),
          losses: black.losses + (blackScore === 0 ? 1 : 0),
          draws: black.draws + (blackScore === 0.5 ? 1 : 0),
          provisional: blackAfter.rd > PROVISIONAL_RD,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // Record the rating delta on the game (handy for an end-of-game screen)
      // and mark it applied so this can never run twice.
      tx.update(gameRef, {
        ratingApplied: true,
        ratingDelta: {
          white: Math.round(floor(whiteAfter.rating) - whiteBefore.rating),
          black: Math.round(floor(blackAfter.rating) - blackBefore.rating),
        },
      });
    });

    // ---- Stake settlement (3c-2) ------------------------------------------
    // If this finished game is a peer staked game, settle its stake: pay the
    // pot (minus rake) to the winner, or return stakes (minus rake) on a draw.
    // The stake is linked via contextId. Idempotent inside settleStakeForGame
    // (the stake's `settled` flag), independent of rating/allotment.
    if (
      (after.gameType === "peer" || after.gameType === "challenge_up") &&
      typeof after.contextId === "string"
    ) {
      try {
        await settleStakeForGame(
          context.params.gameId,
          after.contextId,
          result
        );
      } catch (e) {
        console.error("stake settlement failed", e);
      }
    }
    // Slice 4 will add a sibling block here:
    //   if ((after.gameType === "breach" || after.gameType === "gauntlet")
    //       && typeof after.contextId === "string") {
    //     await settleConquest(context.params.gameId, after.contextId, result);
    //   }
    // (breach/gauntlet route to a NEW one-sided settler, NOT settleStakeForGame)

    // ---- Faucet #2: daily allotment (CP) ----------------------------------
    // Granted to EACH human player for playing a real game today. This is the
    // engagement gate from §6: the main CP source ties to genuine human play,
    // which blocks bot-farming. We do this OUTSIDE the rating transaction and
    // keyed on (user, UTC-day) — independent idempotency from rating's
    // per-game flag, so a rating retry never suppresses (or duplicates) the
    // allotment, and vice versa.
    //
    // Bot/practice games are excluded: when the practice bot is added it will
    // mark games isBotGame:true. Absent the flag (all current real games), we
    // treat it as a real game and grant.
    if (after.isBotGame === true) return;
    try {
      await Promise.all([
        grantDailyAllotment(whiteId),
        grantDailyAllotment(blackId),
      ]);
    } catch (e) {
      // An allotment failure must not crash the trigger (rating already
      // applied). Log and move on; the deterministic ID means a later game
      // the same day will retry harmlessly.
      console.error("daily allotment failed", e);
    }
  });
