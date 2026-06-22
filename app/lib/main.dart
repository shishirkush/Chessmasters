import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:simple_chess_board/simple_chess_board.dart';

import 'game_service.dart';

// Toggle this to true while testing against the local Firebase emulators.
const bool kUseEmulator = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // uses google-services.json on Android

  if (kUseEmulator) {
    // 10.0.2.2 is how the Android emulator reaches the host machine.
    FirebaseFirestore.instance.useFirestoreEmulator('10.0.2.2', 8080);
    FirebaseFunctions.instance.useFunctionsEmulator('10.0.2.2', 5001);
    await FirebaseAuth.instance.useAuthEmulator('10.0.2.2', 9099);
  }

  runApp(const ChessMastersApp());
}

class ChessMastersApp extends StatelessWidget {
  const ChessMastersApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Masters',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B5B92),
      ),
      home: const AuthGate(),
    );
  }
}

/// Watches Firebase auth state and shows either the sign-in screen (when
/// signed out) or the home screen (when signed in). Because we listen to
/// authStateChanges(), the app automatically routes correctly on launch
/// (Firebase restores the previous session) and on sign-in/sign-out.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final service = GameService();
    return StreamBuilder<User?>(
      stream: service.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snap.data;
        if (user == null) {
          return SignInScreen(service: service);
        }
        return HomeScreen(service: service);
      },
    );
  }
}

/// Sign-in screen — a single "Sign in with Google" button.
class SignInScreen extends StatefulWidget {
  final GameService service;
  const SignInScreen({super.key, required this.service});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.signInWithGoogle();
      // On success, the AuthGate's stream fires and routes to HomeScreen.
      // (No navigation needed here.)
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Sign-in failed.');
    } catch (e) {
      setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.castle, size: 72),
            const SizedBox(height: 8),
            const Text('Chess Masters',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Sign in to play',
                style: TextStyle(fontSize: 14, color: Colors.black54)),
            const SizedBox(height: 32),
            if (_busy)
              const CircularProgressIndicator()
            else
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login),
                label: const Text('Sign in with Google'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final GameService service;
  const HomeScreen({super.key, required this.service});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  GameService get _service => widget.service;
  bool _busy = false;
  String? _status;

  // Auto-navigation into active games. A staked/challenge game is created
  // server-side when the OPPONENT accepts, so the issuer (challenger) has no
  // action that returns a gameId — without this they'd sit on whatever screen
  // they were on while their game (and clock) is live. This listener watches
  // the user's active games and pulls them into the board the moment one
  // appears, no matter which screen is on top. Works uniformly for the
  // accepter and the issuer, peer stakes and challenge-ups.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _activeGamesSub;
  final Set<String> _navigatedGameIds = {};
  bool _inGame = false; // true while a GameScreen is on top (prevents stacking)

  @override
  void initState() {
    super.initState();
    _activeGamesSub =
        _service.activeGamesStream().listen(_onActiveGames);
  }

  @override
  void dispose() {
    _activeGamesSub?.cancel();
    super.dispose();
  }

  void _onActiveGames(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!mounted || _inGame) return;
    // Find the first active game we haven't already routed into.
    for (final doc in snap.docs) {
      if (_navigatedGameIds.contains(doc.id)) continue;
      _navigatedGameIds.add(doc.id);
      _enterGame(doc.id);
      break; // one at a time
    }
  }

  Future<void> _enterGame(String gameId) async {
    if (_inGame) return;
    _inGame = true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GameScreen(gameId: gameId, service: _service),
    ));
    // Returned from the board (game over or user backed out).
    _inGame = false;
  }

  Future<void> _quickMatch() async {
    setState(() {
      _busy = true;
      _status = 'Finding a game…';
    });
    try {
      // User is already signed in (the AuthGate guarantees it), so we go
      // straight to matchmaking — no ensureSignedIn() needed.
      final gameId = await _service.quickMatch();
      if (!mounted) return;
      _navigatedGameIds.add(gameId); // avoid the listener double-pushing
      _enterGame(gameId);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _service.currentUser;
    final name = user?.displayName ?? user?.email ?? 'Player';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Masters'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => _service.signOut(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.castle, size: 72),
            const SizedBox(height: 8),
            Text('Signed in as $name',
                style: const TextStyle(fontSize: 14, color: Colors.black54)),
            const SizedBox(height: 12),
            // Live CP balance + rating. CP comes from the ledger sum; rating
            // from the profile. Both update live.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<int>(
                  stream: _service.myCpBalanceStream(),
                  builder: (context, snap) {
                    final cp = snap.data;
                    return _StatChip(
                      icon: Icons.toll,
                      label: cp == null ? 'CP …' : '$cp CP',
                    );
                  },
                ),
                const SizedBox(width: 10),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _service.myProfileStream(),
                  builder: (context, snap) {
                    final data = snap.data?.data();
                    final rating = (data?['rating'] as num?)?.round();
                    return _StatChip(
                      icon: Icons.military_tech,
                      label: rating == null ? 'Rating …' : 'Rating $rating',
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Resume an in-progress game (e.g. a staked game created when an
            // opponent accepted your offer — the issuer has no other way in).
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _service.activeGamesStream(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) return const SizedBox.shrink();
                final gameId = docs.first.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.green.shade700),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            GameScreen(gameId: gameId, service: _service),
                      ),
                    ),
                    icon: const Icon(Icons.sports_esports),
                    label: Text(docs.length > 1
                        ? 'Resume game (${docs.length})'
                        : 'Resume game'),
                  ),
                );
              },
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _quickMatch,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Quick Match'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CirclesScreen(service: _service),
                      )),
              icon: const Icon(Icons.groups),
              label: const Text('Circles'),
            ),
            const SizedBox(height: 16),
            if (_busy) const CircularProgressIndicator(),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Tip: launch two emulators (or an emulator + a device) and '
                'tap Quick Match on both to be paired into one game.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pill showing a stat (CP balance, rating) on the home screen.
