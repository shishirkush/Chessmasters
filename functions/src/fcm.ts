/**
 * Chess Masters — FCM push notifications (Stage 1a).
 *
 * WHY A TRIGGER (not inline in notify.ts):
 * notify.ts's header anticipated hooking FCM in "after the doc write". But the
 * three push-worthy events (game_ready, breach_initiated, gauntlet_nominated)
 * are ALL written inside Firestore transactions (notifyTx / notifyManyTx), and
 * you must not send an FCM push inside a transaction — a tx can retry, which
 * would fire duplicate pushes. So instead we react to the COMMITTED fact: a
 * `notifications/{id}` doc was created. One v2 trigger covers every notify path
 * (notify, notifyTx, notifyManyTx) with zero changes to the call sites.
 *
 * POLICY (Stage 1a): only an allowlist of genuinely time-sensitive, actionable
 * notification types push to the phone. Everything else stays in the in-app bell
 * only. This protects popular players from being buzzed by every stake offer /
 * challenge (those pile up quietly in the bell). The allowlist is a plain,
 * easily-edited constant below.
 *
 * PER-USER PREFS (Stage 1b, later): `userWantsPush()` is a seam — it returns
 * true for everyone now, and will become a real per-user preference lookup once
 * the settings UI exists. No rework needed; drop the real check in there.
 *
 * REGION: this is a Firestore trigger, so (like onGameFinished) it must be a v2
 * (Eventarc) function co-located with the database in asia-southeast1.
 *
 * TOKENS: stored at users/{uid}/fcmTokens/{token} — one doc per device, doc id
 * IS the token (slash-free, so a valid id), so stale-token cleanup is a direct
 * delete. registerFcmToken (client → on login + refresh) writes them;
 * unregisterFcmToken (client → on sign-out) removes one.
 */

import * as functions from "firebase-functions/v1";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

import { db } from "./init";

// ---- Push policy ----------------------------------------------------------

/**
 * Notification `type`s that escalate to a phone push. Everything NOT in this set
 * is in-app-bell-only. Keep this tight — each entry is an interruption.
 *
 *   game_ready          a staked game you agreed to is waiting for you to enter.
 *   breach_initiated    your circle is under breach — defend to stop them.
 *   gauntlet_nominated  you've been nominated to defend the gauntlet.
 *
 * (Deliberately excluded: stake_offer / challenge_up and all result/info types —
 * they'd flood high-rated players. They remain visible in the bell.)
 */
const PUSH_ALLOWLIST = new Set<string>([
  "game_ready",
  "breach_initiated",
  "gauntlet_nominated",
]);

/**
 * Stage 1b seam: does this user want a push for this type? Returns true for all
 * users in Stage 1a (the allowlist + sensible defaults ARE the policy for now).
 * Becomes a per-user preference lookup when the settings screen is built.
 */
async function userWantsPush(_uid: string, _type: string): Promise<boolean> {
  return true;
}

// ---- Token registration (client callables) --------------------------------

function requireAuth(context: functions.https.CallableContext): string {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be signed in."
    );
  }
  return context.auth.uid;
}

function tokensCol(uid: string) {
  return db.collection("users").doc(uid).collection("fcmTokens");
}

/**
 * Save (upsert) the caller's FCM device token. Client calls this on app start
 * after sign-in and again whenever the token refreshes. Idempotent: re-saving
 * the same token just bumps updatedAt.
 */
export const registerFcmToken = functions.https.onCall(
  async (data, context) => {
    const uid = requireAuth(context);
    const token = typeof data?.token === "string" ? data.token.trim() : "";
    if (!token) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "token is required."
      );
    }
    const platform =
      typeof data?.platform === "string" ? data.platform : "android";

    await tokensCol(uid).doc(token).set({
      token,
      platform,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { ok: true };
  }
);

/**
 * Remove a token from the caller's device list. Client calls this on sign-out so
 * the device stops receiving pushes meant for this account (important when a
 * different account later signs in on the same device).
 */
export const unregisterFcmToken = functions.https.onCall(
  async (data, context) => {
    const uid = requireAuth(context);
    const token = typeof data?.token === "string" ? data.token.trim() : "";
    if (!token) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "token is required."
      );
    }
    await tokensCol(uid).doc(token).delete();
    return { ok: true };
  }
);

// ---- The push trigger (v2, asia-southeast1) -------------------------------

/**
 * Fires when a notification doc is created. If its type is push-worthy and the
 * recipient opted in, send a push to all the recipient's device tokens, and
 * prune any tokens the FCM service reports as dead.
 */
export const onNotificationCreated = onDocumentCreated(
  { document: "notifications/{notifId}", region: "asia-southeast1" },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const n = snap.data();

    const recipientId: string | undefined =
      typeof n.recipientId === "string" ? n.recipientId : undefined;
    const type: string | undefined =
      typeof n.type === "string" ? n.type : undefined;
    if (!recipientId || !type) return;

    // Policy gate 1: is this type push-worthy at all?
    if (!PUSH_ALLOWLIST.has(type)) return;
    // Policy gate 2 (Stage 1b seam): does this user want it? (true for now)
    if (!(await userWantsPush(recipientId, type))) return;

    // Look up the recipient's device tokens.
    const tokSnap = await tokensCol(recipientId).get();
    if (tokSnap.empty) return; // no devices registered → nothing to send
    const tokens = tokSnap.docs.map((d) => d.id);

    const title = typeof n.title === "string" ? n.title : "Chess Masters";
    const body = typeof n.body === "string" ? n.body : "";
    // notify.ts stores data as Record<string,string>; FCM data must be strings.
    const baseData: Record<string, string> =
      n.data && typeof n.data === "object"
        ? (n.data as Record<string, string>)
        : {};
    // Include the type (and our notif id) so the client can route on tap later.
    const data: Record<string, string> = {
      ...baseData,
      type,
      notifId: event.params.notifId,
    };

    let resp;
    try {
      resp = await getMessaging().sendEachForMulticast({
        tokens,
        notification: { title, body },
        data,
        android: {
          priority: "high",
          notification: {
            // Default channel; client can customize later. Tag dedupes repeats.
            tag: data.gameId || data.conquestId || type,
          },
        },
      });
    } catch (e) {
      console.error("[fcm] send failed", e);
      return;
    }

    // Prune dead tokens so we don't keep trying them (and the list stays clean).
    const dead: string[] = [];
    resp.responses.forEach((r, i) => {
      if (r.success) return;
      const code = r.error?.code || "";
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token" ||
        code === "messaging/invalid-argument"
      ) {
        dead.push(tokens[i]);
      } else {
        // Other errors (transient/network) — log but keep the token.
        console.error(`[fcm] send error for a token (${code})`, r.error);
      }
    });
    if (dead.length > 0) {
      await Promise.all(
        dead.map((t) => tokensCol(recipientId).doc(t).delete())
      );
    }

    console.log(
      `[fcm] type=${type} recipient=${recipientId} tokens=${tokens.length} ` +
        `sent=${resp.successCount} failed=${resp.failureCount} pruned=${dead.length}`
    );
  }
);
