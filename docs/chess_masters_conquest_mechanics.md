# Chess Masters — Conquest Mechanics (Slice 4 data-model spec)

Extracted verbatim-in-substance from the LOCKED design (`chess_masters_v1_design.md` §10–§11) and the decisions checklist (`chess_masters_decisions_checklist.md` A/B/C). This pins the three things that determine the conquest data model. **Both source docs now travel alongside this file — read them directly if anything here is ambiguous.**

---

## THE CORE LOOP (so the state machine is unambiguous)

An outsider forces entry into a circle they don't own, by chess:

1. **Breach** — outsider stakes CP (challenge-up formula, 30% cap — the SAME math/escrow as `acceptChallengeUp` already does) to challenge a circle.
2. **Defense of the breach** — the **first circle member to accept** defends (first-come, server-timestamp wins; NO owner nomination at this stage). If **no member accepts**, challenger is **accepted by default** (undefended). **One** defense game decides it:
   - challenger **wins** → **provisional entry**, proceed to Gauntlet.
   - challenger **loses OR draws** → breach **fails**; challenger's breach stake **transfers to the defender** (checklist #7, #13). Draw does NOT grant entry.
3. **Gauntlet** — **best-of-3 vs ONE defender** (first to 2 losses ejects challenger). Gauntlet defender is **owner-nominated**; if owner offline, cascade to **next-highest-rated ONLINE member**; if nobody available to nominate, challenger **accepted by default**. Owner may nominate self. **Challenger risks NO CP in the Gauntlet** (skill trial only). The **group stakes discounted CP** (see Q2).
4. **Outcomes (REVISED 2026-06-26 — per-game settlement, challenger never receives Gauntlet CP):**
   - The Gauntlet defender's stake is **per-game** and settles **per game**, NOT pooled at series level. Each game: defender **loses** that game → that game's stake is **burned to `__sink__`**; defender **wins or draws** that game → that game's stake is **returned to the defender**. The **challenger never receives** the defender's Gauntlet CP under any outcome (the Gauntlet is a pure skill gate; CP only leaves the defender via burn-on-loss and is conserved via return-on-win/draw).
   - challenger **survives (wins 2 of 3)** → **full permanent member**. (The deciding games the challenger won had their stakes burned per the per-game rule above; nothing transfers to the challenger.)
   - challenger **ejected (loses 2 of 3)** → out. (The games the defender won had their stakes returned to the defender per the per-game rule; nothing is burned for those.)
   - challenger **abandons** mid-process → unplayed Gauntlet games **forfeit as losses** → ejected; breach stake to the defender (checklist #12).
   - **NOTE — this REVISES §11.4 / the original "forfeits to the challenger" language.** The original spec had the group's pooled CP transfer to the challenger on survival and burn on ejection. The locked V1 model inverts the disposition basis: settlement is **per-game by who won that game** (burn on challenger game-win, return on defender game-win/draw), and the **challenger gains no Gauntlet CP**. This is a deliberate design change (2026-06-26) to keep the Gauntlet a pure skill trial and use the burn as an anti-inflation sink.

Crown is unrelated/automatic (highest-rated member, §10) — not part of conquest settlement.

---

## Q1 — Provisional → full membership follow-through condition

**ANSWER: There is NO separate time-window or N-games follow-through. "Full member" is granted the instant the challenger wins the Gauntlet (2-of-3).** The Gauntlet *is* the follow-through.

Sequence is: breach win → **provisional entry** → Gauntlet (best-of-3) → win it → **full, permanent member**. "Provisional" is just the state *between winning the breach and finishing the Gauntlet* — it is not a probationary membership with its own timer or game-count quota. Once full, the player is an ordinary member (§11.5, checklist #17 — they can even leave immediately).

**Data-model consequence:** the conquest doc needs a **status enum lifecycle**, but **NO scheduled/cron function** for membership graduation — graduation is event-driven (fires inside the Gauntlet's game-finish settlement when the 2nd win lands). 

The conquest is **synchronous by design** (§11 intro: "no autonomous timers"). The only timeouts are the **existing 90-second abandonment rule** (already in the engine) and a "**short wait**" for a nominated defender / abandoning challenger to show (checklist #4, #12). These are short, in-process waits, not long scheduled windows. **You likely do NOT need a scheduled Cloud Function for V1 conquest** — defender-no-show and challenger-abandon can be handled with the same client-driven / on-demand timeout mechanism the engine already uses, or a short server-side delay. Confirm the "short wait" handling approach when scoping, but it does not imply a cron/Pub/Sub scheduler.

**Suggested conquest status enum** (to design in Slice 4):
`breach_pending` → `breach_defense_active` (game live) → `gauntlet_pending` (challenger won breach, awaiting/ nominating defender) → `gauntlet_active` (best-of-3 in progress) → terminal: `challenger_won` / `challenger_ejected` / `breach_failed` / `force_closed`.

---

## Q2 — Gauntlet best-of-3 state + "discounted group CP" pooling

**Best-of-3 match state location — DESIGN DECISION FOR SLICE 4 (not pre-locked).** The design doesn't mandate doc vs subcollection. Recommendation given the existing schema: keep **series state on the conquest doc** (e.g. `gauntlet: { gameIds: [], challengerWins: 0, defenderWins: 0, currentGameId }`) and let each individual game be a normal `games/{id}` doc with `gameType:"gauntlet"`, `contextId:<conquestId>`. Rationale: mirrors how peer/challenge-up already link a game to its stake via `contextId`; the series is small and bounded (≤3), so a subcollection adds little. The game-finish trigger reads the conquest doc, increments the win counter, and either starts game N+1 or settles the series. (Checklist #8: a **drawn Gauntlet game → replay** that game — so `gameIds` can exceed 3; count only decisive results toward 2.)

**Discounted group CP — the LOCKED numbers (§11.3):**
- The group stakes **25% of the equivalent normal 3-game stake**, **split per participant**.
- "Equivalent normal 3-game stake" = what the defenders would stake across 3 ordinary staked games (the base reference), then **discounted to 25%**, then **divided among the contributing participants**.
- **Who contributes:** "the group" — the participating defender(s)/circle members on the defending side. The exact contributor set (just the nominated Gauntlet defender? owner? a defending roster?) is the one under-specified detail — **§11 V1 is single-defender** ("single-defender, no multi-player roster"), so for V1 the realistic reading is **the nominated Gauntlet defender stakes the discounted group CP** (possibly with the owner), NOT the whole circle. **Pin this explicitly when scoping Slice 4** — it's the only genuinely open parameter, and it decides whether the escrow is single-staker (simple, like the current model) or multi-staker (pooled).

**This is NEW escrow shape vs the current `stakes` model:**
- Current `stakes` model: exactly **two** stakers (issuer + opponent), symmetric or asymmetric, both stake at accept-time. The pot is `issuerStake + opponentStake`.
- Conquest Gauntlet: the **challenger stakes NOTHING** in the Gauntlet; only the **group side** stakes (the discounted pooled CP). On challenger survival, that pool **forfeits to the challenger** (one-directional transfer, no matching stake). On ejection, the pool is **burned** (not transferred to anyone). 
- So the Gauntlet escrow is **one-sided** (defender stakes; challenger doesn't) and its resolution is **per-game: burn-to-sink on a challenger game-win, return-to-defender on a defender game-win/draw**. The challenger never receives Gauntlet CP. `settleConquest`'s gauntlet branch handles this (per-game, on each game finish) — `settleStakeForGame` does not cover the one-sided escrow with a burn outcome. (IMPLEMENTED: this is the live behavior as of 2026-06-26.)
- The **breach stake** (challenger's CP, step 1) IS exactly the existing model's shape (one staker, transfers to defender on failure) — reuse the `stake_lock` → transfer machinery for it.

**Ledger reuse:** all of this uses the append-only `ledger`. `stake_lock` (negative) for the defender's per-game locked CP; on a defender game-win/draw a `stake_return` (positive) back to the defender; on a challenger game-win a `rake`-type burn entry to `account:"__sink__"`; on force-close a `stake_return` back to original stakers.

---

## Q3 — What defenders stake / forfeit ("forfeit-on-survival," "burned-on-eject")

**The challenger's breach stake (step 1) — RESOLVED (Option A, 2026-06-26):**
- Locked at breach time (`stake_lock`, challenge-up formula, 30% cap).
- Breach **failure** (challenger loses/draws) → breach stake → **defender** (checklist #13).
- Breach **success** (challenger wins) → breach stake **refunded to the challenger immediately** at breach-win time. The challenger then enters the Gauntlet risking **NO further CP** (consistent with "challenger risks no CP in the Gauntlet"). This resolves the previously-open question on line 63: **Option A (refund on breach win)** is locked. A successful breach therefore costs the challenger no net CP — it is a pure skill gate.
- **Force-close** (account deletion / circle deleted) → breach stake → back to **challenger** (checklist #14).
- Challenger **abandons** mid-Gauntlet → breach stake → **defender** (checklist #12).
- (IMPLEMENTED: live behavior as of 2026-06-26.)

**The defender's Gauntlet stake — per-game (LOCKED outcomes, REVISED 2026-06-26):**
- **Staked when:** each Gauntlet game begins (defender locks that game's discounted stake into escrow).
- **Defender loses a game** → that game's stake **burned to `__sink__`** (`rake`-type entry). CP leaves circulation; books stay balanced (sum over all accounts incl. sink conserved).
- **Defender wins or draws a game** → that game's stake **returned to the defender** (`stake_return`).
- **The challenger never receives the defender's Gauntlet CP** under any outcome (REVISES the original §11.4 "forfeits to the challenger"). Disposition is per-game by who won that game, not a series-level transfer.
- **Force-close refund:** account deletion / app error → **clean refund** to original stakers, no burn, no transfer (checklist #14): challenger's breach stake back to challenger, group's pool back to the group.

**Burn as a sink — confirmed consistent with §7:** §7 lists sinks as "the pot rakes; (post-launch: Gauntlet burn...)". Note the design parenthetically tags Gauntlet burn as *post-launch* in §7's sink list, but §11 (the V1 conquest spec) and build-order §13.4 both include "burn-on-eject" as part of **V1 simplified conquest**. Treat **burn-on-eject as IN for Slice 4** (it's explicit in §11.4 and §13.4); the §7 parenthetical is stale wording. Worth a one-line confirmation but the build order is unambiguous.

---

## EDGE CASES THAT SHAPE THE STATE MACHINE (checklist A/B/C — all LOCKED)

- Two simultaneous breaches on one circle → **higher-rated challenger proceeds**, other rejected/deferred (#1). → conquest doc needs to guard one-active-breach-per-circle.
- **Multiple concurrent conquests per attacker ALLOWED** (#18, REVISED 2026-06-25). A challenger may mount breaches against several DIFFERENT circles at once (incl. overlapping breach-accept windows and even concurrent Gauntlets). Over-extension is bounded by CP: each breach locks its own stake. The one-active-breach-PER-CIRCLE guard (#1) still stands. Circle deletion force-closes its conquests and refunds the breach stake (#14).
- **Can't breach your own circle / a circle you're already in** (#20); members use internal challenge/crown instead.
- **No re-attempt cooldown in V1** (#19) — ejected challenger may immediately re-breach.
- Breach **draw** → fails, stake to defender (#7). Gauntlet **draw** → **replay that game** (#8).
- Disconnect mid-game (breach or Gauntlet) → existing **90s rule** = loss for the absent side (#5, #6).
- Defender **nominated but never shows** → short wait → **challenger accepted** (#4).
- Challenger **abandons** post-breach → short wait → unplayed Gauntlet games **forfeit as losses** → ejected; breach stake to defender (#12).
- **Account deletion** force-closes a conquest → refund all escrow to original stakers (#2, #11, #14).
- Member **can't leave to dodge** an active defense/Gauntlet they're committed to (locked until resolved; leaving forfeits) — but can leave freely otherwise (#16, #3).
- Nominated defender being the crown-holder → **no conflict** (#10).

---

## NET FOR THE BUILD (Slice 4)

- **New top-level collection** e.g. `conquests/{id}` (or `breaches/{id}`), client-readable to involved parties, **write:false**, all mutations via new Cloud Functions — same rules shape as everything else.
- **Status state machine on the conquest doc** (enum above); **event-driven graduation**, almost certainly **no scheduler** needed for V1 (synchronous design; reuse the 90s engine timeout + short in-process waits).
- **Gauntlet series state on the conquest doc**; each game a normal `games/{id}` with `gameType:"gauntlet"`/`"breach"` + `contextId:<conquestId>`.
- **Reuse** the breach stake via the existing one-staker `stake_lock`→transfer machinery (it's just a challenge-up against a circle).
- **NEW one-sided pooled escrow + settlement** for the Gauntlet (group stakes, challenger doesn't; forfeit-to-challenger OR burn-to-sink) — a new `settleGauntlet`/`settleConquest` function; `settleStakeForGame` does not cover this.
- **Burn = `rake`-type ledger entry to `__sink__`** (your instinct confirmed).
- **THREE open params — ALL RESOLVED 2026-06-26:** (a) for single-defender V1, the Gauntlet stake is the **nominated defender's** per-game stake (single-staker, not the wider circle). (b) breach-stake disposition on a clean breach win = **Option A, refund to challenger** at breach-win time (challenger risks no CP in the Gauntlet). (c) burn-on-loss is **IN** for V1 (per §11/§13), now applied **per-game** on each defender game-loss. Additionally, the Gauntlet pool disposition is **REVISED**: per-game burn (defender loss) / return (defender win-draw); the **challenger never receives Gauntlet CP** (inverts the original §11.4 "forfeits to challenger").

**Rating (all games):** every game against a human updates Glicko rating — Quick Match, peer, challenge-up, breach, AND each Gauntlet game. Only bot games (future, flagged `isBotGame:true`) are excluded from rating. Rating is independent of CP/stake settlement.