class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.indigo.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Colors.indigo),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.indigo)),
        ],
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final String gameId;
  final GameService service;
  const GameScreen({super.key, required this.gameId, required this.service});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  // The board is driven directly by the SERVER's FEN string. We keep the
  // latest authoritative FEN here and hand it to SimpleChessBoard. The widget
  // never decides legality — it only displays this FEN and reports move intents.
  String _currentFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  bool _sending = false;

  // ---- Local display clock (server stays authoritative) ----
  Timer? _ticker;          // 1s display tick
  int _tick = 0;           // increments each second to force clock redraw
  DateTime? _opponentLowSince; // when the opponent first appeared out of time
  bool _claimingTimeout = false;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Start/stop a 1-second ticker while the game is active. The ticker only
  /// drives DISPLAY (counting down the side-to-move's clock visually). If the
  /// OPPONENT appears to have run out for a few seconds, we ask the SERVER to
  /// resolve it via claimTimeout — we never decide the result ourselves.
  void _trackClock(String status, String turn, bool myTurn) {
    final active = status == 'active';
    if (active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _tick++);
        // If it's the OPPONENT's turn and they seem to have flagged, give the
        // server a moment then ask it to check. (Server is the judge.)
        if (!myTurn && !_claimingTimeout) {
          _maybeClaimTimeout();
        }
      });
    } else if (!active && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
      _opponentLowSince = null;
    }
  }

  Future<void> _maybeClaimTimeout() async {
    // Throttle: only poll the server occasionally, not every tick.
    _claimingTimeout = true;
    try {
      final res = await widget.service.claimTimeout(widget.gameId);
      // If the server resolved it, the stream will deliver the finished state.
      // If not, nothing happens — the game continues.
      if (res['resolved'] != true) {
        // not resolved; allow another attempt later
      }
    } catch (_) {
      // Ignore — transient; the stream remains the source of truth.
    } finally {
      // Re-allow a future claim after a short delay to avoid hammering.
      Future.delayed(const Duration(seconds: 5), () => _claimingTimeout = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = widget.service.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Game'),
        actions: [
          IconButton(
            tooltip: 'Resign',
            icon: const Icon(Icons.flag),
            onPressed: () => widget.service.resign(widget.gameId),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: widget.service.gameStream(widget.gameId),
        builder: (context, snap) {
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final g = snap.data!.data()!;
          final status = g['status'] as String;
          final fen = g['fen'] as String;
          final turn = g['turn'] as String; // 'w' | 'b'
          final whiteId = g['whiteId'] as String?;
          final blackId = g['blackId'] as String?;
          final result = g['result'] as String?;
          final reason = g['resultReason'] as String?;

          // Clock fields (server-authoritative; we only DISPLAY them).
          final whiteMs = (g['whiteMs'] as num?)?.toInt() ?? 0;
          final blackMs = (g['blackMs'] as num?)?.toInt() ?? 0;

          // Which colour am I? Determines board orientation and move rights.
          final iAmWhite = myUid == whiteId;
          final iAmBlack = myUid == blackId;
          final myTurn = (turn == 'w' && iAmWhite) || (turn == 'b' && iAmBlack);

          // Track the SERVER's FEN as the source of truth for the board.
          _currentFen = fen;

          // Keep the local display ticker aware of the active game so it can
          // count down the side-to-move's clock for display and, if the
          // OPPONENT runs out / abandons, prompt the server to resolve it.
          _trackClock(status, turn, myTurn);

          // Player-type gate: a side is "human" (movable) only if it's MY
          // colour AND it's my turn AND the game is active and I'm not mid-send.
          // Everything else is "computer" (locked). The server also enforces
          // turn/legality — this is the client-side belt-and-braces.
          final canMove = status == 'active' && myTurn && !_sending;
          final whiteType = (iAmWhite && canMove)
              ? PlayerType.human
              : PlayerType.computer;
          final blackType = (iAmBlack && canMove)
              ? PlayerType.human
              : PlayerType.computer;

          return Column(
            children: [
              _ClockBar(
                status: status,
                turn: turn,
                whiteMs: whiteMs,
                blackMs: blackMs,
                iAmWhite: iAmWhite,
                tick: _tick, // forces recompute each second
              ),
              _StatusBar(
                status: status,
                myTurn: myTurn,
                iAmWhite: iAmWhite,
                iAmBlack: iAmBlack,
                result: result,
                reason: reason,
              ),
              Expanded(
                child: Center(
                  child: SimpleChessBoard(
                    fen: _currentFen,
                    blackSideAtBottom: iAmBlack,
                    whitePlayerType: whiteType,
                    blackPlayerType: blackType,
                    engineThinking: false,
                    onMove: ({required ShortMove move}) =>
                        _onLocalMove(move),
                    onPromote: () async => PieceType.queen,
                    onPromotionCommited: ({
                      required ShortMove moveDone,
                      required PieceType pieceType,
                    }) {
                      // Promotion is sent to the server as part of the move;
                      // nothing to update locally (server returns new FEN).
                    },
                    // Required by the widget; we don't need custom tap
                    // behaviour (moves go through onMove), so this is a no-op.
                    onTap: ({required String cellCoordinate}) {},
                    // Required: which squares to tint. We highlight none.
                    cellHighlights: const <String, Color>{},
                    chessBoardColors: ChessBoardColors()
                      ..lastMoveArrowColor = Colors.blueAccent,
                  ),
                ),
              ),
              if (_sending)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The board reported a tentative move (ShortMove from simple_chess_board).
  /// We DO NOT trust it as truth — we send from/to (+promotion) to the server
  /// and let the authoritative FEN come back through the stream. If the server
  /// rejects it, the stream simply keeps the last good FEN (the board re-renders
  /// from _currentFen, which we never advanced locally).
  Future<void> _onLocalMove(ShortMove move) async {
    if (_sending) return;
    final from = move.from;
    final to = move.to;
    // simple_chess_board's promotion is a PieceType?; the server expects a
    // single-char string ('q','r','b','n') or null.
    String? promo;
    switch (move.promotion) {
      case PieceType.queen:
        promo = 'q';
        break;
      case PieceType.rook:
        promo = 'r';
        break;
      case PieceType.bishop:
        promo = 'b';
        break;
      case PieceType.knight:
        promo = 'n';
        break;
      default:
        promo = null;
    }

    setState(() => _sending = true);
    try {
      await widget.service.makeMove(
        gameId: widget.gameId,
        from: from,
        to: to,
        promotion: promo,
      );
      // Success: the stream will deliver the new authoritative FEN, which
      // re-renders the board. We never advanced the board locally.
    } on FirebaseFunctionsException catch (e) {
      // Rejected by server — the board stays on the last good FEN (_currentFen
      // was not changed locally), so nothing to roll back. Just inform the user.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Move rejected: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

class _StatusBar extends StatelessWidget {
  final String status;
  final bool myTurn;
  final bool iAmWhite;
  final bool iAmBlack;
  final String? result;
  final String? reason;

  const _StatusBar({
    required this.status,
    required this.myTurn,
    required this.iAmWhite,
    required this.iAmBlack,
    required this.result,
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    String text;
    if (status == 'waiting') {
      text = 'Waiting for an opponent to join…';
    } else if (status == 'finished') {
      final iWon = (result == 'white' && iAmWhite) ||
          (result == 'black' && iAmBlack);
      if (result == 'draw') {
        text = 'Draw (${reason ?? ''})';
      } else {
        text = iWon ? 'You won (${reason ?? ''})' : 'You lost (${reason ?? ''})';
      }
    } else {
      final colour = iAmWhite ? 'White' : (iAmBlack ? 'Black' : 'Spectator');
      text = myTurn ? 'Your move ($colour)' : 'Opponent\'s move ($colour)';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

/// Displays both players' clocks. Server-authoritative times come from the
/// game doc (whiteMs/blackMs); for the side to move we count DOWN locally each
/// second purely for display. The server remains the judge of flag-fall —
/// this widget never decides a result.
class _ClockBar extends StatelessWidget {
  final String status;
  final String turn; // 'w' | 'b'
  final int whiteMs;
  final int blackMs;
  final bool iAmWhite;
  final int tick; // changes each second to force a rebuild

  const _ClockBar({
    required this.status,
    required this.turn,
    required this.whiteMs,
    required this.blackMs,
    required this.iAmWhite,
    required this.tick,
  });

  String _fmt(int ms) {
    if (ms < 0) ms = 0;
    final totalSec = ms ~/ 1000;
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // For display only: show the stored times. (A more advanced version would
    // subtract local elapsed time for the side to move; kept simple here since
    // the stream refreshes on every move and the server is authoritative.)
    final myMs = iAmWhite ? whiteMs : blackMs;
    final oppMs = iAmWhite ? blackMs : whiteMs;
    final myColourToMove = (turn == 'w' && iAmWhite) || (turn == 'b' && !iAmWhite);

    Widget clock(String label, int ms, bool isActive) {
      return Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          Text(
            _fmt(ms),
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: isActive && status == 'active'
                  ? Theme.of(context).colorScheme.primary
                  : Colors.black87,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          clock('You', myMs, myColourToMove),
          clock('Opponent', oppMs, !myColourToMove),
        ],
      ),
    );
  }
}

// =============================================================================
// SLICE 2c: Circles
// =============================================================================

/// Lists the circles the user belongs to, distinguishes the one they own,
/// and lets them create a circle (if they don't already own one).
class CirclesScreen extends StatelessWidget {
  final GameService service;
  const CirclesScreen({super.key, required this.service});

  Future<void> _createCircle(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create a circle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'Circle name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await service.createCircle(name);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Created "$name"')));
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message ?? 'Failed')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circles'),
        actions: [
          IconButton(
            tooltip: 'Search circles',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SearchCirclesScreen(service: service),
            )),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: service.myProfileStream(),
        builder: (context, profileSnap) {
          final ownedCircleId =
              profileSnap.data?.data()?['ownedCircleId'] as String?;
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: service.myCirclesStream(),
            builder: (context, circlesSnap) {
              if (circlesSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = circlesSnap.data?.docs ?? [];
              return Column(
                children: [
                  Expanded(
                    child: docs.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Text(
                                "You're not in any circles yet.\n"
                                'Create one below, or search to join (coming soon).',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.black54),
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: docs.length,
                            itemBuilder: (context, i) {
                              final c = docs[i].data();
                              final id = docs[i].id;
                              final isOwner = id == ownedCircleId;
                              final count = (c['memberCount'] ?? 0) as int;
                              return ListTile(
                                leading: const Icon(Icons.groups),
                                title: Text(c['name'] as String? ?? 'Circle'),
                                subtitle: Text(
                                    '$count member${count == 1 ? '' : 's'}'),
                                trailing: isOwner
                                    ? const Chip(
                                        label: Text('Owner'),
                                        visualDensity: VisualDensity.compact,
                                      )
                                    : null,
                                onTap: () =>
                                    Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => CircleDetailScreen(
                                    service: service,
                                    circleId: id,
                                  ),
                                )),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ownedCircleId == null
                        ? FilledButton.icon(
                            onPressed: () => _createCircle(context),
                            icon: const Icon(Icons.add),
                            label: const Text('Create a circle'),
                          )
                        : const Text(
                            'You already own a circle (one per account).',
                            style: TextStyle(color: Colors.black54),
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Shows a circle's members sorted by rating (top = crown holder), and
/// lets a member leave or the owner delete.
class CircleDetailScreen extends StatelessWidget {
  final GameService service;
  final String circleId;
  const CircleDetailScreen({
    super.key,
    required this.service,
    required this.circleId,
  });

  @override
  Widget build(BuildContext context) {
    final myUid = service.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Circle')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: service.circleStream(circleId),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data?.data();
          if (data == null) {
            return const Center(child: Text('This circle no longer exists.'));
          }
          final name = data['name'] as String? ?? 'Circle';
          final ownerId = data['ownerId'] as String?;
          final members =
              (data['members'] as List?)?.cast<String>() ?? <String>[];
          final isOwner = myUid == ownerId;

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: service.fetchProfiles(members),
            builder: (context, profSnap) {
              if (!profSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final profiles = [...profSnap.data!];
              // Crown order (design §10): highest-rated holds the crown.
              // Tie-breakers for equal ratings (so the crown is stable, not
              // arbitrary): a more *established* 1500 outranks a fresh one.
              //   1) higher rating
              //   2) lower RD (less uncertain = more proven)
              //   3) more games played
              //   4) uid (final deterministic fallback)
              num n(Map<String, dynamic> p, String k, num fallback) =>
                  (p[k] ?? fallback) as num;
              profiles.sort((a, b) {
                final byRating = n(b, 'rating', 0).compareTo(n(a, 'rating', 0));
                if (byRating != 0) return byRating;
                // lower RD ranks higher → compare a vs b (ascending)
                final byRd = n(a, 'rd', 350).compareTo(n(b, 'rd', 350));
                if (byRd != 0) return byRd;
                final byGames =
                    n(b, 'gamesPlayed', 0).compareTo(n(a, 'gamesPlayed', 0));
                if (byGames != 0) return byGames;
                return (a['uid'] as String? ?? '')
                    .compareTo(b['uid'] as String? ?? '');
              });

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('${members.length} member'
                            '${members.length == 1 ? '' : 's'}',
                            style: const TextStyle(color: Colors.black54)),
                      ],
                    ),
                  ),
                  // Slice 4: shows a Defend call-to-action when this circle is
                  // under an active breach (renders nothing otherwise).
                  _BreachDefendBanner(service: service, circleId: circleId),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: profiles.length,
                      itemBuilder: (context, i) {
                        final p = profiles[i];
                        final isCrown = i == 0; // highest-rated holds the crown
                        final isThisOwner = p['uid'] == ownerId;
                        final rating = (p['rating'] ?? 1500).round();
                        final memberUid = p['uid'] as String?;
                        final isMe = memberUid == myUid;
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text('${i + 1}'),
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  p['displayName'] as String? ?? 'Player',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isCrown) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.emoji_events,
                                    size: 18, color: Colors.amber),
                              ],
                            ],
                          ),
                          subtitle: Text(isThisOwner ? 'Owner' : ''),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('$rating',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              if (!isMe && memberUid != null) ...[
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () => _showStakeDialog(
                                    context,
                                    service,
                                    opponentId: memberUid,
                                    opponentName:
                                        p['displayName'] as String? ?? 'Player',
                                    circleId: circleId,
                                  ),
                                  child: const Text('Stake'),
                                ),
                                const SizedBox(width: 4),
                                OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: Colors.deepOrange,
                                  ),
                                  onPressed: () => _showChallengeDialog(
                                    context,
                                    service,
                                    opponentId: memberUid,
                                    opponentName:
                                        p['displayName'] as String? ?? 'Player',
                                  ),
                                  child: const Text('Challenge'),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  // Owner-only: pending join requests to approve/reject.
                  if (isOwner)
                    _PendingRequests(
                      service: service,
                      circleId: circleId,
                    ),
                  // Stake offers made to me (any member) — accept/decline.
                  _IncomingStakes(service: service),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: isOwner
                        ? OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete circle'),
                            onPressed: () async {
                              final ok = await _confirm(context,
                                  'Delete "$name"? This cannot be undone.');
                              if (!ok) return;
                              try {
                                await service.deleteCircle(circleId);
                                if (context.mounted) Navigator.of(context).pop();
                              } on FirebaseFunctionsException catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(e.message ?? 'Failed')));
                                }
                              }
                            },
                          )
                        : OutlinedButton.icon(
                            icon: const Icon(Icons.exit_to_app),
                            label: const Text('Leave circle'),
                            onPressed: () async {
                              final ok = await _confirm(
                                  context, 'Leave "$name"?');
                              if (!ok) return;
                              try {
                                await service.leaveCircle(circleId);
                                if (context.mounted) Navigator.of(context).pop();
                              } on FirebaseFunctionsException catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(e.message ?? 'Failed')));
                                }
                              }
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return result ?? false;
  }
}

// =============================================================================
// SLICE 4: Conquest — breach UI (challenger screen + defend banner)
// =============================================================================

class ChallengerCircleScreen extends StatefulWidget {
  final GameService service;
  final String circleId;
  final String circleName;
  const ChallengerCircleScreen({
    super.key,
    required this.service,
    required this.circleId,
    required this.circleName,
  });

  @override
  State<ChallengerCircleScreen> createState() => _ChallengerCircleScreenState();
}

class _ChallengerCircleScreenState extends State<ChallengerCircleScreen> {
  Map<String, dynamic>? _elig; // server eligibility result (authoritative)
  bool _loading = true;
  String? _loadError;
  bool _mounting = false; // breach call in flight

  @override
  void initState() {
    super.initState();
    _loadEligibility();
  }

  Future<void> _loadEligibility() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final e = await widget.service.getBreachEligibility(widget.circleId);
      if (mounted) {
        setState(() {
          _elig = e;
          _loading = false;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.message ?? 'Could not check eligibility.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _mountBreach() async {
    setState(() => _mounting = true);
    try {
      final conquestId =
          await widget.service.initiateBreach(widget.circleId);
      if (!mounted) return;
      // Breach mounted: pop back and confirm. (The challenger watches their
      // conquest via myBreachesStream; a dedicated conquest screen lands with
      // the Gauntlet commit.)
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Breach mounted on ${widget.circleName}. '
            'Waiting for a defender…')),
      );
      // conquestId intentionally unused for now (no conquest screen yet).
      // ignore: unused_local_variable
      final _ = conquestId;
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _mounting = false);
        // A lost race (e.g. circle_under_breach) lands here — re-check so the
        // button reflects the new reality instead of staying enabled.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Breach failed.')),
        );
        _loadEligibility();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Breach circle')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: widget.service.circleStream(widget.circleId),
        builder: (context, snap) {
          final data = snap.data?.data();
          if (snap.connectionState == ConnectionState.waiting &&
              data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (data == null) {
            return const Center(child: Text('This circle no longer exists.'));
          }
          final name = data['name'] as String? ?? widget.circleName;
          final members =
              (data['members'] as List?)?.cast<String>() ?? <String>[];

          // Authoritative numbers from getBreachEligibility once it returns.
          final e = _elig;
          final ownerRating = e?['ownerRating'] as int?;
          final serverStake = e?['estimatedStake'] as int?;
          final eligible = e?['eligible'] as bool? ?? false;
          final reason = e?['reason'] as String?;
          final cooldownDays = e?['cooldownDaysLeft'] as int?;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${members.length} member'
                  '${members.length == 1 ? '' : 's'}'
                  '${ownerRating != null ? '  ·  owner rating $ownerRating' : ''}',
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 20),

              // ---- Stake preview ----
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Breach stake',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      if (_loading)
                        const Text('Estimating…',
                            style: TextStyle(fontSize: 13))
                      else
                        Text(
                          serverStake != null
                              ? '$serverStake CP'
                              : 'Unavailable',
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      const SizedBox(height: 6),
                      const Text(
                        'You stake this to mount the breach. Win the defense '
                        'game and it is refunded; lose or draw and it goes to '
                        'the defender.',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ---- Prize / risk explainer ----
              const Text('How a breach works',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text(
                'Win one defense game to enter a best-of-3 Gauntlet for full '
                'membership. A draw counts as a loss — you must win. Lose or '
                'draw the defense and your stake goes to the defender.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 24),

              // ---- Breach button (eligibility-driven) ----
              if (_loadError != null) ...[
                Text(_loadError!,
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _loadEligibility,
                  child: const Text('Retry'),
                ),
              ] else
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.deepOrange),
                  icon: _mounting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.flag),
                  label: Text(_loading
                      ? 'Checking…'
                      : (eligible ? 'Breach this circle' : 'Cannot breach')),
                  onPressed: (_loading || _mounting || !eligible)
                      ? null
                      : () async {
                          final ok = await _confirmBreach(
                              context, name, serverStake);
                          if (ok) _mountBreach();
                        },
                ),
              if (!_loading && !eligible && reason != null) ...[
                const SizedBox(height: 10),
                Text(
                  _breachReasonText(reason, cooldownDays),
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<bool> _confirmBreach(
      BuildContext context, String name, int? stake) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Breach "$name"?'),
        content: Text(
          stake != null
              ? 'This locks $stake CP. Win the defense game to get it back and '
                'enter the Gauntlet; lose or draw and it goes to the defender.'
              : 'This locks your breach stake. Win the defense game to get it '
                'back; lose or draw and it goes to the defender.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Breach')),
        ],
      ),
    );
    return result ?? false;
  }
}

/// Friendly text for a getBreachEligibility `reason` code.
String _breachReasonText(String reason, int? cooldownDays) {
  switch (reason) {
    case 'own_circle':
      return 'You own this circle — you can\'t breach it.';
    case 'already_member':
      return 'You\'re already a member of this circle.';
    case 'active_conquest':
      return 'You already have an active conquest. Finish it first.';
    case 'circle_under_breach':
      return 'This circle is already under an active breach. Try again later.';
    case 'cooldown':
      return cooldownDays != null
          ? 'You breached this circle recently. Try again in $cooldownDays day'
              '${cooldownDays == 1 ? '' : 's'}.'
          : 'You breached this circle recently. Try again later.';
    case 'insufficient_cp':
      return 'You don\'t have enough CP to mount this breach.';
    default:
      return 'You can\'t breach this circle right now.';
  }
}

/// Shown inside CircleDetailScreen (member view) when the circle is under an
/// active breach: lets the FIRST member to tap Defend answer it. Navigates into
/// the breach game on success.
class _BreachDefendBanner extends StatelessWidget {
  final GameService service;
  final String circleId;
  const _BreachDefendBanner({
    required this.service,
    required this.circleId,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: service.openBreachesForCircleStream(circleId),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final conquest = docs.first;
        final conquestId = conquest.id;

        return Container(
          width: double.infinity,
          color: scheme.errorContainer,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.shield, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your circle is under breach. The first member to defend '
                  'plays the challenger.',
                  style: TextStyle(
                      color: scheme.onErrorContainer, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  try {
                    final gameId =
                        await service.acceptBreachDefense(conquestId);
                    if (context.mounted) {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            GameScreen(service: service, gameId: gameId),
                      ));
                    }
                  } on FirebaseFunctionsException catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(e.message ?? 'Failed')),
                      );
                    }
                  }
                },
                child: const Text('Defend'),
              ),
            ],
          ),
        );
      },
    );
  }
}



