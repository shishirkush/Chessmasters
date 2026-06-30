# Chess Masters — Design & Architecture Spec

> **Purpose of this document:** a self-contained reference so any new
> conversation (or developer) understands the Chess Masters design without the
> original chat history. It describes the system **as currently implemented in
> the codebase**, with open design questions flagged explicitly.
>
> **Status note:** Where this spec and the live code ever disagree, the code is
> authoritative — treat this as a map, not the territory. Verify specifics
> against the named source files.
>
> **Revision note (this version):** Stake-sizing has been **migrated from Elo to
> Glicko-2 throughout** (challenge-up, open lobby, and conquest). The open-lobby
> economic redesign (poster-picks-stake + odds-scaled accepter) is **shipped**.
> All four staked game types plus both conquest settlement paths have been
> **reconciled to the decimal in production** (see §18). Sections 5, 7, 8, 9,
> and 18 reflect these changes.

---

## 1. What Chess Masters Is

A competitive, real-time **Android chess app** for Indian users, built solo by
Shishir (Jakarta; develops on Windows). Players compete in staked blitz games
using an in-app virtual currency (**CP**), with skill tracked separately by a
**Glicko-2** rating. The defining architectural principle is **server
authority**: the server owns all truth (game state, money, ratings); the client
only sends *intents* and *reads* state.

**Tech stack**
- **Client:** Flutter (Dart), Android-only. Board rendering via
  `simple_chess_board` (display-only — it does NOT enforce chess rules; the
  server does).
- **Backend:** Firebase Cloud Functions (TypeScript), Cloud Firestore, Firebase
  Auth (Google Sign-In + Anonymous), Firebase Cloud Messaging (FCM).
- **Repo:** `https://github.com/shishirkush/Chessmasters.git` (branch `main`).

---

## 2. Infrastructure & Project Layout

### Firebase project (CRITICAL)
- **Active project: `chessmasters-sg`** — Singapore.
  - Default Firestore region: **`asia-southeast1`** (permanent/immutable).
  - Plan: **Blaze**. Project number: **`128072093934`**.
  - Android app id: `1:128072093934:android:75311d8dd0e1f2eb6363ff`,
    package `com.shishir.chessmasters`, messagingSenderId `128072093934`.
- **`chessmasters-dev` (asia-south1) is ABANDONED.** Mumbai (`asia-south1`)
  Firestore **does not support Firestore triggers** — this forced the migration
  to Singapore. Do not deploy here.
- **`angrezi-seekho`** is a *separate, unrelated* app (Hindi→English learning).
  Never deploy Chess Masters there.

### Why asia-southeast1 matters
Firestore triggers (e.g. `onGameFinished`, `onNotificationCreated`) are **v2
Eventarc** functions that must be **co-located in the same region as the
database**. Singapore supports them; Mumbai did not. The Firestore region is
permanent, so the whole project had to be recreated to change it.

