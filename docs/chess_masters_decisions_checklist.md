# Chess Masters — Edge-Case Decisions (RESOLVED)

All edge cases below are DECIDED. Each is now a simple rule the code follows — no ambiguous branches left for the build to agonize over. This is the complexity-reducing payoff: a decided edge case is just "if X, do Y."

---

## A. Conquest / Gauntlet resolution

1. **Two outsiders breach the same circle simultaneously** → the **higher-rated** player's breach proceeds; the other is rejected/deferred.
2. **Challenger wins entry at the instant the owner deletes their account** → **account deletion force-closes** the challenge (CP per #14).
3. **A Gauntlet game finishes as the challenger tries to leave** → the challenger **leaves at the cost of losing that game**.
4. **Owner nominates a defender, but the defender never shows** → after a short wait, the **challenger is accepted** (treated as no defense mounted).
5. **Challenger disconnects mid-Gauntlet game** → 90-second rule: that game is a **loss for the challenger** (counts toward 2-of-3 ejection).
6. **Defender disconnects mid-Gauntlet game** → 90-second rule: that game is a **loss for the defender**.
7. **The breach game ends in a draw** → a draw does **NOT** grant entry; the challenger must **win** the breach. Draw = breach fails; stake per #13.
8. **A Gauntlet game ends in a draw** → counts as neither win nor loss; **replay that game** (best-of-3 needs decisive games).
9. **Breach defense** → **first member to accept defends** (first-come; no owner nomination); if none accept, challenger accepted by default. **Gauntlet defender** → **owner nominates**; if owner offline, next-highest-ranked online member nominates (cascading); if nobody available, challenger accepted. Owner may nominate themselves for the Gauntlet.
10. **Nominated defender is also the eventual crown-holder** → **no conflict**; defending a breach and holding the crown are independent.
11. **Owner tries to delete account during an in-progress breach/Gauntlet** → deletion **force-closes** the conquest immediately; CP per #14.
12. **Challenger abandons after breaching but before/between the Gauntlet** → **leaving not allowed**; after a wait, unplayed Gauntlet games **forfeit as losses** → challenger **ejected** (per 2-of-3); breach stake resolved to the **defender** (#13).

## B. CP escrow

13. **Breach fails (challenger loses or draws the breach game)** → challenger's breach stake **transfers to the defender** (defender won the breach).
14. **Conquest force-closed mid-process** (account deletion, app error) → all escrowed CP is **returned to its original stakers** (challenger's breach stake back to challenger; group's Gauntlet stake back to the group). No burn, no transfer — clean refund.
15. **CP between stake-lock and settlement** → staked CP is **locked at stake time**: removed from spendable balance immediately, held in escrow, cannot be double-spent. (Non-negotiable for correctness.)

## C. Membership / circle

16. **A member leaves a circle (RESHAPED — the key fix):** a member **can leave freely when NOT mid-commitment**. A member **cannot leave to dodge an active Gauntlet/defense** — if committed (opted in, or nominated defender mid-trial), they are locked until it resolves; attempting to leave forfeits per the rules (lose the game / forfeit stake). *This preserves anti-ducking WITHOUT trapping people in circles they were auto-added to.*
17. **Challenger, after becoming a full member, immediately leaves** → allowed (normal member, not mid-commitment, per #16). Refusing to play instead just costs ranking.
18. **A player tries to mount concurrent conquests against different circles** → **ALLOWED** (REVISED 2026-06-25; was "not allowed — one active conquest per attacker"). Aggressive players may breach multiple circles simultaneously, including overlapping breach-accept windows and concurrent Gauntlets. Bounded by CP (each breach locks its own stake). One-active-breach-per-CIRCLE (#1) still enforced.
19. **Breach a circle you were ejected from, before a cooldown** → **V1: allowed (no cooldown)**; cooldown is post-launch.
20. **Breach a circle you're already a member of** → **no**; members use internal challenge / crown contest instead.

## D. Game-level (staked games)

21. **A staked game (peer or outside) ends in a draw** → stakes **returned to both players** (no transfer), minus the **normal 1–2% rake per player** (consistent with all other rakes).
22. **Both players disconnect in a staked game** → draw → stakes returned per #21.
23. **A player disconnects and reconnects within 90s** → game **resumes**, clock kept running during absence. The 90s rule only fires if they do NOT return.

## E. Matchmaking / identity

24. **Quick-match finds no waiting opponent** → offer the **practice bot** (better UX for a thin early population).
25. **An account that never plays** → does **not** appear on leaderboards or in matchmaking (only players with >=1 completed game appear).
26. **Outside staked match with mismatched ratings (Option B)** → **allowed, ASYMMETRIC**: outside matches inherit the **challenge-up staking model** — the lower-rated player stakes more for the bigger upside, using the same win-improbability gap-scaling and the **30% stake cap** (per §5). Effectively "challenge-up against anyone on the open ladder." Rating handles fairness (big upset = big swing). Still transfer-only, never minting (per §5 hard line).

---

## F. Conquest CP/stake resolutions (LOCKED 2026-06-26)

27. **Gauntlet defender stake — per-game settlement.** The Gauntlet defender's stake settles **per game** (not series-pooled): defender **loses** a game → that game's stake **burned to `__sink__`**; defender **wins/draws** a game → that game's stake **returned to the defender**.
28. **Challenger never receives Gauntlet CP.** This REVISES original §11.4 ("forfeits to the challenger"). The Gauntlet is a pure skill gate; the challenger gains no CP from it under any outcome. (Burn = anti-inflation sink.)
29. **Breach-stake disposition on a successful breach = Option A (refund).** On a breach **win**, the challenger's breach stake is **refunded immediately** at breach-win time; the challenger then risks NO further CP in the Gauntlet. (Breach failure → defender; force-close → challenger; abandon → defender — unchanged.)
30. **Gauntlet stake is single-staker (V1).** Only the **nominated defender** stakes (not owner+defender, not the wider circle).
31. **All games rate.** Every human-vs-human game updates Glicko rating (Quick Match, peer, challenge-up, breach, each Gauntlet game). Only future bot games (`isBotGame:true`) are excluded. Rating is independent of CP settlement.

**Note:** these four (27–30) were the previously-open conquest CP parameters; all now locked. The live code (`conquest.ts` per-game gauntlet branch + breach-win refund) already implements them — no code change required, spec brought into line with implementation.

---

**STATUS: every edge case decided.** Combined with the master design doc, the entire app — features AND edge cases — is now fully specified for the build.
