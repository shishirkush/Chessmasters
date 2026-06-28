/**
 * Chess Masters — leaderboards (precomputed, hourly).
 *
 * Two boards, both written as single docs that clients read in ONE shot (cheap,
 * fast, scale-safe) rather than each viewer running heavy queries:
 *
 *   leaderboards/players — all players with >= MIN_GAMES rated games, ranked by
 *     rating desc, top PLAYER_TOP_N.
 *
 *   leaderboards/circles — circles with >= MIN_CIRCLE_SIZE members, ranked by a
 *     "top quartile" score: the average rating of the top ceil(0.25 * size)
 *     ELIGIBLE members (eligible = >= MIN_GAMES games), but ONLY if the circle
 *     has at least that many eligible members (Option 2 — stricter: we never
 *     average fewer than the intended quartile count). Circles that can't fill
 *     the quartile with eligible members are omitted until enough members rate.
 *
 * WHY PRECOMPUTED (not a client query): the circle score is an average of the
 * top-quartile of a FILTERED subset of each circle's members — not expressible
 * as a Firestore query or aggregation. Computing it client-side would mean every
 * viewer reads every circle and every member. So a scheduled function does it
 * once an hour and writes the ranked result.
 *
 * SCHEDULER CAVEAT: like the expiry sweep, the hourly trigger only fires in
 * PRODUCTION (Cloud Scheduler). The emulator never runs it, so the compute logic
 * is factored into `computeLeaderboards()` which a temporary trigger can invoke
 * for testing. The boards are stale between runs (up to an hour) — expected.
 */

import * as functions from "firebase-functions/v1";
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./init";

// ---- Dials ----------------------------------------------------------------

/** A player/member must have at least this many rated games to be eligible. */
const MIN_GAMES = 10;

/** A circle must have at least this many members to be listed at all. */
const MIN_CIRCLE_SIZE = 10;

/** How many players to keep on the player board. */
const PLAYER_TOP_N = 100;

/** How many circles to keep on the circle board. */
const CIRCLE_TOP_N = 100;

/** Default rating if a user doc somehow lacks one. */
const DEFAULT_RATING = 1500;

// ---- Types ----------------------------------------------------------------

interface PlayerEntry {
  uid: string;
  displayName: string;
  rating: number;
  gamesPlayed: number;
  photoURL: string | null;
}

interface CircleEntry {
  circleId: string;
  name: string;
  ownerId: string;
  score: number; // top-quartile average rating
  memberCount: number;
  quartileCount: number; // how many members fed the score
}

// ---- Compute (shared by the scheduled fn and any test trigger) -------------

/**
 * Compute both boards and write them. Reads all users once (the player board and
 * the per-member ratings for circles both need them), builds a uid->rating map,
 * then walks circles. Idempotent: overwrites the board docs each run.
 */
export async function computeLeaderboards(): Promise<{
  players: number;
  circles: number;
}> {
  // ---- Read all users once; build the player board + a rating lookup. -----
  const usersSnap = await db.collection("users").get();

  const ratingByUid = new Map<string, number>();
  const gamesByUid = new Map<string, number>();
  const eligiblePlayers: PlayerEntry[] = [];

  for (const doc of usersSnap.docs) {
    const u = doc.data();
    const rating = typeof u.rating === "number" ? u.rating : DEFAULT_RATING;
    const games = typeof u.gamesPlayed === "number" ? u.gamesPlayed : 0;
    ratingByUid.set(doc.id, rating);
    gamesByUid.set(doc.id, games);

    if (games >= MIN_GAMES) {
      eligiblePlayers.push({
        uid: doc.id,
        displayName:
          typeof u.displayName === "string" ? u.displayName : "Player",
        rating,
        gamesPlayed: games,
        photoURL: typeof u.photoURL === "string" ? u.photoURL : null,
      });
    }
  }

  eligiblePlayers.sort((a, b) => b.rating - a.rating);
  const players = eligiblePlayers.slice(0, PLAYER_TOP_N);

  await db.collection("leaderboards").doc("players").set({
    entries: players,
    count: players.length,
    minGames: MIN_GAMES,
    updatedAt: FieldValue.serverTimestamp(),
  });

  // ---- Walk circles; compute the top-quartile-of-eligible score. ----------
  const circlesSnap = await db.collection("circles").get();
  const circleEntries: CircleEntry[] = [];

  for (const doc of circlesSnap.docs) {
    const c = doc.data();
    const members: string[] = Array.isArray(c.members) ? c.members : [];
    if (members.length < MIN_CIRCLE_SIZE) continue; // size gate

    // Quartile count scales with TOTAL membership (ceil of 25%).
    const quartileCount = Math.ceil(0.25 * members.length);

    // Ratings of ELIGIBLE members only (>= MIN_GAMES games).
    const eligibleRatings: number[] = [];
    for (const m of members) {
      if ((gamesByUid.get(m) ?? 0) >= MIN_GAMES) {
        eligibleRatings.push(ratingByUid.get(m) ?? DEFAULT_RATING);
      }
    }

    // OPTION 2 (strict): must have at least `quartileCount` eligible members,
    // so we never average fewer than the intended quartile. Otherwise omit.
    if (eligibleRatings.length < quartileCount) continue;

    eligibleRatings.sort((a, b) => b - a);
    const top = eligibleRatings.slice(0, quartileCount);
    const score = top.reduce((s, r) => s + r, 0) / top.length;

    circleEntries.push({
      circleId: doc.id,
      name: typeof c.name === "string" ? c.name : "Circle",
      ownerId: typeof c.ownerId === "string" ? c.ownerId : "",
      score: Math.round(score * 100) / 100, // 2 dp
      memberCount: members.length,
      quartileCount,
    });
  }

  // Rank by score desc; tie-break by larger membership.
  circleEntries.sort((a, b) =>
    b.score !== a.score ? b.score - a.score : b.memberCount - a.memberCount
  );
  const circles = circleEntries.slice(0, CIRCLE_TOP_N);

  await db.collection("leaderboards").doc("circles").set({
    entries: circles,
    count: circles.length,
    minCircleSize: MIN_CIRCLE_SIZE,
    minGames: MIN_GAMES,
    updatedAt: FieldValue.serverTimestamp(),
  });

  console.log(
    `[leaderboards] wrote ${players.length} players, ${circles.length} circles`
  );
  return { players: players.length, circles: circles.length };
}

// ---- The scheduled function (PROD only; emulator never fires it) ------------

/**
 * Recomputes both boards every hour. Cloud Scheduler invokes this in production;
 * the emulator does not (test via a temporary trigger calling computeLeaderboards).
 */
export const refreshLeaderboards = functions.pubsub
  .schedule("every 60 minutes")
  .onRun(async () => {
    await computeLeaderboards();
    return null;
  });
