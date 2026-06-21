/**
 * Chess Masters — Firebase Admin initialization.
 *
 * WHY THIS FILE EXISTS:
 * Several modules call `admin.firestore()` at module top-level
 * (`const db = admin.firestore()`). ES module imports are hoisted and run
 * before the rest of index.ts, so if `admin.initializeApp()` lived only in
 * index.ts's body, a top-level `admin.firestore()` in an imported module would
 * run FIRST and crash with "The default Firebase app does not exist."
 *
 * By putting initializeApp() here and importing this module FIRST (before any
 * module that touches firestore), initialization is guaranteed to happen before
 * any `admin.firestore()` call, regardless of import graph ordering.
 */

import * as admin from "firebase-admin";

if (admin.apps.length === 0) {
  admin.initializeApp();
}

export const db = admin.firestore();