// =============================================================================
// SLICE 2d: Search circles + join requests
// =============================================================================

/// Search circles by name prefix and request to join.
class SearchCirclesScreen extends StatefulWidget {
  final GameService service;
  const SearchCirclesScreen({super.key, required this.service});
  @override
  State<SearchCirclesScreen> createState() => _SearchCirclesScreenState();
}

class _SearchCirclesScreenState extends State<SearchCirclesScreen> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _searched = false;

  Future<void> _runSearch() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final r = await widget.service.searchCircles(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Search failed: $e')));
      }
    } finally {
      if (mounted) setState(() {
        _searching = false;
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find a circle')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _runSearch(),
                    decoration: const InputDecoration(
                      hintText: 'Search circle name…',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _runSearch,
                  child: const Text('Search'),
                ),
              ],
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: !_searched
                ? const Center(
                    child: Text('Search for a circle by name to join.',
                        style: TextStyle(color: Colors.black54)),
                  )
                : _results.isEmpty
                    ? const Center(
                        child: Text('No circles found.',
                            style: TextStyle(color: Colors.black54)),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, i) {
                          final c = _results[i];
                          return _SearchResultTile(
                            service: widget.service,
                            circleId: c['circleId'] as String,
                            name: c['name'] as String? ?? 'Circle',
                            memberCount: (c['memberCount'] ?? 0) as int,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// A single search result with a Join / Pending / Member button that reflects
/// the user's live relationship to the circle.
class _SearchResultTile extends StatelessWidget {
  final GameService service;
  final String circleId;
  final String name;
  final int memberCount;
  const _SearchResultTile({
    required this.service,
    required this.circleId,
    required this.name,
    required this.memberCount,
  });

  @override
  Widget build(BuildContext context) {
    final myUid = service.uid;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: service.circleStream(circleId),
      builder: (context, circleSnap) {
        final members = (circleSnap.data?.data()?['members'] as List?)
                ?.cast<String>() ??
            <String>[];
        final isMember = members.contains(myUid);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: service.myJoinRequestStream(circleId),
          builder: (context, reqSnap) {
            final isPending = reqSnap.data?.exists ?? false;

            Widget trailing;
            if (isMember) {
              trailing = const Chip(label: Text('Member'));
            } else if (isPending) {
              trailing = OutlinedButton(
                onPressed: () async {
                  try {
                    await service.cancelJoinRequest(circleId);
                  } catch (_) {}
                },
                child: const Text('Pending'),
              );
            } else {
              trailing = FilledButton(
                onPressed: () async {
                  try {
                    await service.requestJoin(circleId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Request sent')));
                    }
                  } on FirebaseFunctionsException catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(e.message ?? 'Failed')));
                    }
                  }
                },
                child: const Text('Join'),
              );
            }

            return ListTile(
              leading: const Icon(Icons.groups),
              title: Text(name),
              subtitle: Text('$memberCount member'
                  '${memberCount == 1 ? '' : 's'}'),
              trailing: trailing,
              onTap: isMember
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ChallengerCircleScreen(
                          service: service,
                          circleId: circleId,
                          circleName: name,
                        ),
                      )),
            );
          },
        );
      },
    );
  }
}

