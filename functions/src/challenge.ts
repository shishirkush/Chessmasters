/**
 * Chess Masters — CP stake-sizing (LOCKED, §5). Glicko-2 throughout.
 *
 * Two staking shapes share this module, both driven by the SAME Glicko-2 win
 * probability (glicko.ts `winProbability`) — there is NO Elo anywhere:
 *
 *   1. challengeStakeAmount() — the "win-improbability" fraction-of-balance
 *      stake used by challenge-up (proposeChallengeUp/acceptChallengeUp) and by
 *      conquest (breach + gauntlet). Each player stakes a fraction of their OWN
 *      balance, scaled by how unlikely their win is. The underdog stakes a LARGE
 *      fraction (an improbable upset is an expensive ticket); the favorite a
 *      SMALL fraction. Clamped at the §5 hard cap (40% of balance).
 *
 *   2. lobbyAccepterStake() — the OPEN-LOBBY accept stake. Here the POSTER picks
 *      an exact stake S (200+, in 50s, up to 40% of their balance); the ACCEPTER
 *      then stakes an amount ANCHORED to S and scaled by the Glicko win odds:
 *      a favorite stakes more than S (up to 3×), an underdog less (down to the
 *      200 floor). This makes small, accessible seats possible (the poster can
 *      choose 200) while keeping the bet fair by the rating gap.
 *
 * WHY GLICKO-2 (not Elo): the win probability is RD-weighted (see glicko.ts).
 * A rating gap between two UNCERTAIN players (high RD) counts for less, so stake
 * spreads are gentle while ratings are unsettled and steepen as players mature
 * and their RD shrinks. Stakes self-calibrate to how trustworthy the gap is.
 *
 * SCALE NOTE: CP is integer-only and runs at the 10× base unit (see ledger.ts),
 * so "fractions of balance" land on stakes in the hundreds; everything is
 * floored/rounded to whole CP here.
 */

import { winProbability } from "./glicko";
import { MIN_STAKE, MAX_STAKE_FRACTION } from "./ledger";

// ---- Challenge-up / conquest: win-improbability fraction-of-balance --------

/** Base fraction every staker pays, before the rating-gap term. */
export const CHALLENGE_BASE_FRACTION = 0.05;
/** How much the (1 - winProb) term can add on top of the base. */
export const CHALLENGE_SPREAD = 0.35;
/** §5 hard cap: no stake exceeds this fraction of the staker's balance. */
export const CHALLENGE_MAX_FRACTION = MAX_STAKE_FRACTION; // 0.40

export interface RatedPlayer {
  rating: number;
  rd: number;
}

/**
 * The raw stake fraction (before the cap) for `player` vs `opponent`: the less
 * likely the player's win, the larger the fraction. Uses the Glicko-2 win
 * probability (RD-weighted), so an uncertain opponent compresses the spread.
 */
export function challengeStakeFraction(
  player: RatedPlayer,
  opponent: RatedPlayer
): number {
  const winProb = winProbability(player, opponent);
  const frac = CHALLENGE_BASE_FRACTION + (1 - winProb) * CHALLENGE_SPREAD;
  return Math.min(frac, CHALLENGE_MAX_FRACTION);
}

/**
 * The integer CP stake for `player` vs `opponent`: the capped fraction of the
 * player's CURRENT balance, floored to a whole number (CP is integer-only).
 *
 * Used by challenge-up (both legs) and conquest (breach stake, gauntlet stake).
 * Object-pair signature: each player is {rating, rd} so the RD is always carried
 * to the Glicko win-probability and call sites can't transpose bare numbers.
 */
export function challengeStakeAmount(
  player: RatedPlayer,
  opponent: RatedPlayer,
  playerBalance: number
): number {
  const frac = challengeStakeFraction(player, opponent);
  return Math.floor(playerBalance * frac);
}

// ---- Open lobby: poster-anchored, odds-scaled accepter stake ---------------

/**
 * Lobby accepter stake dials (LOCKED):
 *   floor   200  — accepter never stakes below this (monetization floor; also
 *                  keeps the 5% pot rake a clean integer). Same number as the
 *                  poster's posting floor, but a SEPARATE rule (this clamps the
 *                  accepter's COMPUTED stake; the poster floor clamps the
 *                  poster's CHOSEN stake).
 *   ceiling 3×S  — accepter never stakes more than 3× the poster's stake. The
 *                  Glicko odds ratio winProb/(1-winProb) explodes for big
 *                  favorites; this caps the runaway (beyond it the favorite just
 *                  gets a slightly favorable bet — incentive to accept). Equal
 *                  ratings land at 1× (symmetric) naturally; the cap only bites
 *                  at the high end. The 40% balance cap also applies (take the
 *                  lower of the two).
 *   no damping   — the multiplier is the RAW odds ratio; we do NOT soften it
 *                  with an exponent. Glicko's own RD-weighting IS the softener
 *                  (and it fades as ratings mature), so a second damping term
 *                  would double-flatten. This is what makes lobby spreads gentle
 *                  early and steepen as the population's RD shrinks.
 */