### Local layout (Windows)
```
C:\Users\sidyy\ChessMasters\chessmasters_slice1_v1\chessmasters\
├── firebase.json, firestore.rules, .firebaserc   ← repo root
├── functions\
│   ├── src\        ← TypeScript source (compiled to lib\ via `npm run build`)
│   └── package.json (Node 20 runtime)
└── app\
    ├── lib\        ← Flutter/Dart source
    ├── pubspec.yaml
    └── android\app\google-services.json   ← chessmasters-sg config (GITIGNORED)
```
- `app` and `functions` are **siblings** under `chessmasters\`.
- **`google-services.json` is gitignored** — the correct chessmasters-sg copy
  exists only locally; re-download from the console if lost.
- **`.firebaserc`** maps aliases: `default → chessmasters-dev`,
  `SG → chessmasters-sg`. Aliases MUST be nested under a `"projects"` key
  (a malformed flat version broke `flutterfire` and risked deploys).

---

## 3. Core Architecture: Server Authority

**The client sends INTENTS and READS state. It never writes game/economic
state.** All mutations go through Cloud Functions (Admin SDK, which bypasses
Firestore rules). Firestore security rules **deny all client writes** to every
economic/game collection, and scope reads.

- Client → **callable functions** (`createGame`, `joinGame`, `makeMove`,
  `acceptStake`, etc.) to *do* things.
- Client → **Firestore streams** to *read* live state (current game, lobby,
  notifications, leaderboards).
- Server → owns truth; computes everything; writes via Admin SDK.

**The V1 firewall — "money never touches rank":** rating is a server-owned,
skill-only quantity. Clients can never set their own rating; CP never
influences rating; rating never influences CP balance.

---

## 4. The CP Economy

CP (the virtual currency) runs at a **10× scale** for granularity.

### Faucets (the only sources of CP)
1. **Starting grant — 5000 CP**, one-time, on first account creation
   (`grantStartingCP` in `ledger.ts`, called by the `onUserCreate` auth
   trigger). Idempotent via a deterministic ledger doc id (`grant_{uid}`).
2. **Daily allotment — 500 CP per human player per UTC day**, granted for
   *playing a real (non-bot) game* that day (`grantDailyAllotment`, called from
   `onGameFinished`). Idempotent per `(uid, UTC-day)` (doc id
   `allot_{uid}_{YYYY-MM-DD}`). This ties the main CP source to genuine human
   play, which blocks bot-farming.

### Economic dials
- `MIN_STAKE = 50`
- Stake cap = **40% of balance** (the §5 hard cap; `MAX_STAKE_FRACTION = 0.40`)
- **Rake = 5%** of the pot, paid to the `__sink__` account on settlement
- Daily caps (see `counters.ts`): `QUICK_MATCH_DAILY_CAP = 3` (unstaked casual
  games/day), `SAME_OPPONENT_DAILY_CAP = 3` (games/day vs the same opponent)

### The ledger (source of truth)
- Every CP movement is an append-only `ledger/{id}` entry written via
  `appendEntry`, which **transactionally** updates the cached `cp` field on the
  user doc (a read-optimization; the ledger is authoritative).
- Entry types seen: `starting_grant`, `daily_allotment`, `stake_lock`,
  `pot_win`, `rake`, `stake_return`. `__sink__` is the house account that
  collects rake and conquest burns.
- **Conservation invariant:** total CP across all users + `__sink__` always
  equals the sum of all grants + allotments. No CP is created or destroyed in a
  game — settlement only redistributes (winner gets pot minus rake; rake to
  sink; conquest burns send CP to sink; breach transfers move CP between
  players). This has been **verified end-to-end in production with exact,
  per-account ledger-sum-equals-cp reconciliation across all game types**
  (see §18).

---

## 5. Rating System — Glicko-2

Rating is the authoritative skill measure, entirely separate from CP. As of this
revision, **Glicko-2 is also the single basis for stake-sizing** (§7), so the
project now uses **one rating model everywhere** — there is no Elo logistic
anywhere in the codebase.

- **Implementation:** `glicko.ts` — pure math, no Firestore, a faithful
  implementation of Glickman's Glicko-2 (one game = one rating period).
- **State per user:** `rating` (public, ~1500), `rd` (rating deviation,
  uncertainty), `vol` (volatility).
- **Starting values:** `START_RATING = 1500`, `START_RD = 350`,
  `START_VOL = 0.06`. System constant `TAU = 0.5`.
- **Provisional:** a player is `provisional: true` until `rd` drops below
  `PROVISIONAL_RD = 110`. New players start provisional.
- **Rating floor:** 500 (enforced on update, not at creation).
- Glicko-2 ratings are intentionally on (approximately) the **Elo scale**
  (centered ~1500).

### Shared win-probability — `winProbability` (the one source)
`glicko.ts` exports **`winProbability(player{rating,rd}, opponent{rating,rd})`**,
the Glicko-2 expected score:
```
g(φ)  = 1 / sqrt(1 + 3φ²/π²)
E     = 1 / (1 + exp(−g(φ_opp) · (μ − μ_opp)))     // base-e, RD-weighted
```
where μ, φ are the internal-scale rating/RD (`μ = (rating−1500)/173.7178`,
`φ = rd/173.7178`). This is the **same** expectation the rating update uses
internally, now exposed so that **rating and stake-sizing speak one language**.

**Why Glicko-2 (not Elo) for staking:** the gap is weighted by the *opponent's*
RD via `g(φ_opp)`. When the opponent's rating is uncertain (high RD / provisional
/ potential smurf), the result is less predictable, so the win-probability is
pulled toward 0.5 — the rating gap "counts for less" and stake spreads are
gentle. As the opponent's RD shrinks with games played, `g(φ_opp) → 1` and the
curve converges toward the plain logistic (Elo-like). **Consequence (accepted
design):** stake spreads are gentle while ratings are unsettled and **steepen as
the population matures** — stakes self-calibrate to how trustworthy the rating
gap is. This is intentional; there is deliberately **no damping exponent** on top
(Glicko's RD-weighting *is* the softener — a second damper would double-flatten).

### Where rating is applied: `onGameFinished` (rating.ts)
- A **v2 Firestore `onDocumentUpdated` trigger** on `games/{gameId}`, region
  **`asia-southeast1`**. (The *only* Firestore trigger besides FCM's; all
  callables/schedulers remain v1 in us-central1 — mixing v1/v2 in one codebase
  is supported.)
- Acts **only on the transition into `status === "finished"`**.
- **Idempotent:** marks the game `ratingApplied: true` inside a transaction, so
  a retry/duplicate can never double-rate.
- Both players update against the **opponent's PRE-game rating** (snapshotted
  before either is applied, so order doesn't matter).
- Also records `ratingDelta` on the game for an end-of-game screen.

`onGameFinished` is the single settlement hub — beyond rating it also triggers
stake settlement, conquest settlement, the daily allotment, and stale-game
notification cleanup (see §8, §11).

---

## 6. Game Types & Lifecycle

### Game types (`gameType`)
`casual` | `peer` | `challenge_up` | `outside` | `breach` | `gauntlet`

- **casual** — unstaked quick match (subject to `QUICK_MATCH_DAILY_CAP`).
- **peer** — staked game challenging a *specific* person (fixed symmetric stake).
- **challenge_up** — staking a *higher-rated* player (cost via the §7 formula).
- **outside** — **open lobby** staked game vs a stranger (see §7).
- **breach** / **gauntlet** — conquest games (see §9).

`onGameFinished` routes settlement by type: `peer`/`challenge_up`/`outside` →
`settleStakeForGame`; `breach`/`gauntlet` → `settleConquest`.

### Game lifecycle (engine lives in `index.ts`)
Callables: `createGame`, `joinGame`, `markReady`, `makeMove`, `resign`,
`claimTimeout`.

**Real-time blitz.** Both players are present at the board; the clock runs live.
A per-move time limit is enforced **server-side** — if a player exceeds it, the
opponent calls `claimTimeout` to claim the win. (Because games are real-time
with a live clock, there is deliberately **no "your move" push** — both players
are already at the board. Confirm the exact time control / move-timeout value in
`index.ts`.)

**Ready-up flow:**
1. Game created → `game_ready` notifications sent to both players.
2. Each player enters the board and calls `markReady`.
3. When **both** are in the `ready` set → `game_activated` → game goes live with
   the clock.
- A **12-hour no-show window** (expiry sweep, §12) refunds stakes if a player
  never shows up to ready. So *game start* is NOT latency-critical (relevant to
  FCM: the `game_ready` push has hours of slack). The per-move timeout only
  applies *after* activation.

Move legality is decided **only** by the server. The client board is display.

---

## 7. Stakes & The Open Lobby

### Stake mechanics (`stakes.ts`)
Three staked paths: **peer** (challenge a specific player), **challenge_up**
(stake a higher-rated player), **outside** (open lobby vs a stranger). Stakes
are locked via `appendEntry` (`stake_lock`) and the game links to its stake via
`contextId`. Settlement pays the pot (minus rake) to the winner, or returns
stakes (minus rake) on a draw — handled uniformly by `settleStakeForGame`.

- **Peer** stakes are a **fixed symmetric amount** chosen by the issuer (both
  players stake the same number). They use **no rating formula** — there is
  nothing to size — so they were unaffected by the Glicko migration.
- **Challenge-up** and **open-lobby** stakes are formula-sized (below).

> **Historical bug (fixed):** `challenge_up` games once locked stakes at accept
> time but never settled (CP stranded in escrow forever) because
> `onGameFinished` only settled `peer`. Now `peer`, `challenge_up`, and
> `outside` all settle on the same path. Keep this in mind when adding new
> staked game types — they MUST be added to the settlement routing.

### The stake formulas (`challenge.ts`) — GLICKO-2 THROUGHOUT
All stake-sizing now uses the shared `winProbability` from `glicko.ts` (§5).
There are **two distinct stake shapes**, both Glicko-driven:

**(A) `challengeStakeAmount(player{rating,rd}, opponent{rating,rd}, balance)`** —
the **win-improbability fraction-of-balance** stake, used by **challenge-up**
(both legs) and **conquest** (breach + gauntlet). Each player stakes a fraction
of their **own** balance, scaled by how unlikely their win is:
```
winProb = winProbability(player, opponent)              // Glicko-2, RD-weighted
fraction = BASE_FRACTION + (1 − winProb) × SPREAD
stake    = floor(balance × min(fraction, MAX_FRACTION))
```
Dials: `CHALLENGE_BASE_FRACTION = 0.05`, `CHALLENGE_SPREAD = 0.35`,
`CHALLENGE_MAX_FRACTION = MAX_STAKE_FRACTION = 0.40`. The **underdog** stakes a
*larger* fraction (an improbable upset is an expensive ticket); the **favorite**
a *smaller* fraction. **Object-pair signature** `{rating, rd}` per player so the
RD is always carried to the win-probability and call sites can't transpose bare
numbers.

**(B) `lobbyAccepterStake(posterStake, accepter{rating,rd}, poster{rating,rd},
accepterBalance)`** — the **open-lobby accepter** stake, anchored to the poster's
chosen stake **S** and scaled by the Glicko win odds, then clamped:
```
p     = winProbability(accepter, poster)
raw   = round( S × p / (1 − p) )
stake = clamp( raw, 200, min(3 × S, floor(accepterBalance × 0.40)) )
```
- Equal ratings → p≈0.5 → raw≈S → **symmetric**.
- Favorite → p>0.5 → raw>S, capped at **3×S** (and the 40% balance cap).
- Underdog → p<0.5 → raw<S, floored at **200**.

Lobby dials (LOCKED): `LOBBY_ACCEPTER_FLOOR = 200`, `LOBBY_STAKE_STEP = 50`,
`LOBBY_CEILING_MULT = 3`, **no damping**. The 200 floor is a deliberate
**monetization floor** (CP must drain; the 500/day faucet refills; newcomers
improve on free Quick Match, not in the staked lobby) and also keeps the 5% pot
rake a clean integer.

`validateLobbyPosterStake(stake, posterBalance)` enforces the poster's choice:
≥ 200, ≤ 40% of balance, a multiple of 50 above the floor (200/250/300/…). A
poster whose 40% cap can't reach 200 (balance < 500) cannot post.

> **`difficultyLabel()` is dormant** — zero call sites anywhere (server or
> client). It was left in place but is unused; it does not display, so there is
> no Elo-vs-Glicko label-calibration concern.

### Open Lobby specifics (REDESIGNED — shipped)
- `gameType: "outside"`. A player **posts a public seat with an exact chosen
  stake S** (200+, in steps of 50, up to 40% of balance — picked via a stepper
  dialog). Any eligible stranger **accepts** it.
- The **poster's leg is the fixed S they chose**; the **accepter's leg is
  `lobbyAccepterStake`** (anchored to S, odds-scaled, clamped 200..min(3S,40%)).
  Pots are therefore **asymmetric by rating** but always ≥ S + 200.
- **Seat schema** stores `posterStake` (the chosen S), `posterRating`, **and
  `posterRd`** — the RD is required so the accepter's Glicko-odds stake can be
  computed server-side AND previewed client-side.
- **Client preview:** the accept dialog computes a Dart port of the same Glicko
  formula and shows the accepter, before committing, "You risk ~X / They risk S
  / If you win ~+Z / favored-or-underdog." (Verified to match the server stake
  exactly in production — see §18.)
- **1 open seat per player** at a time. **30-minute seat window** — an
  unaccepted seat expires and refunds the poster (expiry sweep, §12).
- **Daily caps apply** (`counters.ts`): same-opponent and quick-match limits.

> **Backlog — smurfing guardrails (NOT built):** a provisional-rating gate and
> rating-band restrictions on who can post/accept lobby seats. `posterRating`
> and `posterRd` are already recorded to support this. With Glicko-2 staking,
> the RD-weighting already *partially* mitigates the smurf case (an uncertain
> opponent compresses the stake spread); the explicit provisional gate would be
> the stronger wall and remains deferred (the app has no real users yet).

---

## 8. Settlement (How Staked Games End)

When a game's `status` becomes `finished`, `onGameFinished` (asia-southeast1):
1. **Rating:** applies Glicko-2 to both players (idempotent via `ratingApplied`).
2. **Stake settlement** (`peer`/`challenge_up`/`outside` with a `contextId`):
   `settleStakeForGame` pays pot − rake to the winner (or returns stakes − rake
   on a draw); idempotent via the stake's `settled` flag.
3. **Conquest settlement** (`breach`/`gauntlet`): `settleConquest` advances the
   conquest state machine (idempotent on conquest status + stake `settled`). See
   §9 for the breach-win / breach-loss / gauntlet-burn / defender-hold paths.
4. **Daily allotment:** grants 500 CP to each *human* player (skips
   `isBotGame: true`), independent idempotency keyed on `(uid, UTC-day)`.
5. **Notification cleanup:** deletes transient `game_ready` / `game_activated` /
   `stake_accepted` notifications for this game (tapping them would dead-end).

Each step is independently guarded so one failing never crashes the trigger or
suppresses the others.

**Settlement is computed UPSTREAM of stake amounts** — the Glicko migration only
changed how stakes are *computed* at propose/accept; settlement reads whatever
amounts were locked and is agnostic to how they were sized. Conservation
invariants are therefore unaffected by the migration (and were re-verified
post-migration — §18).

---

## 9. Conquest — Circles, Breach & Gauntlet (`conquest.ts`)

A higher-stakes social conquest layer on top of circles (§10).

### Roles (IMPORTANT — enforced by the code)
- An **outsider** (not a member) breaches a circle to win membership.
- **"You can't breach your own circle"** — the circle **owner cannot be the
  breacher** of their own circle; they (or a nominated member) **defend**.
- The **breacher must NOT already be a member** ("you're already a member").
- The **defender must be a member** of the circle being breached (the owner may
  nominate themselves).

So a minimal 2-account conquest test is: **Account A owns a circle; Account B
(outsider, not a member) breaches it; A defends** (self-nominated for the
gauntlet if it gets that far).

### Mechanics
- **Breach:** the outsider stakes CP (via `challengeStakeAmount` (A), Glicko-2,
  capped at 40%) — **only the breacher stakes; the owner's leg is 0**. All
  circle members are notified (`breach_initiated`, fanned out via `notifyManyTx`)
  so they can defend. A defender plays the breach game.
- **Gauntlet:** if the **breacher WINS** the breach, the conquest moves to a
  gauntlet phase where the circle owner **nominates a defender**
  (`gauntlet_nominated` sent to that defender), played as a **best-of-3**.
  Gauntlet stakes are also `challengeStakeAmount`-sized. *(The Gauntlet/best-of
  mechanic is implemented; the per-game burn path is verified structurally — see
  below and §18.)*
- Conquest games (`gameType` `breach`/`gauntlet`) link to their conquest via
  `contextId`; settlement runs through `settleConquest` from `onGameFinished`.
- **Cleanup on circle deletion:** `forceCloseConquestsForCircle` refunds
  escrowed breach/gauntlet stakes before a circle is deleted, so a conquest can
  never orphan and strand CP.

### Settlement paths (VERIFIED — ledger semantics confirmed in production)
- **Breach, breacher WINS** → breacher's stake is **refunded in full**
  (`stake_return`, outcome `breach_win_refund`), **no rake**. Net 0 to the
  breacher; they advance to the gauntlet. (CP is not awarded for winning the
  breach — winning earns the *right to the gauntlet*, not a prize.)
- **Breach, breacher LOSES** → the breacher's **full stake is awarded to the
  defender**, **no rake** (a pure transfer, not a burn, not rake-skimmed).
  Verified: defender's balance rose by exactly the breach stake.
- **Gauntlet game, defender LOSES (circle being conquered)** → the staked amount
  is **burned to the sink** in full (outcome `gauntlet_burn`) — the deflationary
  CP destruction conquest is meant to create.
- **Gauntlet game, defender HOLDS (wins)** → the stake is **returned**
  (`stake_return`, outcome `gauntlet_defender_hold`), no penalty.

> **Design note (flag for review, not a bug):** breach settlement (both win and
> loss) takes **no rake**, unlike standard staked games (peer/lobby/challenge-up
> all rake 5%). Breach-loss is a pure player-to-player transfer; breach-win is a
> pure refund. If breach is *intended* to be rake-free, this is correct as-is. If
> breach losses should also drain CP to the sink via rake, that would be a change
> to `settleConquest`. Decide explicitly.

> Conquest notification *types* that are push-worthy: `breach_initiated` and
> `gauntlet_nominated` (see §13). Outcome notifications stay bell-only.

---

## 10. Circles (`circles.ts`)

Social spaces.

- `circles/{id}`: `name`, `nameLower` (search), `ownerId`, `members[]`
  (includes owner), `memberCount`, timestamps.
- **A user OWNS at most one circle but BELONGS to many** (`ownedCircleId` on the
  user doc enforces the one-owned rule in O(1)).
- The **owner cannot leave** their own circle (prevents orphans); they must
  delete it. Members may leave freely when not mid-conquest-commitment.
- The "crown" (highest-rated member) is **computed on read**, never stored.
- Callables: `createCircle`, `leaveCircle`, `deleteCircle`, `requestJoin`,
  `cancelJoinRequest`, `approveJoin`, `rejectJoin`. Join requests live in a
  `joinRequests` subcollection keyed by uid; owner approval adds to `members`.
- All writes go through functions; rules keep circles read-only to clients.

> **Circle-list rating staleness (known, deferred):** the circle members list in
> `main.dart` reads member ratings via a one-shot `fetchProfiles` (inside a
> `FutureBuilder`) that only re-runs when the *circle* doc changes (membership),
> **not** when a member's *rating* changes. So the challenge-up button's
> rating-gate can render against stale ratings (e.g. show "Challenge" against a
> member whose rating has since risen above yours). The **gate logic itself is
> correct**, and the **server always rejects an invalid challenge-up**
> (`proposeChallengeUp` throws if `issuerRating >= opponentRating`), so this is a
> cosmetic UI leak with a hard server backstop — not an economic risk.
> Re-entering the circle re-fetches and clears it. Proper fix (deferred):
> stream member profiles, or refetch on focus.

---

## 11. Notifications (`notify.ts`)

One `notifications/{id}` doc per (recipient, event); **server-only writes**; the
client lists its own (`recipientId == uid`) to drive an in-app **bell /
notification center**.

**Doc shape:** `{ recipientId, type, title, body, data: Record<string,string>,
read: false, createdAt }`. `data` carries navigation ids (gameId, stakeId,
circleId, conquestId).

**Entry points:**
- `notify(input)` — standalone async write (non-transactional callers).
- `notifyTx(tx, input)` — write **inside a transaction** (atomic with the state
  change). Most events use this.
- `notifyManyTx(tx, recipientIds, base, exclude)` — fan-out to many recipients
  in-tx (e.g. `breach_initiated` to all circle members).
- Cleanup helpers delete stale call-to-action notifications when offers/breaches/
  conquests resolve.

**Notification types (`NotificationType` union):** `join_request`,
`join_approved`, `join_rejected`, `stake_offer`, `challenge_up`,
`stake_accepted`, `stake_declined`, `breach_initiated`, `breach_won`,
`breach_lost`, `member_left`, `gauntlet_nominated`, `game_ready`,
`game_activated`, `forfeit`, `expired`.

---

## 12. Expiry Sweeps (`expiry.ts`)

A **scheduled** function (`expireStaleItems`) that runs periodically in
production to clean up time-bound items. Includes (among sweeps):
- Lobby seat expiry (the **30-minute** unaccepted-seat window → refund poster).
- **Sweep 3 — waiting no-shows:** a game created but never activated is expired
  after a **12-hour** window, refunding stakes. (This is why `game_ready` is not
  latency-sensitive.)
- Offer/window expiries.

> **Scheduler caveat:** scheduled (pubsub) functions only fire in **production**
> (Cloud Scheduler) — the **emulator never runs them**. Confirmed in prod:
> `expireStaleItems` was observed firing (9 invocations/24h).

---

## 13. FCM Push Notifications — Stage 1a (BUILT, DEPLOYED & VERIFIED)

Android-only push, built on the verified production backend.

### Policy: tight allowlist, bell for everything else
Only genuinely time-sensitive, actionable events push to the phone; everything
else stays in the in-app bell (this protects high-rated players from being
buzzed by every stake offer / challenge). **No "your move" push** (real-time
games — both players already at the board).

**Push allowlist (the only types that buzz):**
```
["game_ready", "breach_initiated", "gauntlet_nominated"]
```
- `game_ready` — a staked game you agreed to is waiting for you to enter.
- `breach_initiated` — your circle is under breach; defend.
- `gauntlet_nominated` — you're nominated to defend the gauntlet.

All three were **verified firing in production** during a full conquest series,
each with `sent=1 failed=0 pruned=0`, correctly routed (breach/gauntlet to the
owner; game_ready to both players), and correctly **withholding** non-allowlisted
types (logged-but-not-sent). See §18.

### Architecture: a notification trigger (not inline)
All three push-worthy events are created **inside Firestore transactions**
(`notifyTx` / `notifyManyTx`). You must NOT send FCM inside a transaction (a
retry would duplicate the push). So push is decoupled into a trigger that fires
on the **committed** notification doc:

- **`onNotificationCreated`** (`fcm.ts`) — a **v2 `onDocumentCreated` trigger on
  `notifications/{id}`, region `asia-southeast1`**. It checks the allowlist + a
  `userWantsPush()` seam (returns `true` for everyone in Stage 1a → becomes a
  per-user preference lookup in Stage 1b), reads the recipient's tokens, sends a
  multicast push, and **prunes dead tokens** on send failure. This covers
  `notify` / `notifyTx` / `notifyManyTx` automatically with zero changes to call
  sites.

> **Foreground vs background (important for testing):** a push only draws a
> **system banner** when the recipient device is **backgrounded**. If the app is
> **foregrounded**, the message routes to the in-app bell (`onMessage`), NOT a
> system banner. So "I sent N pushes but saw 1 banner" is usually explained by
> the watched device being foregrounded (actively playing) for most of them, and
> pushes to a *second* device you weren't watching. `sent=1` in the logs means
> FCM accepted the payload, not that a banner visibly drew.

### Token storage & callables
- **`users/{uid}/fcmTokens/{token}`** subcollection — one doc per device, the
  **doc id IS the token** (slash-free, so a valid id), enabling direct
  stale-token deletion. Server-owned (rules deny client access; written/read
  only via Admin SDK).
- **`registerFcmToken`** callable — client saves its token on sign-in and on
  token refresh (upsert; idempotent).
- **`unregisterFcmToken`** callable — client removes its token on sign-out (so a
  different account later on the same device doesn't get the prior account's
  pushes).

### Client (`fcm_messaging.dart` + edits)
- `firebase_messaging: ^14.7.10` (the 14.x line pairs with `firebase_core` 2.x;
  15.x would force a full Firebase-stack upgrade).
- Top-level `@pragma('vm:entry-point')` **background handler** registered in
  `main()` before `runApp` (no-op for Stage 1a; the OS auto-displays
  notification messages when backgrounded/killed).
- **`setupFcm()`** (called in `_HomeScreenState.initState`, i.e. once signed in):
  requests notification permission (Android 13+ runtime prompt), gets the token,
  registers it, and re-registers on `onTokenRefresh` (guarded against duplicate
  listeners).
- **Foreground:** relies on the existing in-app bell (Android doesn't auto-show
  notification messages in foreground) — so **no `flutter_local_notifications`
  dependency** in Stage 1a. Background/closed: system notification is automatic.

### Testing notes
- FCM requires **Google Play Services** — a physical device works; a plain
  Android emulator does NOT (needs a Google-Play system image).
- **Test:** background Device B → on Device A accept a staked game → Device B
  gets a "Game ready" push. Watch `onNotificationCreated` logs for
  `[fcm] ... sent=1`. **Watch the *backgrounded* device, not the one you're
  driving** (the driver is foregrounded → in-app bell, no system banner).
- Tokens persist across app-data wipes on the same physical device; a fresh
  sign-in re-registers automatically (token doc reappears under the new user).
- First deploy of the v2 trigger may need an **Eventarc service-agent
  propagation retry** (the "wait a few minutes, re-run deploy" pattern).

### Backlog — FCM Stage 1b (next)
**Per-user push preferences:** a `pushPrefs` model on the user doc + a settings
UI + a real `userWantsPush()` lookup. The seam already exists in `fcm.ts`; this
slots in without reworking the pipeline. (Deferred because the app has no real
users yet — the allowlist + defaults solve bombardment for now.)

### Backlog — `challenge_up` push (decided, NOT yet applied)
Adding `"challenge_up"` to the push allowlist (so a challenged player is buzzed
about a high-CP-gain opportunity) was **decided** but **not yet applied** to
`fcm.ts`. It is a one-line allowlist change plus a tag tweak
(`tag: data.stakeId || data.gameId || data.conquestId || type`, so simultaneous
challenges stack rather than collapse) and a redeploy of `onNotificationCreated`
only (no app rebuild). The flood risk was accepted (no mute until Stage 1b).

---

## 14. Firestore Data Model (collections)

- `users/{uid}` — profile: `displayName`, `photoURL`, Glicko-2 state
  (`rating`, `rd`, `vol`, `provisional`), stats (`gamesPlayed`, `wins`,
  `losses`, `draws`), cached `cp`, `ownedCircleId`, timestamps.
  - `users/{uid}/fcmTokens/{token}` — FCM device tokens (server-only).
- `games/{gameId}` — game state: players (`whiteId`/`blackId`), `status`,
  `result`, `gameType`, `contextId` (links to stake/conquest), `ready` set,
  `ratingApplied`, `ratingDelta`, `isBotGame`, clock/board state.
- `ledger/{id}` — append-only CP movements (the money source of truth). Entry
  `type`s: `starting_grant`, `daily_allotment`, `stake_lock`, `pot_win`, `rake`,
  `stake_return`. `meta` carries `outcome` labels (`win`, `breach_win_refund`,
  `breach_loss_award`/defender award, `gauntlet_burn`, `gauntlet_defender_hold`)
  and ids (`gameId`, `stakeId`, `conquestId`, `kind`, `leg`, `day`).
- `stakes/{id}` — staked-game records. Fields include issuer/opponent stakes,
  `pot`, `settled`, `settledResult`, `status`, `kind`, and for lobby seats
  `posterStake` / `posterRating` / `posterRd`; for challenge-ups the frozen
  `issuerStake` / `opponentStake` plus propose-time snapshots
  `proposeIssuerRating` / `proposeOpponentRating` / `proposeIssuerRd` /
  `proposeOpponentRd`. Links via `contextId` / `gameId`.
- `circles/{id}` — circles; `circles/{id}/joinRequests/{uid}` — pending joins.
- `conquests/{id}` — breach/gauntlet state machine.
- `conquestCooldowns/{id}` — breach cooldowns between attacker/circle.
- `notifications/{id}` — in-app notifications (per recipient).
- `gameCounts/{uid}_{YYYY-MM-DD}` — daily counters (caps).
- `leaderboards/players` and `leaderboards/circles` — precomputed boards.

**Security model:** all economic/game collections are **write-denied to
clients**; reads are scoped (e.g. you read your own user doc, your own
notifications). A terminal `match /{document=**} { allow read, write: if false }`
backstops everything. Servers mutate via Admin SDK (bypasses rules).

---

## 15. Leaderboards (`leaderboards.ts`)

Two precomputed boards, written as single docs read in one shot (cheap, scalable):
- **`leaderboards/players`** — players with ≥ `MIN_GAMES` (10) rated games,
  ranked by `rating` desc, top 100.
- **`leaderboards/circles`** — circles with ≥ `MIN_CIRCLE_SIZE` (10) members,
  ranked by a **top-quartile score**: the average rating of the top
  `ceil(0.25 × memberCount)` **eligible** (≥10-game) members — but only if the
  circle has at least that many eligible members (Option-2 strict). Top 100.
- Recomputed hourly by a scheduled function (`refreshLeaderboards`). The circle
  score isn't expressible as a Firestore query (it's an average of the top
  quartile of a filtered subset), hence precomputation. Boards are stale up to an
  hour — expected.

---

## 16. Client Architecture (Flutter)

- **`main.dart`** — app entry, Firebase init, the emulator toggle, routing
  (`AuthGate` → login vs `HomeScreen`), and most screens/UI (lobby, board,
  leaderboards, notifications bell). The lobby now includes the **stake-picker
  dialog** (poster chooses S) and the **accept-preview dialog** (accepter sees
  risk/reward before committing).
- **`game_service.dart`** — the single backend facade: all callable invocations
  (`createGame`, `joinGame`, `makeMove`, stake/lobby actions, FCM token
  register/unregister) and Firestore read streams. The client never writes game
  state directly. Includes the **Dart Glicko-2 ports** for client-side previews:
  `myRatingRdCp()`, `lobbyPosterMaxStake()`, `lobbyAccepterStakePreview()`,
  `estimateBreachStake()` (all Glicko, RD-aware), and a private
  `_glickoWinProbability()` mirroring `glicko.ts`.
- **`firebase_options.dart`** — FlutterFire-generated config. **Now correctly
  points at chessmasters-sg** (was previously a stale chessmasters-dev landmine;
  regenerated via `flutterfire configure`). Note: the app actually inits via
  `Firebase.initializeApp()` with **no options** (reads `google-services.json`),
  so `firebase_options.dart` is currently unused — but it's kept correct in case
  init ever switches to `DefaultFirebaseOptions.currentPlatform`.

### The emulator toggle (important for dev)
`main.dart` has, near the top:
```dart
const bool kUseEmulator = false;          // false = real chessmasters-sg backend
const String kEmulatorHost = '192.168.x.x'; // LAN IP for physical-device testing
```
- `kUseEmulator = true` → app uses local Firestore/Functions/Auth emulators
  (host = `10.0.2.2` for the Android emulator, or the PC's LAN IP for a physical
  phone).
- `kUseEmulator = false` → app talks to **real chessmasters-sg** (current state).
- `FirebaseFunctions.instance` defaults to **us-central1**, which matches where
  the callables are deployed — so no region needs pinning on the client.

---

## 17. Dev & Deploy Workflow (Windows)

**Division of labor:** Claude writes/explains code; Shishir runs, deploys, and
tests on devices.

- **Dart change** → hot restart `R`. **BUT** changing `main()` / Firebase init /
  `google-services.json` → **full `flutter run` rebuild** (hot restart is
  insufficient).
- **Functions `.ts` change** → **`npm run build` is MANDATORY** before deploy
  (compiles `src` → `lib`). `npm run build` in the real project is the
  *definitive* TypeScript check (standalone `npx tsc --noEmit` in a scratch dir
  shows false errors).
- **Deploy:** ensure the active project is chessmasters-sg (`firebase use`), then
  `firebase deploy --only firestore:rules,functions`. In **PowerShell**, quote
  comma-separated targets (`--only "functions,firestore:rules"`) and **do not add
  a trailing period** to a target. **New v2 Eventarc triggers may need a
  propagation retry** on first deploy.
- **Adding a native dependency** (e.g. `firebase_messaging`) → `flutter pub get`
  + full `flutter run` (not hot reload).
- **Stuck ports / emulator wedged:** `taskkill /F /IM java.exe`. Emulator restart
  wipes data (fresh sign-in needed); stale auth shows as `INVALID_REFRESH_TOKEN`.
- **No angle brackets** in `flutter run -d <device>` commands.
- `firebase functions:shell` is **broken** in this environment (SDK 4.9.0 + Node
  24) — test via the app instead.
- **FCM has no emulator** — test on a real device / Google-Play emulator.
- **`grep` is not available in PowerShell** — use `Select-String -Path … -Pattern
  …` (pipe to `Format-Table LineNumber, Line -Wrap` for full lines).

### Clean-slate reset procedure (for fresh reconciliation)
Two strategies, both verified:
- **Keep auth (manual field reset):** wipe every collection **except `users`**
  via `firebase firestore:delete <collection> --recursive --force`; then
  re-create each `grant_{uid}` ledger doc (amount 5000, type `starting_grant`)
  and overwrite each user doc's `cp:5000, rating:1500, rd:350, vol:0.06`, stats
  0, `provisional:true`. Preserves UIDs, circle ownership, and FCM tokens.
- **Full ground-zero (auto-reseed via trigger):** delete the **Auth** users
  (Console → Authentication → Users) *and* all Firestore collections; sign in
  fresh → the `onUserCreate` **Auth** trigger auto-creates profiles + the 5000
  grant. **Gives NEW UIDs** (Google sign-in maps to a new UID), invalidating any
  noted UIDs and circle references — only choose this if fresh identities are
  wanted. (`onUserCreate` is an **Auth** trigger, so deleting only the Firestore
  `users` doc does NOT re-fire it — that path leaves a broken, profile-less Auth
  user.)
- After reset, confirm the active project with `firebase use` before any
  `--force` delete (irreversible, no undo).

### Test accounts (pre-production; only test players exist)
> **Note:** after a recent full ground-zero reset, the test accounts were
> re-created with **new UIDs**. Historical UIDs in older notes are stale.
- **Shishir Kushwaha** (shishirkush@gmail.com) — UID
  `qULbvMEbbsVIBtju2vOiCw1yWQc2`
- **Satyajeet Kumar** — UID `mX9wWmnR6TP1rV2mnK4ABxOUjD33`
- *(Pre-reset UIDs, now defunct: NFS Shishir `8iHhHEz5JQVudOG9gmxr4buQZwx1`,
  Satyajeet `lvjYk8U5Y5Z8VJglxdQgyrWYyoz1`.)*
- Devices: emulators `emulator-5554` / `emulator-5556` + a physical Realme
  RMX2002 (the Realme is the reliable FCM device; emulators flake on
  network/DNS / need a cold boot).

---

## 18. Production Verification Status (what's proven)

The Singapore migration and the Glicko-2 stake-sizing rework are **fully
verified end-to-end**, not just deployed:
- Google Sign-In + home load against chessmasters-sg ✓
- `onUserCreate` grants starting CP in prod ✓ (and auto-reseeds on a fresh
  ground-zero sign-in)
- Schedulers fire in prod (`expireStaleItems` observed, 9 invocations/24h) ✓
- `onGameFinished` fires in asia-southeast1 and settles correctly ✓

### Glicko-2 rework — batched reconciliation (decimal-exact, clean slate)
From a verified clean slate (both accounts 5000 CP / 1500 rating, ledger = two
grants only), each staked game type was played in isolation and reconciled. For
**every** batch: per-account **ledger-sum equals the cached `cp` field exactly**,
**CP conservation summed to zero**, the **Glicko-2 stake** matched the formula to
the integer, and the **Glicko-2 rating update matched to the decimal** (the full
update reproduced, including the Illinois-algorithm volatility step):

- **Batch 1 — Peer stake (symmetric):** fixed-amount settlement; rating bit-exact
  (winner +162 / loser −162 from 1500/1500, rd 350→290.32, vol shift correct). ✓
- **Batch 2 — Open lobby (the Glicko redesign):** poster picked S=300; accepter
  (underdog) stake **floored at 200** — and the **client accept-dialog preview,
  the server `stakes` doc, and the hand-computed formula ALL agreed on 200**
  (client/server formula-port alignment verified). Upset win rating bit-exact
  (+229 underdog swing; vol ticked *up* for the surprise). ✓
- **Batch 3 — Challenge-up (frozen-at-propose):** underdog issuer staked the
  larger fraction (1556 vs favorite's 920); both RD snapshots captured; frozen
  terms held through settlement; CP and rating bit-exact. ✓
- **Batch 4a — Conquest breach (breacher LOSES — a previously-unobserved path):**
  favorite breacher's small stake (1040 = 16.1%) correct; on the loss, the **full
  stake transferred to the defender with no rake**; rating bit-exact (defender's
  +133 upset win). `breach_initiated` push fired to the owner. ✓
- **Conquest gauntlet (best-of-3 burn-to-sink):** the breach-loss ended the
  conquest, so the **gauntlet was not exercised in the clean-slate run** — but
  its settlement was **structurally verified earlier** via ledger double-entry
  (each gauntlet `stake_lock` matched by either `gauntlet_burn` → sink or
  `gauntlet_defender_hold` → return). A dedicated **breacher-wins** run is still
  the way to reconcile a gauntlet from a clean slate. *(Pending.)*

### FCM Stage 1a — verified
During a full conquest series, all three allowlisted types
(`game_ready`, `breach_initiated`, `gauntlet_nominated`) logged
`sent=1 failed=0 pruned=0`, correctly routed, with non-allowlisted types
correctly withheld (logged-but-not-sent). A system banner was visually confirmed
on a backgrounded device; the foreground/background routing accounts for the
observed banner counts.

---

## 19. Backlog / Deferred (not yet built)

- **Conquest gauntlet clean-slate reconciliation:** run a conquest where the
  **breacher wins** the breach, to reconcile the best-of-3 gauntlet (per-game
  `gauntlet_burn` / `gauntlet_defender_hold`) from a clean slate to the decimal.
- **`challenge_up` FCM push:** apply the decided one-line allowlist + tag change
  to `fcm.ts` and redeploy `onNotificationCreated` (see §13).
- **Breach rake decision:** decide whether breach settlement should rake to the
  sink (currently rake-free — §9). Design call, not a bug.
- **FCM Stage 1b:** per-user push preferences (`pushPrefs` + settings UI + real
  `userWantsPush`; seam exists).
- **Later FCM:** deep-linking on notification tap (data payload already carries
  ids); custom Android notification channel. ("Your move" push deemed
  unnecessary — real-time games.)
- **Lobby smurfing guardrails:** provisional-rating gate + rating-band
  restrictions on who can post/accept lobby seats (`posterRating`/`posterRd`
  already recorded). Glicko-2 RD-weighting already partially mitigates; the gate
  is the stronger wall.
- **Circle-list rating staleness:** stream member profiles or refetch on focus so
  the challenge-up button's rating-gate never renders against stale ratings
  (§10). Cosmetic; server backstop already prevents invalid challenges.
- **Co-locate** the ~30 us-central1 callables to asia-southeast1 (latency polish;
  optional).
- **firebase-functions SDK 4.9.0 → v5+** (deploy nags; optional, breaking).
- **Delete abandoned `chessmasters-dev`** eventually (no rush).
- **UX:** stake-confirmation dialog clips the "max is X CP" message.
- **Dead code:** `difficultyLabel()` in `challenge.ts` (zero call sites);
  `_opponentLowSince` field in `main.dart`; boilerplate `test/widget_test.dart`
  references a non-existent `MyApp`.

---

## 20. Key Files Index

**Backend (`functions/src/`):**
`index.ts` (game engine + exports), `init.ts` (Admin init / `db`),
`users.ts` (profiles + `onUserCreate` auth trigger), `glicko.ts` (rating math +
exported `winProbability`), `rating.ts` (`onGameFinished`),
`ledger.ts` (CP primitives + economic dials),
`stakes.ts` (peer/challenge/lobby stakes + lobby poster-picks redesign +
settlement), `challenge.ts` (Glicko-2 stake formulas: `challengeStakeAmount` +
`lobbyAccepterStake` + `validateLobbyPosterStake`), `counters.ts` (daily caps),
`circles.ts` (circles), `conquest.ts` (breach/gauntlet),
`leaderboards.ts` (boards), `expiry.ts` (sweeps), `notify.ts` (notifications),
`fcm.ts` (FCM trigger + token callables).

**Client (`app/lib/`):**
`main.dart` (entry + UI + emulator toggle + lobby picker/preview dialogs),
`game_service.dart` (backend facade + Dart Glicko-2 preview ports),
`fcm_messaging.dart` (FCM client setup), `firebase_options.dart`
(chessmasters-sg config).

**Config:** `firestore.rules` (server-authoritative deny model),
`firebase.json`, `.firebaserc` (aliases under `"projects"`),
`functions/package.json` (Node 20).