/// Owner-only widget: lists pending join requests with Approve / Reject.
class _PendingRequests extends StatelessWidget {
  final GameService service;
  final String circleId;
  const _PendingRequests({required this.service, required this.circleId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: service.joinRequestsStream(circleId),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Pending requests (${docs.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.black87)),
            ),
            ...docs.map((d) {
              final r = d.data();
              final applicantUid = d.id;
              final rating = (r['rating'] ?? 1500).round();
              return ListTile(
                dense: true,
                leading: const Icon(Icons.person_add_alt),
                title: Text(r['displayName'] as String? ?? 'Player'),
                subtitle: Text('Rating $rating'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Approve',
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () async {
                        try {
                          await service.approveJoin(circleId, applicantUid);
                        } on FirebaseFunctionsException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message ?? 'Failed')));
                          }
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Reject',
                      icon: const Icon(Icons.close, color: Colors.red),
                      onPressed: () async {
                        try {
                          await service.rejectJoin(circleId, applicantUid);
                        } on FirebaseFunctionsException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message ?? 'Failed')));
                          }
                        }
                      },
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

/// Dialog to propose a peer stake to a circle-mate. Issuer enters an absolute
/// CP amount; the opponent will accept or decline. The 30%-cap and balance
/// checks happen server-side at accept time against live balances.
Future<void> _showStakeDialog(
  BuildContext context,
  GameService service, {
  required String opponentId,
  required String opponentName,
  required String circleId,
}) async {
  final controller = TextEditingController(text: '200');
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      String? error;
      bool busy = false;
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text('Stake vs $opponentName'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Both players stake this amount of CP. Winner takes the pot '
                  'minus a 5% rake. Minimum 50 CP.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Stake (CP)',
                    errorText: error,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        final amount = int.tryParse(controller.text.trim());
                        if (amount == null || amount < 50) {
                          setState(() => error = 'Enter at least 50 CP');
                          return;
                        }
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await service.proposeStake(
                            opponentId: opponentId,
                            circleId: circleId,
                            amount: amount,
                          );
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    'Stake offer sent to $opponentName')));
                          }
                        } on FirebaseFunctionsException catch (e) {
                          setState(() {
                            busy = false;
                            error = e.message ?? 'Failed';
                          });
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send offer'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Confirmation dialog to send a challenge-up. No amount entry — stakes are
/// computed server-side from the rating gap (CP = entry fee for a rating shot).
Future<void> _showChallengeDialog(
  BuildContext context,
  GameService service, {
  required String opponentId,
  required String opponentName,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      bool busy = false;
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text('Challenge $opponentName'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'A challenge-up is a shot at a big rating climb. The stake is '
                  'set by the rating gap — challenging a stronger player costs '
                  'more CP, but an upset win means a large rating jump plus the '
                  'pot. Both stakes are calculated when they accept.',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepOrange),
                onPressed: busy
                    ? null
                    : () async {
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await service.proposeChallengeUp(opponentId);
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content:
                                    Text('Challenge sent to $opponentName')));
                          }
                        } on FirebaseFunctionsException catch (e) {
                          setState(() {
                            busy = false;
                            error = e.message ?? 'Failed';
                          });
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send challenge'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Shows stake offers made TO the current user (they are the opponent), with
/// Accept / Decline. Accepting locks both stakes, creates the game, and
/// navigates into it.
class _IncomingStakes extends StatelessWidget {
  final GameService service;
  const _IncomingStakes({required this.service});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: service.incomingStakesStream(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Stake offers (${docs.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.indigo)),
            ),
            ...docs.map((d) {
              final s = d.data();
              final stakeId = d.id;
              final isChallenge = s['kind'] == 'challenge_up';
              final amount = (s['amount'] ?? 0) as int;
              return ListTile(
                dense: true,
                leading: Icon(
                  isChallenge ? Icons.bolt : Icons.toll,
                  color: isChallenge ? Colors.deepOrange : Colors.indigo,
                ),
                title: Text(isChallenge
                    ? 'Challenge-up'
                    : 'Stake $amount CP'),
                subtitle: Text(isChallenge
                    ? 'Stakes set by rating gap — tap ✓ to accept'
                    : 'Tap ✓ to accept and start the game'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Accept',
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () async {
                        try {
                          // Accept only — entry into the board is handled
                          // uniformly by the home screen's active-game
                          // listener (for both the accepter and the issuer),
                          // so we don't navigate here.
                          if (isChallenge) {
                            await service.acceptChallengeUp(stakeId);
                          } else {
                            await service.acceptStake(stakeId);
                          }
                          if (context.mounted) {
                            Navigator.of(context).popUntil(
                                (route) => route.isFirst);
                          }
                        } on FirebaseFunctionsException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message ?? 'Failed')));
                          }
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Decline',
                      icon: const Icon(Icons.close, color: Colors.red),
                      onPressed: () async {
                        try {
                          await service.declineStake(stakeId);
                        } on FirebaseFunctionsException catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.message ?? 'Failed')));
                          }
                        }
                      },
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
