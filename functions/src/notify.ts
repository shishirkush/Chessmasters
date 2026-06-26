/**
 * Chess Masters — in-app notification helper.
 *
 * One `notifications/{id}` doc per (recipient, event). Server-only writes; the
 * client lists its own notifications (recipientId == uid) to drive a global
 * bell + notification center. Every async event a player needs to know about
 * (join requests, stake/challenge offers, breach, gauntlet nomination, a game
 * waiting to start, activation, forfeits, expiries) writes one of these.
 *
 * Two entry points:
 *   - notifyTx(tx, ...)   write inside an existing Firestore transaction (so the
 *                         notification is atomic with the state change).
 *   - notify(...)         standalone write (for non-transactional callers).
 *
 * When FCM is added later, it hooks in HERE (after the doc write) so push
 * delivery rides on the same call sites — no second pass over the functions.
 */

import { FieldValue } from "firebase-admin/firestore";
import { db } from "./init";

export type NotificationType =
  | "join_request" // owner: someone asked to join your circle
  | "join_approved" // requester: you were let in
  | "join_rejected" // requester: your request was declined
  | "stake_offer" // opponent: a peer stake was proposed to you
  | "challenge_up" // opponent: you were challenged up
  | "stake_accepted" // proposer: your offer was accepted
  | "stake_declined" // proposer: your offer was declined
  | "breach_initiated" // circle members: a breach was mounted
  | "breach_won" // breach winner (challenger or defender) — positive outcome
  | "breach_lost" // breach loser — negative outcome
  | "member_left" // owner: a member left your circle
  | "gauntlet_nominated" // defender: you were nominated for the gauntlet
  | "game_ready" // player: a staked game is waiting for you to ready up
  | "game_activated" // player: both ready — your game is live
  | "forfeit" // player: a game/stake was forfeited (no-show)
  | "expired"; // player: an offer/window expired with no consequence

export interface NotifyInput {
  recipientId: string;
  type: NotificationType;
  title: string;
  body: string;
  /** ids the client uses to navigate (circleId, stakeId, gameId, …). */
  data?: Record<string, string>;
}

function buildDoc(input: NotifyInput) {
  return {
    recipientId: input.recipientId,
    type: input.type,
    title: input.title,
    body: input.body,
    data: input.data ?? {},
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  };
}

/** Write a notification inside an existing transaction (atomic with the change). */
export function notifyTx(
  tx: FirebaseFirestore.Transaction,
  input: NotifyInput
): void {
  // Never notify yourself about your own action.
  if (!input.recipientId) return;
  const ref = db.collection("notifications").doc();
  tx.set(ref, buildDoc(input));
}

/** Write a notification outside a transaction. */
export async function notify(input: NotifyInput): Promise<void> {
  if (!input.recipientId) return;
  await db.collection("notifications").add(buildDoc(input));
}

/**
 * Delete pending offer notifications (stake_offer / challenge_up) tied to a
 * given stakeId, once that offer is resolved (accepted / declined / cancelled).
 * These are transient calls-to-action; once the offer is gone they're stale and
 * tapping them would dead-end. Best-effort, non-transactional.
 */
export async function deleteOfferNotifications(stakeId: string): Promise<void> {
  if (!stakeId) return;
  try {
    const snap = await db
      .collection("notifications")
      .where("data.stakeId", "==", stakeId)
      .get();
    if (snap.empty) return;
    const batch = db.batch();
    for (const d of snap.docs) {
      const t = d.data().type as string | undefined;
      if (t === "stake_offer" || t === "challenge_up") {
        batch.delete(d.ref);
      }
    }
    await batch.commit();
  } catch (e) {
    // Cleanup is best-effort; never throw from it.
    console.error("deleteOfferNotifications failed", e);
  }
}

/**
 * Delete the breach_initiated notifications fanned out to circle members, once
 * the breach is resolved (won or failed). Matched by data.conquestId.
 * Best-effort; never throws.
 */
export async function deleteBreachNotifications(
  conquestId: string
): Promise<void> {
  if (!conquestId) return;
  try {
    const snap = await db
      .collection("notifications")
      .where("data.conquestId", "==", conquestId)
      .where("type", "==", "breach_initiated")
      .get();
    if (snap.empty) return;
    const batch = db.batch();
    for (const d of snap.docs) {
      batch.delete(d.ref);
    }
    await batch.commit();
  } catch (e) {
    console.error("deleteBreachNotifications failed", e);
  }
}

/**
 * Delete the transient call-to-action notifications tied to a conquest once it
 * concludes (challenger_won / challenger_ejected). These are the prompts that
 * become meaningless when the conquest is over: the gauntlet nomination prompt,
 * any lingering breach_initiated fan-out, and per-game game_ready/game_activated
 * notes. Terminal RESULT notifications (breach_won/breach_lost and the conquest
 * result) are left for the user to read and dismiss. Matched by data.conquestId.
 * Best-effort; never throws.
 */
export async function deleteConquestNotifications(
  conquestId: string
): Promise<void> {
  if (!conquestId) return;
  try {
    const snap = await db
      .collection("notifications")
      .where("data.conquestId", "==", conquestId)
      .get();
    if (snap.empty) return;
    const transient = new Set([
      "gauntlet_nominated",
      "breach_initiated",
      "game_ready",
      "game_activated",
    ]);
    const batch = db.batch();
    let count = 0;
    for (const d of snap.docs) {
      const t = d.data().type as string | undefined;
      if (t && transient.has(t)) {
        batch.delete(d.ref);
        count++;
      }
    }
    if (count > 0) await batch.commit();
  } catch (e) {
    console.error("deleteConquestNotifications failed", e);
  }
}

export function notifyManyTx(
  tx: FirebaseFirestore.Transaction,
  recipientIds: string[],
  base: Omit<NotifyInput, "recipientId">,
  exclude?: string
): void {
  const seen = new Set<string>();
  for (const rid of recipientIds) {
    if (!rid || rid === exclude || seen.has(rid)) continue;
    seen.add(rid);
    notifyTx(tx, { ...base, recipientId: rid });
  }
}
