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

import { db } from "./init";

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
//
// CP is an INTEGER-ONLY currency. There is no fractional CP anywhere in the
// system. Every amount stored in the ledger is a whole number. Any computation
// that could produce a fraction (e.g. a percentage stake or rake) is reduced
// to an integer by a single fixed rule (see the helpers at the bottom of this
// file), and the rounding residue is absorbed by the rake → sink, so totals
// always reconcile exactly.
//
// Scale: we use a 10× base unit (vs the raw design numbers) so that typical
// stakes are in the hundreds and the 5%-of-pot rake stays comfortably above 1
// CP — keeping rounding distortion negligible while everything stays integer.

/** Starting grant on first sign-in (§6: ~500 → 10× = 5,000 CP). */
export const STARTING_GRANT = 5000;

/** Daily allotment, once per UTC day on a real-human game (§6: 50 → 500). */
export const DAILY_ALLOTMENT = 500;

/**
 * Rake taken from a settled pot, as a fraction of the pot (§5: 5%). Applied as
 * `round(pot * RAKE_RATE)` — see rakeOf(). The rake is the economy's SINK: it
 * removes CP from circulation on every staked game, holding supply against
 * inflation.
 */
export const RAKE_RATE = 0.05;

/** Minimum stake a player may propose (anti-spam; keeps rake a real integer). */
export const MIN_STAKE = 50;

/** Hard cap: no single stake exceeds this fraction of a player's balance (§5). */
export const MAX_STAKE_FRACTION = 0.40;

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
  // Maintain the denormalized `cp` CACHE on the user doc, ATOMICALLY in the
  // same transaction as the ledger append. This is the single chokepoint: every
  // CP movement goes through appendEntry, so it is structurally impossible to
  // write a ledger entry without updating the cache — they commit together.
  //
  // The ledger remains the SOURCE OF TRUTH; `cp` is a read-optimization only.
  // FieldValue.increment treats a missing field as 0, so the first entry for a
  // user (the starting grant) correctly initializes it. The sink is not a user
  // doc, so we don't cache it (its balance is still fully tracked in the ledger
  // for conservation proofs). updateCpCache() must precede any reads? No —
  // increment is a blind WRITE, valid after the reads-before-writes boundary.
  updateCpCacheInTx(tx, entry.account, entry.amount);
}

/**
 * Apply a `cp` delta to a user's cached balance inside a transaction. Blind
 * write (FieldValue.increment), so it's valid in the writes phase of a tx.
 * Skips the sink (not a user doc). Kept as a named helper so the cache-update
 * rule lives in exactly one place.
 */
