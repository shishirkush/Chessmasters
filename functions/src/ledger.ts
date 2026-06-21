/**
 * Chess Masters — Slice 3a: the CP ledger (append-only, earned-only).
 *
 * THE ONE INVARIANT THIS FILE PROTECTS
 * ------------------------------------
 * CP is only ever:
 *   - CREATED at two faucets   → starting grant, daily allotment
 *   - TRANSFERRED between users → stakes / pots (added in 3c)
 *   - DESTROYED at one sink     → the rake (added in 3c)
 *
 * The ledger is APPEND-ONLY. We never edit a balance in place. A user's
 * balance is ALWAYS derived by summing their ledger entries. This makes the
 * whole economy auditable: every CP that exists can be traced to the faucet
 * that minted it and every movement since.
 *
 * Because balance is a pure sum of entries, ESCROW needs no separate storage:
 * locking a stake is just a negative entry, returning it is a positive entry.
 * Spendable balance therefore automatically excludes escrowed CP. (Staking is
 * built in 3c; the structure here is laid so it slots in without rework.)
 *
 * Every entry is one immutable document in the top-level `ledger` collection:
 *   {
 *     account:   uid | SINK_ACCOUNT      — whose balance this affects
 *     amount:    number (+ credit / - debit)
 *     type:      LedgerEntryType         — why this entry exists
 *     gameId?:   string                  — the game that caused it (if any)
 *     meta?:     object                  — small type-specific extras
 *     createdAt: serverTimestamp
 *   }
 *
 * Entries are NEVER updated or deleted. A correction is a new compensating
 * entry, never an edit. (Firestore rules lock the collection to server-only.)
 */

import * as admin from "firebase-admin";
import { FieldValue, Transaction } from "firebase-admin/firestore";

const db = admin.firestore();

// ---- Accounts -------------------------------------------------------------

/**
 * The sink. Rake flows here and stays here — CP that lands in the sink is
 * effectively destroyed (removed from player circulation). Using a real
 * account (rather than just deleting CP) keeps the books balanced: the sum of
 * ALL accounts including the sink is conserved by every transfer, so we can
 * always prove no CP was minted or lost in a settlement.
 */
export const SINK_ACCOUNT = "__sink__";

// ---- Amounts (dials — starting values from the locked V1 design) ----------

/** Starting grant on first sign-in (§6: ~500 CP). */
export const STARTING_GRANT = 500;

// ---- Entry types ----------------------------------------------------------

/**
 * Every ledger entry declares WHY it exists. Keeping this a closed set makes
 * the ledger self-documenting and lets us audit by type (e.g. "sum all
 * starting_grant entries" = total CP minted by that faucet).
 */
export type LedgerEntryType =
  | "starting_grant" // faucet: one-time grant on profile creation
  | "daily_allotment" // faucet: per-day engagement grant (3b)
  | "stake_lock" // escrow: CP removed from spendable at stake time (3c)
  | "stake_return" // escrow: stake returned (draw / cancelled) (3c)
  | "pot_win" // transfer: winner receives the pot (3c)
  | "rake"; // sink: pot rake destroyed to the sink (3c)

// ---- Append primitive -----------------------------------------------------

export interface LedgerEntryInput {
  account: string;
  amount: number;
  type: LedgerEntryType;
  gameId?: string;
  meta?: Record<string, unknown>;
}

/**
 * Append one entry to the ledger inside a transaction. ALL ledger writes go
 * through here so the shape stays consistent. Uses an auto-ID doc (ordinary
 * entries can legitimately repeat — e.g. many rakes — so they are not
 * deduplicated; the faucets that MUST be unique use deterministic IDs via the
 * dedicated helpers below).
 */
export function appendEntry(tx: Transaction, entry: LedgerEntryInput): void {
  const ref = db.collection("ledger").doc();
  tx.set(ref, {
    account: entry.account,
    amount: entry.amount,
    type: entry.type,
    gameId: entry.gameId ?? null,
    meta: entry.meta ?? null,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/**
 * Append an entry with a CALLER-CHOSEN deterministic doc ID, using create()
 * so a repeat is a hard no-op (the second create throws ALREADY_EXISTS).
 * This is how the faucets guarantee "exactly once": the grant for a user can
 * physically exist at most once because its doc ID is derived from the uid.
 *
 * Returns true if it wrote, false if the entry already existed.
 */
export async function appendUniqueEntry(
  docId: string,
  entry: LedgerEntryInput
): Promise<boolean> {
  const ref = db.collection("ledger").doc(docId);
  try {
    await ref.create({
      account: entry.account,
      amount: entry.amount,
      type: entry.type,
      gameId: entry.gameId ?? null,
      meta: entry.meta ?? null,
      createdAt: FieldValue.serverTimestamp(),
    });
    return true;
  } catch (e: unknown) {
    // ALREADY_EXISTS → the unique entry was already written. That is the
    // whole point (idempotency); swallow it and report "didn't write".
    const code = (e as { code?: number | string }).code;
    if (code === 6 || code === "already-exists") return false;
    throw e;
  }
}

// ---- Balance (pure sum of entries) ----------------------------------------

/**
 * Compute an account's balance by summing its ledger entries. This is the
 * source of truth for balance — there is no stored balance field to drift.
 *
 * NOTE ON SCALE: at V1 scale this is cheap (a user has few entries). If it
 * ever isn't, we add a cached balance doc updated transactionally alongside
 * each append — without changing this being the canonical definition.
 *
 * NOTE FOR STAKING (3c): inside a stake transaction we will sum the relevant
 * entries WITHIN the transaction to get a consistent spendable balance, since
 * Firestore transactions can't run an aggregation. This function is for
 * reads/displays outside a transaction.
 */
export async function computeBalance(account: string): Promise<number> {
  const snap = await db
    .collection("ledger")
    .where("account", "==", account)
    .get();
  let sum = 0;
  snap.forEach((doc) => {
    const a = doc.get("amount");
    if (typeof a === "number") sum += a;
  });
  return sum;
}

// ---- Faucet: starting grant -----------------------------------------------

/**
 * Give a user their one-time starting grant. Idempotent by construction: the
 * ledger entry's doc ID is deterministic (`grant_<uid>`), so calling this
 * twice writes exactly one grant. Safe to call from the (retry-prone) auth
 * trigger.
 */
export async function grantStartingCP(uid: string): Promise<void> {
  await appendUniqueEntry(`grant_${uid}`, {
    account: uid,
    amount: STARTING_GRANT,
    type: "starting_grant",
  });
}