export const LOBBY_ACCEPTER_FLOOR = MIN_STAKE > 200 ? MIN_STAKE : 200; // 200
export const LOBBY_CEILING_MULT = 3; // accepter ≤ 3× the poster's stake
/** Poster picks S in steps of this, starting at the floor (200, 250, 300, …). */
export const LOBBY_STAKE_STEP = 50;

/**
 * The integer CP the ACCEPTER stakes when taking a lobby seat whose poster
 * staked `posterStake` (S). The accepter's stake is anchored to S and scaled by
 * the Glicko-2 win odds, then clamped:
 *
 *   raw = round( S * p/(1-p) )                          p = P(accepter beats poster)
 *   stake = clamp( raw, 200, min(3*S, 40% of accepterBalance) )
 *
 * - Equal ratings  → p≈0.5 → raw≈S → symmetric.
 * - Favorite       → p>0.5 → raw>S, capped at 3*S (and the 40% balance cap).
 * - Underdog       → p<0.5 → raw<S, floored at 200.
 *
 * Returns the clamped integer stake. The CALLER must still verify the accepter
 * can afford it (balance ≥ stake) and reject if the usable ceiling falls below
 * the 200 floor (i.e. 40% of their balance < 200 → they simply can't take this
 * seat; it stays open for someone who can).
 */
export function lobbyAccepterStake(
  posterStake: number,
  accepter: RatedPlayer,
  poster: RatedPlayer,
  accepterBalance: number
): number {
  const p = winProbability(accepter, poster);
  // Guard the asymptote: p extremely close to 1 would blow up the ratio; the
  // 3× ceiling catches it regardless, but clamp p defensively for safe math.
  const pSafe = Math.min(Math.max(p, 1e-6), 1 - 1e-6);
  const raw = Math.round(posterStake * (pSafe / (1 - pSafe)));

  const balanceCap = Math.floor(accepterBalance * MAX_STAKE_FRACTION);
  const ceiling = Math.min(LOBBY_CEILING_MULT * posterStake, balanceCap);

  // Apply the floor, then the ceiling. If ceiling < floor (the accepter's 40%
  // cap is below 200), this returns `ceiling` (< 200): the caller detects
  // stake < floor / unaffordable and rejects the accept.
  const floored = Math.max(raw, LOBBY_ACCEPTER_FLOOR);
  return Math.min(floored, ceiling);
}

/**
 * Validate a poster's CHOSEN lobby stake S against the posting rules:
 *   - at least the 200 floor,
 *   - at most 40% of the poster's balance (the §5 cap),
 *   - a multiple of 50 above the floor (200, 250, 300, …).
 * Returns null if valid, or a human-readable reason string if not.
 *
 * Note: if 40% of the poster's balance is below 200, they cannot post at all
 * (their cap can't reach the floor) — the caller surfaces "need ≥ X CP".
 */
export function validateLobbyPosterStake(
  stake: number,
  posterBalance: number
): string | null {
  if (!Number.isInteger(stake)) {
    return "Stake must be a whole number of CP.";
  }
  const cap = Math.floor(posterBalance * MAX_STAKE_FRACTION);
  if (cap < LOBBY_ACCEPTER_FLOOR) {
    return `You need at least ${Math.ceil(
      LOBBY_ACCEPTER_FLOOR / MAX_STAKE_FRACTION
    )} CP to post a lobby seat.`;
  }
  if (stake < LOBBY_ACCEPTER_FLOOR) {
    return `Minimum lobby stake is ${LOBBY_ACCEPTER_FLOOR} CP.`;
  }
  if (stake > cap) {
    return `Stake exceeds ${Math.round(
      MAX_STAKE_FRACTION * 100
    )}% of your balance (max ${cap} CP).`;
  }
  if ((stake - LOBBY_ACCEPTER_FLOOR) % LOBBY_STAKE_STEP !== 0) {
    return `Stake must be in steps of ${LOBBY_STAKE_STEP} CP (e.g. ${LOBBY_ACCEPTER_FLOOR}, ${
      LOBBY_ACCEPTER_FLOOR + LOBBY_STAKE_STEP
    }, ${LOBBY_ACCEPTER_FLOOR + 2 * LOBBY_STAKE_STEP}).`;
  }
  return null;
}
