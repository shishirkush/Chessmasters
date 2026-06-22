/**
 * Chess Masters — Slice 3d: the challenge-up cost formula (LOCKED, §5).
 *
 * When you stake to challenge a HIGHER-rated player (or play a staked outside
 * match against anyone on the open ladder), the stake is "win-improbability
 * based": the less likely your upset, the more it costs. This is self-balancing
 * and hard to game — you can't cheaply farm a much stronger player.
 *
 * Formula (locked):
 *   expectedScore = 1 / (1 + 10^((targetRating - challengerRating) / 400))
 *   stakeFraction = baseFraction + (1 - expectedScore) * spread
 *   stake = clamp(stakeFraction, 0..MAX) * challengerBalance, floored to int
 *
 * Dials (starting values):
 *   baseFraction = 0.05
 *   spread       = 0.35
 *   MAX cap      = 0.40  (the §5 40%-of-balance hard cap)
 *
 * Note `expectedScore` is the Elo expectation. If the challenger is much
 * lower-rated, expectedScore → 0, so (1 - expectedScore) → 1 and the fraction
 * approaches base + spread = 0.40, which the 40% cap then clamps to 0.40. If
 * evenly matched, expectedScore = 0.5, fraction = 0.05 + 0.175 = 0.225.
 */

export const CHALLENGE_BASE_FRACTION = 0.05;
export const CHALLENGE_SPREAD = 0.35;
export const CHALLENGE_MAX_FRACTION = 0.4; // §5 hard cap

/** Elo expected score for the challenger vs the target. */
export function expectedScore(
  challengerRating: number,
  targetRating: number
): number {
  return 1 / (1 + Math.pow(10, (targetRating - challengerRating) / 400));
}

/** The raw stake fraction (before the cap) for a challenge-up. */
export function challengeStakeFraction(
  challengerRating: number,
  targetRating: number
): number {
  const exp = expectedScore(challengerRating, targetRating);
  const frac = CHALLENGE_BASE_FRACTION + (1 - exp) * CHALLENGE_SPREAD;
  return Math.min(frac, CHALLENGE_MAX_FRACTION);
}

/**
 * The integer CP stake for a challenge-up: the capped fraction of the
 * challenger's CURRENT balance, floored to a whole number (CP is integer-only;
 * stakes never exceed the fraction implied).
 */
export function challengeStakeAmount(
  challengerRating: number,
  targetRating: number,
  challengerBalance: number
): number {
  const frac = challengeStakeFraction(challengerRating, targetRating);
  return Math.floor(challengerBalance * frac);
}

/**
 * A coarse difficulty label for presentation (players never see the formula —
 * §5). Based on the challenger's win expectation.
 */
export function difficultyLabel(
  challengerRating: number,
  targetRating: number
): string {
  const exp = expectedScore(challengerRating, targetRating);
  if (exp >= 0.45) return "Even";
  if (exp >= 0.3) return "Tough";
  if (exp >= 0.15) return "Hard";
  return "Long shot";
}
