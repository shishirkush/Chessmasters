# Chess Masters — Slice 1: Authoritative Live Chess

Two-player online chess where **the server decides every move's legality and the
result**. The Flutter app only sends move intents and renders the board it's
told to. No CP, no rating, no payments yet — that's slices 2–4. This slice
proves the foundation that everything else (money included) safely sits on.

## What's here

```
chessmasters/
├── firebase.json            # functions + firestore + emulator config
├── firestore.rules          # clients READ games, NEVER write (integrity core)
├── functions/               # TypeScript Cloud Functions = the game authority
│   ├── src/index.ts         # createGame / joinGame / makeMove / claimTimeout / resign
│   ├── package.json
│   └── tsconfig.json
└── app/                     # Flutter client
    ├── pubspec.yaml
    └── lib/
        ├── main.dart        # UI: home + live game screen + clock display
        └── game_service.dart# the only backend contact layer
```

## Updated to current V1 spec

This slice now includes the V1 essentials beyond the original proof-of-concept:

- **5+3 blitz clock, server-authoritative.** Each player has remaining ms stored
  server-side; on every move the server computes elapsed time from its OWN
  clock, deducts it, adds the 3-second increment, and checks flag-fall. The
  client only displays a countdown — it never reports or decides time.
- **90-second abandonment rule.** `claimTimeout` lets a waiting opponent ask the
  server to resolve a stalled game: if the player to move has run out → loss on
  time; if idle past 90s with time remaining → loss by abandonment. The server
  judges from its own clock. (Both vanish → would resolve to a draw; extend as
  needed.)
- **`gameType` + `contextId` on the game doc.** Every game is tagged with what
  it's FOR (casual / peer / challenge_up / outside / breach / gauntlet). Slice 1
  only creates `casual` games; later slices create the others and read the
  result to apply CP/rating/conquest consequences — without changing this engine.

## Still deferred to later slices (per the V1 design doc)

- **Real accounts (Google Sign-In)** — slice 1 still uses anonymous auth; slice 2
  replaces it. This is the persistent identity the circle/ownership model needs.
- **Quick-match 3/day cap** — slice 1 pairs whoever's waiting; the daily cap and
  rating-awareness come with slice 2/3.
- **Rating, CP, circles, conquest** — slices 2–4.

## The one idea that matters

The client never decides truth. `makeMove` runs on the server, rebuilds the
position from the stored FEN, validates with chess.js, and is the only writer
of game state. Firestore rules block all client writes. So a hacked app
**cannot** make an illegal move or declare itself the winner — it has no write
path. When money arrives in slice 4, balances get the same treatment.

## Prerequisites

- Flutter SDK (you have this)
- Node.js 18 and the Firebase CLI: `npm install -g firebase-tools`
- A Firebase project (free Spark plan is fine for the emulator)

## Setup

### 1. Backend / functions

```bash
cd chessmasters
firebase login
firebase use --add        # pick (or create) your Firebase project

cd functions
npm install               # pulls chess.js, firebase-admin, firebase-functions
npm run build             # compiles TypeScript -> lib/
```

### 2. Run the emulators (your testing loop)

From the `chessmasters/` root:

```bash
firebase emulators:start --only functions,firestore,auth
```

Emulator UI: http://localhost:4000  (watch game docs update live here)

> Enable **Anonymous** sign-in in Firebase console → Authentication → Sign-in
> method. The auth emulator honours it locally.

### 3. Flutter app

```bash
cd app
flutter pub get
```

Add your Android Firebase config:
- In Firebase console, add an Android app, download `google-services.json`,
  place it in `app/android/app/google-services.json`.
- Make sure `app/android/build.gradle` and `app/android/app/build.gradle`
  include the Google services plugin (standard FlutterFire setup; run
  `flutterfire configure` if you prefer the automated route).

`main.dart` already points at the emulator via `10.0.2.2` (the Android
emulator's alias for your host machine). Keep `kUseEmulator = true` while
testing locally; set it to `false` to run against deployed functions.

```bash
flutter run
```

## Testing two players

The whole point is two people in one game. Easiest ways:

- **Two emulators:** launch a second Android emulator (AVD Manager → another
  device) and `flutter run -d <deviceId>` on each. Tap **Quick Match** on both.
- **Emulator + physical device**, or emulator + a second AVD.

The first tap creates a waiting game; the second is matched into it as Black.
Make moves on White's app → they appear on Black's instantly (Firestore
realtime), and vice versa. Try an illegal move or moving on the wrong turn —
the server rejects it and the board snaps back.

## Deploying for real (optional now)

```bash
cd chessmasters
firebase deploy --only firestore:rules,functions
```

Then set `kUseEmulator = false` in `main.dart`. Cloud Functions need the
Blaze (pay-as-you-go) plan to deploy, though the free tier covers light usage.

## What slice 1 deliberately leaves out (coming next)

- **Slice 2 — Ratings:** Glicko-2, recorded per finished game.
- **Slice 3 — CP economy:** the append-only ledger, challenges with CP stakes.
- **Slice 4 — Payments:** Google Play Billing for CP, server-side receipt
  validation. Highest risk; gets the most testing and a security review.
- Reconnection/clocks, real accounts, matchmaking by rating, tournaments,
  anti-cheat.

## Known slice-1 simplifications

- Anonymous auth only (real accounts later).
- Quick-match scans up to 10 waiting games; fine for testing, replace with a
  proper matchmaking queue at scale.
- No game clock yet (timeouts come with ratings/stakes where they matter).
- A disconnect doesn't auto-resolve the game yet.
