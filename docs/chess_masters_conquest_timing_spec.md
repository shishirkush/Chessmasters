# Chess Masters — Conquest Timing & Ready-Gate Spec

Design reference for making the **Conquest** feature (breach + Gauntlet) actually
playable for real players on different timelines. This document is the source of
truth for the **two-timer model** and the **no-show outcomes**. Build the next
slice from this.

Status at time of writing:
- Breach half: **committed** (`f016246`).
- Gauntlet half (commit 2): **built but NOT committed** — blocked on this spec.
- None of the timing/ready-gate logic below exists yet. It is the next build.

---

## 1. The core problem this solves

Conquest games were created in `active` state with the **clock already running**,
regardless of whether both players were present. In testing, one player landed in
the game and the other never did, so games ran down the 90s abandon timer with a
single player present and resolved as abandons. No real chess was played.

Two distinct things were conflated and must be separated:

1. **"Is the opponent at the board right now?"** — a *synchronous* concern, scale
   of seconds. Solved by the **ready-gate**.
2. **"Will this player ever show up to respond?"** — an *asynchronous* concern,
   scale of a day, because players are on different timelines (asleep, busy,
   different timezones). Solved by the **response window**.

Conquest is an asynchronous, multi-day, social feature (you are attacking a
circle of real people) with synchronous live chess games nested inside it.

---

## 2. The two timers

### Response window — 12 hours
"You have a day to show up to this game."
- Applies to whichever player is **not already present** when a game is created.
- The game sits in `waiting`; **clocks are frozen** during this window.
- If the absent player enters within 12h → proceed to the ready-gate.
- If they never enter within 12h → they forfeit by no-show (outcome depends on
  role and phase — see §5).

### Ready-gate — 90 seconds
"You are both here now — start the clock fairly."
- Applies the moment **both** players are ready.
- After activation, a 90s **grace window** for both players to actually arrive at
  the board before the clock meaningfully bites — so the player who tapped in a
  few seconds later is not punished.
- This is distinct from the existing *in-game* 90s abandon (which only applies
  once the game is already `active` and a player stops moving).

> One-sentence rule: **Any created conquest game gives each not-yet-present
> player 12h to ready up; when both are ready, the game activates and both are
> notified, with a 90s grace before clocks bite.**

### CRITICAL — a `waiting` game NEVER blocks other play
A player who is party to a `waiting` game (e.g. mounted a breach, or is the
pending opponent) **must remain free to do everything else** — quick matches,
other staked games, browsing — while the game waits. An interested, active player
must **never** be frozen out for the up-to-12–24h window.

Implications for the build:
- **No forced navigation / no trap.** The app must never pin a player on a
  `waiting` game screen. They can open it, ready up, and leave freely. (This
  reinforces the earlier move away from forced auto-push toward prompts.)
- **No blocking state.** Being in a `waiting` game must not prevent starting or
  joining other games. (The engine already has no such block; do not add one.)
