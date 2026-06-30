/**
 * Chess Masters — Glicko-2 rating system.
 *
 * Pure math, no Firestore. Implemented directly from Mark Glickman's
 * "Example of the Glicko-2 system" (the canonical reference). We update one
 * player against ONE opponent per game (a "rating period" of a single game),
 * which is the simplest correct application for a live 1v1 ladder.
 *
 * Public scale (what we store/show): rating ~1500, rd ~350.
 * Internal scale (Glicko-2 math):    mu, phi   (rating-1500)/173.7178 etc.
 *
 * The only entry point is updatePlayer(): give it the player's current
 * {rating, rd, vol}, the opponent's {rating, rd}, and the score
 * (1 win / 0.5 draw / 0 loss), and it returns the player's new
 * {rating, rd, vol}.
 */

// Glickman's system constant τ ("tau") constrains volatility change over time.
// Smaller = ratings change more conservatively. 0.5 is a common, stable choice.
const TAU = 0.5;
// Convergence tolerance for the volatility iteration.
const EPSILON = 0.000001;
// Scale factor between public ratings and the internal Glicko-2 scale.
const SCALE = 173.7178;

export interface RatingState {
  rating: number; // public rating (e.g. 1500)
  rd: number;     // public rating deviation (e.g. 350)
  vol: number;    // volatility (e.g. 0.06)
}

// g(phi): weights an opponent's influence by how certain their rating is.
function g(phi: number): number {
  return 1 / Math.sqrt(1 + (3 * phi * phi) / (Math.PI * Math.PI));
}

// E(mu, mu_j, phi_j): expected score of player vs opponent j.
function expectedScore(mu: number, muJ: number, phiJ: number): number {
  return 1 / (1 + Math.exp(-g(phiJ) * (mu - muJ)));
}

/**
 * Update one player's rating after a single game.
 *
 * @param player   the player's current public {rating, rd, vol}
 * @param opponent the opponent's current public {rating, rd}
 * @param score    1 = player won, 0.5 = draw, 0 = player lost
 * @returns        the player's new public {rating, rd, vol}
 */
export function updatePlayer(
  player: RatingState,
  opponent: { rating: number; rd: number },
  score: number
): RatingState {
  // Step 2: convert player and opponent to the internal scale.
  const mu = (player.rating - 1500) / SCALE;
  const phi = player.rd / SCALE;
  const sigma = player.vol;

  const muJ = (opponent.rating - 1500) / SCALE;
  const phiJ = opponent.rd / SCALE;

  // Step 3: variance of the estimated rating, from this one game.
  const gPhiJ = g(phiJ);
  const eVal = expectedScore(mu, muJ, phiJ);
  const v = 1 / (gPhiJ * gPhiJ * eVal * (1 - eVal));

  // Step 4: estimated improvement in rating (the "delta").
  const delta = v * gPhiJ * (score - eVal);

  // Step 5: iterate to find the new volatility (sigma').
  const a = Math.log(sigma * sigma);
  const phi2 = phi * phi;
  const delta2 = delta * delta;

  const f = (x: number): number => {
    const ex = Math.exp(x);
    const num = ex * (delta2 - phi2 - v - ex);
    const den = 2 * (phi2 + v + ex) * (phi2 + v + ex);
    return num / den - (x - a) / (TAU * TAU);
  };

  // Bracket the root (Illinois algorithm, per the spec).
  let A = a;
  let B: number;
  if (delta2 > phi2 + v) {
    B = Math.log(delta2 - phi2 - v);
  } else {
    let k = 1;
    while (f(a - k * TAU) < 0) k += 1;
    B = a - k * TAU;
  }

  let fA = f(A);
  let fB = f(B);
  while (Math.abs(B - A) > EPSILON) {
    const C = A + ((A - B) * fA) / (fB - fA);
    const fC = f(C);
    if (fC * fB <= 0) {
      A = B;
      fA = fB;
    } else {
      fA = fA / 2;
    }
    B = C;
    fB = fC;
  }
  const newSigma = Math.exp(A / 2);

  // Step 6: update the rating deviation to the new pre-rating-period value.
  const phiStar = Math.sqrt(phi2 + newSigma * newSigma);

  // Step 7: new phi and mu.
  const newPhi = 1 / Math.sqrt(1 / (phiStar * phiStar) + 1 / v);
  const newMu = mu + newPhi * newPhi * gPhiJ * (score - eVal);

  // Step 8: convert back to the public scale.
  const newRating = SCALE * newMu + 1500;
  const newRd = SCALE * newPhi;

  return {
    rating: newRating,
    rd: newRd,
    vol: newSigma,
  };
}

// ---- Public win-probability (shared by stake-sizing) ----------------------

/**
 * The probability that `player` beats `opponent`, on the Glicko-2 model.
 *
 * This is the SAME expectation the rating update uses internally (E(mu, mu_j,
 * phi_j) above), exposed for reuse by the CP stake-sizing code so that staking
 * and rating speak one language — there is no separate Elo formula anywhere.
 *
 * Glicko-2 (unlike Elo) weights the gap by the OPPONENT's rating deviation via
 * g(phi_j): when the opponent's rating is uncertain (high RD, e.g. a new or
 * provisional player), the result is less predictable, so the probability is
 * pulled toward 0.5 — the rating gap "counts for less". As the opponent's RD
 * shrinks with games played, g(phi_j) -> 1 and this converges toward the plain
 * logistic (Elo-like) curve. This is why stake spreads are gentle while ratings
 * are unsettled and steepen as the population matures.
 *
 * Inputs are PUBLIC-scale {rating, rd} (the values stored on user docs). The
 * conversion to the internal Glicko-2 scale happens here.
 *
 * @returns a probability in (0, 1).
 */
export function winProbability(
  player: { rating: number; rd: number },
  opponent: { rating: number; rd: number }
): number {
  const mu = (player.rating - 1500) / SCALE;
  const muJ = (opponent.rating - 1500) / SCALE;
  const phiJ = opponent.rd / SCALE; // opponent's RD weights the expectation
  return 1 / (1 + Math.exp(-g(phiJ) * (mu - muJ)));
}
