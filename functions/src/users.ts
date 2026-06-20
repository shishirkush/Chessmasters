/**
 * Chess Masters — Slice 2b: user profiles + rating (Glicko-2).
 *
 * This module owns the `users/{uid}` profile document. Profiles are created
 * SERVER-SIDE the moment a Firebase Auth user is created (the onCreate
 * trigger below), so:
 *   - every signed-in user is guaranteed exactly one profile,
 *   - the client can never set its own starting rating, and
 *   - rating stays a server-owned, skill-only quantity (the V1 firewall:
 *     money never touches rank).
 *
 * Rating model: Glicko-2. We store the three Glicko-2 state values per user:
 *   rating  — the familiar number shown to players (starts 1500).
 *   rd      — rating deviation: how uncertain we are about the rating.
 *             Starts high (350) for a new player and shrinks as they play,
 *             which is exactly the "provisional" behaviour we want.
 *   vol     — volatility: how erratic the player's results are. Starts 0.06.
 *
 * The actual rating MATH (updating these after a game) lives in glicko.ts and
 * is wired into game-end in a later step. This file just establishes the
 * profile and its starting values.
 */

import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";

const db = admin.firestore();

// ---- Glicko-2 starting values (V1 spec) -----------------------------------

// Every player starts here. 1500 is the Glicko-2 convention and matches the
// locked design (start 1500, floor 500 enforced on update, not here).
export const START_RATING = 1500;
// New players are highly uncertain — a high RD means their rating moves a lot
// at first, then settles. 350 is the standard Glicko-2 starting deviation.
export const START_RD = 350;
// Standard Glicko-2 starting volatility.
export const START_VOL = 0.06;

// ---- Profile creation trigger ---------------------------------------------

/**
 * Fires once, automatically, when a new Firebase Auth user is created
 * (Google sign-in, etc.). Writes their starting profile. Idempotent: if a
 * profile somehow already exists we leave it alone rather than reset rating.
 */
export const onUserCreate = functions.auth.user().onCreate(async (user) => {
  const ref = db.collection("users").doc(user.uid);
  const existing = await ref.get();
  if (existing.exists) {
    // Never clobber an existing profile (would wipe rating). Just ensure the
    // displayName/photo are reasonably fresh and stop.
    return;
  }

  // displayName can be null for some providers; fall back gracefully.
  const displayName =
    user.displayName ||
    (user.email ? user.email.split("@")[0] : null) ||
    "Player";

  await ref.set({
    uid: user.uid,
    displayName,
    photoURL: user.photoURL || null,
    // --- Glicko-2 state ---
    rating: START_RATING,
    rd: START_RD,
    vol: START_VOL,
    // --- lightweight stats (handy for profile screens / leaderboards) ---
    gamesPlayed: 0,
    wins: 0,
    losses: 0,
    draws: 0,
    // provisional = true until the player has enough games for a stable
    // rating. We flip this off later (in the rating-update step) once RD
    // drops below a threshold. For now everyone starts provisional.
    provisional: true,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
});