- **Readying is STICKY / async.** When a player opens a `waiting` game, they are
  marked ready (added to the game's `ready` set) and may then leave and do
  anything else. Ready persists; they do not have to sit and wait.
- **Activation notifies both.** When the *second* player readies up (whenever, in
  the 12h window), the game flips to `active` and **both players are notified**
  ("your game is live — enter now"), with the 90s grace to arrive before the clock
  bites. This is why FCM is load-bearing — async readying only works if the player
  who readied earlier is told when it actually goes live.
- **Tradeoff accepted:** a player who readied up may receive a "your game is live"
  notification while doing something else, and should enter within the grace
  window. This is the cost of supporting asynchronous play across timezones;
  requiring simultaneous presence would defeat the 12h window entirely.

---

## 3. The universal principle

Whenever a *specific game* is created and needs two specific people at the board,
each person who is not already there gets 12 hours to show up. Same rule
everywhere — breach game, Gauntlet game 1, 2, 3. The events that *create* those
games (a member accepting a breach defense, the owner nominating a champion) are
just the triggers.

The only place a player does **not** get a window is when there is **no game yet**
— e.g. the challenger who just mounted a breach is waiting to see if *anyone*
will defend. There is no board, no opponent assigned, so no window applies to
them yet. They are simply the waiting initiator.

---

## 4. Breach lifecycle (two "moments")

### Moment 1 — waiting for *anyone* to defend (no game exists yet)
- Challenger mounts breach → conquest `breach_pending`, challenger's stake locked.
- A **12h defense window** opens for the circle.
- **Any** member (including the owner) may accept the defense within 12h.
- The challenger does **not** get a window here — there is no game yet; they are
  the initiator waiting for a response.
- **Nobody accepts within 12h** → the circle failed to defend → **challenger wins
  by default** → conquest advances to `gauntlet_pending`. No CP changes hands (the
  defending side never staked anything).
- **FCM push is required here** — members must be notified a breach needs
  defending, or the 12h passes silently and the circle "fails" simply because
  nobody knew.

### Moment 2 — a defender accepted; a real game now exists
- The moment a member taps **Defend**, a concrete game exists: challenger vs that
  specific defender.
- Now **both** players get the 12h response window to enter that game. The
  challenger mounted the breach hours ago and may be offline; the defender just
  accepted at a random time. Either could be absent.
- Game created `waiting`, clock frozen. Both enter → 90s ready-gate → clock starts
  → play.

---

## 5. No-show outcomes (breach)

| Who is absent | When | Outcome |
|---|---|---|
| No member accepts | Moment 1, 12h window expires | Challenger wins by default → `gauntlet_pending`. No CP changes hands. |
| Challenger | Moment 2, fails to enter the game within 12h | Challenger forfeits their stake to the defender → `breach_failed`. **Real CP loss.** |
| Defender (who already accepted) | Moment 2, fails to enter the game within 12h | Defender forfeits → challenger wins the breach → `gauntlet_pending`. No CP changes hands (defender staked nothing). Accepting is a commitment; bailing advances the challenger. |

Note the asymmetry of breach escrow: only the **challenger** stakes CP. So a
defender no-show is never a CP loss for the defender — it just means the breach
succeeds.

---

## 6. Gauntlet lifecycle

### Nominate window — 12 hours
- Breach won → conquest `gauntlet_pending`. A **12h nominate window** opens for the
  owner.
- Owner nominates a champion (may nominate self) within 12h.
- **Owner does not nominate within 12h** → **challenger wins the whole conquest by
  default** → `challenger_won` → challenger enters the circle as a full member.
- **FCM push required** — the owner must be notified they need to nominate.

### Each Gauntlet game — 12h response window + 90s ready-gate
- When the owner nominates, Gauntlet game 1 is created `waiting`.
- The Gauntlet is mounted at a random time; **both** the nominated defender and the
  challenger may be offline. Each gets the **12h response window** to enter the
  game.
- The same applies to auto-chained games 2 and 3: each is created `waiting`, both
  players get 12h to show up, then the 90s ready-gate.
- **FCM push required** for each game — "your Gauntlet game is ready."

### No-show outcomes (Gauntlet)
The absent player loses **that game** (per the existing per-game stake rules),
counting toward the best-of-3:

| Who is absent | Outcome for that game |
|---|---|
| Defender | Challenger wins the game → defender's per-game stake **burns** to `__sink__`. Counts toward challenger's 2. |
| Challenger | Defender wins the game → defender's per-game stake **returns**. Counts toward defender's 2. |

Terminal logic is unchanged: first to 2 decisive wins. Challenger 2 →
`challenger_won` + added to circle `members`. Defender 2 → `challenger_ejected`.

---

## 7. Ready-gate — applies to ALL games (not just conquest)

Decision: the ready-gate applies to **every** game (quick match, peer stake,
challenge-up, breach, gauntlet), for consistency.

### Current state of the engine (important)
The casual / quick-match path **already implements the ready-gate**: `freshGame`
creates games as `status: "waiting"` with `lastMoveAt: null` (clock frozen) and
only `whiteId` seated; the casual `joinGame` flips to `active` and starts the
clock when the second player joins. Do **not** touch this working path.

The bug is that **every STAKED game bypasses it.** Peer (`stakes.ts` ~320),
challenge-up (`stakes.ts` ~698), and breach + gauntlet (`conquest.ts`) all create
the game with `status: "active"` and `lastMoveAt: Date.now()` — clock running at
creation, both players seated — so the game goes live before either player is at
the board. These four sites are the fix.

### The model for pre-seated (staked) games
Staked games have **known, specific players** (not a random quick-match joiner),
so both seats are assigned at creation. Use a `ready` set rather than the empty-
seat signal the casual path uses:

- Create as `status: "waiting"`, `lastMoveAt: null` (clock frozen), **both**
  `whiteId`/`blackId` assigned, `ready: []`, and a `waitingSince` timestamp.
- **Auto mark-ready on GameScreen open**: a new `markReady(gameId)` callable adds
  the caller to `ready` (after verifying they are one of the two assigned
  players). No explicit "ready" tap.
- **Readying is sticky** (§2.1): once added to `ready`, the player may leave and
  do anything else.
- When **both** assigned players are in `ready` → flip `status` to `active`, set
  `lastMoveAt = now`, clocks start; **notify both** players (FCM) "your game is
  live", with the 90s grace before clocks bite.
- A `waiting` game shows "Waiting for opponent to join…" with the board locked and
  clocks frozen — but the player can freely back out (no trap).
- The existing in-game abandon (90s of no moves) applies **only** once `active`.

Leave the casual `joinGame` untouched; add `markReady` as a separate callable for
pre-seated games so quick-match logic (seat-filling, caps, random matching) is not
disturbed.

### Timers — phase-dependent consequences
Three distinct timers; keep them from tangling:
- **(a) 12h response window** — while `waiting` with only one player in `ready`.
  If it expires, resolve the no-show per role/phase (§5, §6) via the scheduled
  expiry function (§11).
- **(b) 90s ready-gate grace** — once both are ready and the game activates, a
  short grace for both to arrive at the board before the clock bites.
- **(c) 90s in-game abandon** — existing behavior, once `active`, a player who
  stops moving for 90s.

No-show consequences when a 12h window expires:
- **Quick match / peer / challenge-up no-show** → **void** the game. **No CP or
  rating loss.** Any stakes refunded to both sides.
- **Breach / Gauntlet no-show** → the abandon result **applies** per role (see §5
  and §6).

---

## 8. Stake exposure during windows

- The challenger's breach stake is **locked for up to 12h** while waiting for a
  defender (Moment 1) and potentially another 12h while waiting for the defender to
  enter the game (Moment 2). CP can be locked for up to a day across both windows.
  **Decision: accepted for V1** — it is genuine escrow and serious players resolve
  faster than the worst case. No cap or shortened Moment-1 window for now.

---

## 9. Why FCM push is structurally mandatory

Every 12h window is meaningless without a notification. A breach-defense window,
a nominate window, and a "your game is ready" prompt all depend on the target
player learning there is something to respond to. Without push:
- Breaches go unnoticed; circles "fail to defend" because nobody knew.
- Owners miss the nominate window; challengers win by default unfairly.
- Gauntlet games sit until the 12h expires.

Therefore FCM is **not optional** — it is a core dependency of conquest
functioning. The in-app indicator (a banner shown when the app is already open)
is only a minor complement; it cannot replace push for the closed-app case.

FCM cannot be tested against the local Firebase emulator — it needs real device
tokens and the real FCM backend. Real-device testing is already set up
(see the emulator-host config in `main.dart`: `kEmulatorHost`).

---

## 10. Build order for the next session (dependency order)

1. **Ready-gate + response windows** (the two-timer model). Core game-lifecycle
   change. Server-first:
   - Games created `waiting`, clocks frozen, `joined` set, `waitingSince`.
   - `joinGame(gameId)` callable; flip to `active` when both joined.
   - 12h response window (per absent player) + 90s ready-gate + no-show resolution
     per role/phase (§5, §6).
   - Apply to all games. Test path by path: quick match still works → peer still
     works → breach join-gate → gauntlet join-gate.
   - The owner-nominate and any-member-defend 12h windows, resolved by a
     **scheduled Cloud Function** that sweeps for expired windows (see §11).
2. **FCM push** — its own slice. Token registration, Cloud Function triggers on
   breach creation / nomination / game-ready, permission handling, background
   message handling. Needs real devices.
3. **In-app indicator** — minor complement to FCM for the app-open case (a
   home-screen banner / Circles badge: "a circle you're in is under breach").
4. **Then revisit committing the Gauntlet** (commit 2) — it is only playable once
   the ready-gate + windows exist.

---

## 11. Locked decisions (confirmed)

- Ready-gate applies to **all games**.
- **A `waiting` game NEVER blocks other play** — the player remains free to quick-
  match, start other staked games, and browse. No forced navigation, no trap, no
  blocking state. (See §2.1.)
- **Readying is sticky / async**: opening a `waiting` game marks the player ready
  (added to the game's `ready` set); they may then leave and do anything else.
- **Activation notifies both** players when the second readies up; 90s grace to
  arrive before clocks bite.
- **Auto-join** (mark ready) on GameScreen open (no explicit ready tap).
- Join-timeout **90s**; quick-match no-show **voids** with no CP/rating loss;
  breach/gauntlet no-show **applies the abandon result** per role.
- Breach defense window: **12h** for any member to accept; nobody accepts →
  challenger wins by default → `gauntlet_pending`, no CP changes hands.
- Challenger no-show to an accepted breach game → forfeit stake → `breach_failed`.
- Defender who accepted then no-shows → forfeit → challenger advances to
  `gauntlet_pending` (no CP changes hands).
- Gauntlet nominate window: **12h** for the owner; owner doesn't nominate →
  challenger wins the conquest by default → `challenger_won` → enters circle.
- Each Gauntlet game: both players get a **12h** response window to enter (the
  challenger may be offline when the owner mounts the Gauntlet at a random time).
- Gauntlet game no-show → absent player loses that game per the per-game stake
  rules (defender absent → stake burns; challenger absent → stake returns).
- **Window-expiry trigger: scheduled Cloud Function.** A scheduled function
  (Cloud Scheduler, every few minutes) queries for conquests/games whose window
  has expired and resolves them server-side — even if nobody opens the app. This
  is the robust, self-healing option: an unanswered breach resolves itself at the
  12h mark automatically. (Chosen over passive-on-access for reliability.)
- **Stake exposure accepted: challenger CP may be locked up to ~12–24h** across
  the two breach windows (Moment 1 wait-for-defender + Moment 2 wait-for-entry).
  This is acceptable product behavior — it is genuine escrow and serious players
  resolve faster than the worst case. No cap or shortened Moment-1 window for V1.

## 12. Open items to confirm before/while building

- **Defender-accept-then-no-show** resolution chosen as forfeit (§5). Confirmed,
  but flagged in case re-opening the defense window to other members is later
  preferred.
- **Scheduled-function cadence**: how often the expiry sweep runs (e.g. every
  1–5 min). Finer cadence = snappier resolution, marginally more invocations.
  Decide during build; a few minutes is fine for 12h windows.
