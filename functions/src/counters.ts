/**
 * Chess Masters — Slice 3d: daily game counters (the basis for all caps).
 *
 * We track, per user per UTC day, a small counter document:
 *   gameCounts/{uid}_{YYYY-MM-DD} = {
 *     uid, day,
 *     quickMatchCount: number,                 // casual games entered today
 *     opponentCounts: { [oppUid]: number },    // games vs each opponent today
 *     updatedAt
 *   }
 *
 * WHY COUNTER DOCS (not querying games):
 *   - Cap checks become a single O(1) doc read, on the hot path of every game
 *     start — cheaper than counting today's games every time.
 *   - The "≤3 vs the SAME opponent" cap is a trivial map lookup
 *     (opponentCounts[opp]) instead of a filtered query.
 *   - No composite indexes; same deterministic per-day-ID pattern we already
 *     use for grants and allotments.
 *   - We increment INSIDE the game-creation/join transaction, so the counter
 *     and the game commit atomically and can never disagree.
 *
 * Caps (locked V1 §5/§8, dials):
 *   QUICK_MATCH_DAILY_CAP        = 3   (unstaked casual games/day)
 *   SAME_OPPONENT_DAILY_CAP      = 3   (games/day vs the same opponent)
 */

import * as admin from "firebase-admin";
import { FieldValue, Transaction } from "firebase-admin/firestore";
import { utcDayKey } from "./ledger";

import { db } from "./init";

export const QUICK_MATCH_DAILY_CAP = 3;
export const SAME_OPPONENT_DAILY_CAP = 3;

function countsRef(uid: string, day: string) {
  return db.collection("gameCounts").doc(`${uid}_${day}`);
}

interface CountsDoc {
  uid: string;
  day: string;
  quickMatchCount: number;
  opponentCounts: Record<string, number>;
}

function readCounts(
  data: FirebaseFirestore.DocumentData | undefined,
  uid: string,
  day: string
): CountsDoc {
  return {
    uid,
    day,
    quickMatchCount:
      typeof data?.quickMatchCount === "number" ? data.quickMatchCount : 0,
    opponentCounts:
      (data?.opponentCounts as Record<string, number>) || {},
  };
}

/**
 * Read a user's counts for today (outside a transaction) — for display or a
 * cheap pre-check. Authoritative enforcement happens IN-tx via the helpers
 * below so the check and the increment are atomic.
 */
export async function getCountsToday(uid: string): Promise<CountsDoc> {
  const day = utcDayKey();
  const snap = await countsRef(uid, day).get();
  return readCounts(snap.data(), uid, day);
}

/**
 * Read a user's counts for today INSIDE a transaction. Reads-before-writes:
 * call this before any tx writes in the same transaction.
 */
export async function getCountsInTx(
  tx: Transaction,
  uid: string,
  day: string = utcDayKey()
): Promise<CountsDoc> {
  const snap = await tx.get(countsRef(uid, day));
  return readCounts(snap.data(), uid, day);
}

/**
 * Increment a user's quick-match (casual) count by 1, in-tx. Call when a user
 * enters a casual game (creates a waiting one or joins one).
 */
export function bumpQuickMatch(
  tx: Transaction,
  uid: string,
  day: string = utcDayKey()
): void {
  tx.set(
    countsRef(uid, day),
    {
      uid,
      day,
      quickMatchCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

/**
 * Increment the same-opponent count by 1 for `uid` vs `opponentUid`, in-tx.
 * Call once per player at the moment a pairing is finalised (join/accept),
 * for BOTH players (each counts the other).
 */
export function bumpOpponent(
  tx: Transaction,
  uid: string,
  opponentUid: string,
  day: string = utcDayKey()
): void {
  tx.set(
    countsRef(uid, day),
    {
      uid,
      day,
      opponentCounts: { [opponentUid]: FieldValue.increment(1) },
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}
