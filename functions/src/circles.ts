/**
 * Chess Masters — Slice 2c: circles (social spaces).
 *
 * Data model (from the locked design §10):
 *   circles/{circleId}:
 *     name        — display name
 *     ownerId     — the one user who owns this circle (anchor; can't leave)
 *     members     — array of uids (includes the owner). No size limit.
 *     memberCount — denormalised count for cheap display/search.
 *     createdAt / updatedAt
 *
 * Ownership rules (design §10):
 *   - A user OWNS at most one circle but BELONGS to many.
 *   - The owner CANNOT leave their own circle (prevents orphaned circles).
 *   - Members may leave freely WHEN NOT mid-commitment. (The "can't leave to
 *     dodge a Gauntlet" lock is a conquest/slice-4 concern; here, leaving is
 *     free. We'll add the commitment check when conquest exists.)
 *   - The crown (highest-rated member) is NOT stored — it's computed on read
 *     by sorting members by rating. Zero ceremony, always correct.
 *
 * Deferred to a later slice (noted, not built here):
 *   - Owner-deletes-account → ownership cascades to highest-rated non-owning
 *     member, else circle deleted. This ties into an account-deletion flow we
 *     haven't built yet. deleteCircle (owner-initiated) is provided; the
 *     automatic cascade-on-account-deletion is future work.
 *
 * All writes go through these Cloud Functions (Admin SDK), so Firestore rules
 * keep circles read-only to clients — same integrity model as games/users.
 */

import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";

const db = admin.firestore();

const MAX_NAME_LEN = 40;
const MIN_NAME_LEN = 2;

function requireAuth(context: functions.https.CallableContext): string {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "You must be signed in."
    );
  }
  return context.auth.uid;
}

/**
 * Create a circle. The caller becomes its owner and first member.
 * Enforces the "one owned circle per user" rule.
 */
export const createCircle = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);

  const rawName = typeof data?.name === "string" ? data.name.trim() : "";
  if (rawName.length < MIN_NAME_LEN || rawName.length > MAX_NAME_LEN) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Circle name must be ${MIN_NAME_LEN}-${MAX_NAME_LEN} characters.`
    );
  }

  const userRef = db.collection("users").doc(uid);
  const circleRef = db.collection("circles").doc(); // auto-id

  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    if (!userSnap.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Your profile is not set up yet. Try again in a moment."
      );
    }
    // Enforce one-owned-circle-per-user.
    const existingOwned = userSnap.data()?.ownedCircleId;
    if (existingOwned) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You already own a circle. A user can own only one."
      );
    }

    tx.set(circleRef, {
      name: rawName,
      ownerId: uid,
      members: [uid],
      memberCount: 1,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Track ownership on the user profile so the rule above is O(1) to check.
    tx.set(
      userRef,
      { ownedCircleId: circleRef.id, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  });

  return { circleId: circleRef.id };
});

/**
 * Leave a circle. The owner cannot leave their own circle.
 */
export const leaveCircle = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const circleId = typeof data?.circleId === "string" ? data.circleId : "";
  if (!circleId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "circleId is required."
    );
  }

  const circleRef = db.collection("circles").doc(circleId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(circleRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Circle not found.");
    }
    const c = snap.data()!;
    const members: string[] = Array.isArray(c.members) ? c.members : [];

    if (!members.includes(uid)) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You are not a member of this circle."
      );
    }
    if (c.ownerId === uid) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "The owner cannot leave their own circle. Delete it instead."
      );
    }
    // NOTE (slice 4): block leaving if uid is mid-Gauntlet/defense commitment.

    tx.update(circleRef, {
      members: FieldValue.arrayRemove(uid),
      memberCount: Math.max(0, (c.memberCount ?? members.length) - 1),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { ok: true };
});

/**
 * Delete a circle. Only the owner may delete it. Clears the owner's
 * ownedCircleId so they can create another. (Members keep their personal
 * rating + CP — those live on the user profile, untouched here.)
 */
export const deleteCircle = functions.https.onCall(async (data, context) => {
  const uid = requireAuth(context);
  const circleId = typeof data?.circleId === "string" ? data.circleId : "";
  if (!circleId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "circleId is required."
    );
  }

  const circleRef = db.collection("circles").doc(circleId);
  const userRef = db.collection("users").doc(uid);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(circleRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Circle not found.");
    }
    if (snap.data()?.ownerId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Only the owner can delete this circle."
      );
    }
    // NOTE (slice 4): force-close any active conquest on this circle and
    // refund escrowed CP before deletion.

    tx.delete(circleRef);
    tx.set(
      userRef,
      { ownedCircleId: null, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
  });

  return { ok: true };
});