function updateCpCacheInTx(
  tx: Transaction,
  account: string,
  delta: number
): void {
  if (account === SINK_ACCOUNT) return;
  const userRef = db.collection("users").doc(account);
  tx.set(userRef, { cp: FieldValue.increment(delta) }, { merge: true });
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
    // Do the create AND the cp-cache increment in ONE transaction so a faucet
    // entry and its cache update commit together (no drift window). tx.create
    // throws ALREADY_EXISTS on a repeat, preserving exactly-once idempotency —
    // and because it's in the tx, a repeat also skips the increment.
    await db.runTransaction(async (tx: Transaction) => {
      tx.create(ref, {
        account: entry.account,
        amount: entry.amount,
        type: entry.type,
        gameId: entry.gameId ?? null,
        meta: entry.meta ?? null,
        createdAt: FieldValue.serverTimestamp(),
      });
      updateCpCacheInTx(tx, entry.account, entry.amount);
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

/**
 * Balance summed INSIDE a transaction, for consistent reads when we're about
 * to spend (staking). Firestore transactions can't aggregate, so we read the
 * account's entries within the tx and sum them. Because escrow locks are
 * negative entries, this sum is the SPENDABLE balance (escrowed CP already
 * excluded). At V1 scale a user has few entries, so this is cheap.
 *
 * IMPORTANT: in a Firestore transaction, all reads must precede all writes.
 * Call this before any tx.set/update in the same transaction.
 */
export async function computeBalanceInTx(
  tx: Transaction,
  account: string
): Promise<number> {
  const q = db.collection("ledger").where("account", "==", account);
  const snap = await tx.get(q);
  let sum = 0;
  snap.forEach((doc) => {
    const a = doc.get("amount");
    if (typeof a === "number") sum += a;
  });
  return sum;
}

/**
 * O(1) spendable balance read INSIDE a transaction: reads the user's cached
 * `cp` field (one doc get) instead of summing every ledger entry. This is the
 * hot-path reader for spend decisions (stake affordability, the 30% cap,
 * gauntlet stake sizing) — transaction-consistent because the cache is written
 * transactionally by appendEntry, so within a tx the field reflects every entry
 * committed before this read.
 *
 * SAFETY FALLBACK: if the `cp` field is missing (an un-migrated profile created
 * before the cache existed, or any anomaly), we DO NOT trust a 0 — that could
 * wrongly block or approve a spend. We fall back to the authoritative ledger
 * sum (computeBalanceInTx) so a missing cache degrades to correct-but-slower,
 * never to a wrong spend decision. Run repairCpCache once to backfill such
 * users and the fast path resumes.
 *
 * Reads-before-writes: this is a READ, so it must precede any tx writes in the
 * same transaction (same as the computeBalanceInTx it replaces — drop-in).
 */
export async function readCpInTx(
  tx: Transaction,
  account: string
): Promise<number> {
  const userRef = db.collection("users").doc(account);
  const snap = await tx.get(userRef);
  const v = snap.get("cp");
  if (typeof v === "number") return v;
  // Missing/non-numeric cache → authoritative fallback (never a wrong 0).
  return computeBalanceInTx(tx, account);
}

/**
 * Reconcile the cached `cp` field against the authoritative ledger sum for one
 * user. Returns { ledger, cached, drift }. drift === 0 means the cache is
 * honest. Use this in a periodic/admin check (or a test) to PROVE the cache
 * never diverges from the ledger; if it ever does, the ledger wins and the
 * cache can be overwritten with `ledger`. The ledger is always the source of
 * truth — the cache is only a read optimization.
 */
export async function reconcileCp(
  account: string
): Promise<{ ledger: number; cached: number; drift: number }> {
  const ledger = await computeBalance(account);
  const snap = await db.collection("users").doc(account).get();
  const cached = (snap.get("cp") as number) ?? 0;
  return { ledger, cached, drift: cached - ledger };
}

/**
 * Overwrite a user's cached `cp` with the authoritative ledger sum. The repair
 * path if reconcileCp ever reports drift. Idempotent and safe to run anytime.
 */
export async function repairCpCache(account: string): Promise<number> {
  const ledger = await computeBalance(account);
  await db
    .collection("users")
    .doc(account)
    .set({ cp: ledger }, { merge: true });
  return ledger;
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

// ---- Faucet: daily allotment ----------------------------------------------

/**
 * The UTC calendar day as YYYY-MM-DD. We deliberately use UTC (not the
 * player's local time) so "one allotment per day" has a single global
 * definition with no timezone edge cases. Players never see this boundary;
 * they just get their daily CP on the day's first real game.
 */
export function utcDayKey(date: Date = new Date()): string {
  return date.toISOString().slice(0, 10); // "2026-06-21"
}

/**
 * Grant a user their daily allotment for the given UTC day. Idempotent per
 * (user, day): the ledger doc ID is `allot_<uid>_<YYYY-MM-DD>`, so no matter
 * how many real games a user plays in a day, they receive at most one
 * allotment. Returns true if it granted, false if already granted today.
 *
 * Engagement gate lives at the CALL SITE (only called from a real-human
 * game-finished event), so this function just enforces once-per-day.
 */
export async function grantDailyAllotment(
  uid: string,
  dayKey: string = utcDayKey()
): Promise<boolean> {
  return appendUniqueEntry(`allot_${uid}_${dayKey}`, {
    account: uid,
    amount: DAILY_ALLOTMENT,
    type: "daily_allotment",
    meta: { day: dayKey },
  });
}

// ---- Integer money math (THE single source of rounding truth) -------------
//
// CP is integer-only. These helpers are the ONLY place fractions get reduced
// to integers, so the rounding rule is defined exactly once and can't drift.

/**
 * The integer stake for a given balance and fraction (e.g. 0.05 of 5000 = 250).
 * Uses floor: a player never stakes more than the fraction implies, and the
 * result is always a whole number ≤ balance.
 */
export function stakeOf(balance: number, fraction: number): number {
  return Math.floor(balance * fraction);
}

/**
 * The integer rake for a pot: round(pot * RAKE_RATE). Rounding residue (the
 * fractional CP that "doesn't exist") is absorbed here and lands in the sink,
 * so winner_credit + rake === pot exactly, with all three integers.
 */
export function rakeOf(pot: number): number {
  return Math.round(pot * RAKE_RATE);
}

/**
 * Split a settled pot into the winner's credit and the rake, as integers that
 * sum EXACTLY to the pot. This is the conservation guarantee in one function:
 * whatever the rounding, credit + rake === pot, no CP minted or lost.
 */
export function settlePot(pot: number): { winnerCredit: number; rake: number } {
  const rake = rakeOf(pot);
  return { winnerCredit: pot - rake, rake };
}