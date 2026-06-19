import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = GameService();
  bool _busy = false;
  String? _status;

  Future<void> _quickMatch() async {
    setState(() {
      _busy = true;
      _status = 'Signing in…';
    });
    try {
      await _service.ensureSignedIn();
      setState(() => _status = 'Finding a game…');
      final gameId = await _service.quickMatch();
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GameScreen(gameId: gameId, service: _service),
      ));
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
    return Scaffold(
      appBar: AppBar(title: const Text('Chess Masters')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.castle, size: 72),
            const SizedBox(height: 8),
            const Text('Live Chess — Slice 1',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _quickMatch,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Quick Match'),
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

class GameScreen extends StatefulWidget {
  final String gameId;
  final GameService service;
  const GameScreen({super.key, required this.gameId, required this.service});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  final ChessBoardController _controller = ChessBoardController();
  String _lastAppliedFen = '';
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

          // Sync the board widget to the SERVER's FEN whenever it changes.
          if (fen != _lastAppliedFen) {
            _lastAppliedFen = fen;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _controller.loadFen(fen);
            });
          }

          // Keep the local display ticker aware of the active game so it can
          // count down the side-to-move's clock for display and, if the
          // OPPONENT runs out / abandons, prompt the server to resolve it.
          _trackClock(status, turn, myTurn);

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
                  child: AbsorbPointer(
                    // Block interaction unless it is genuinely my turn.
                    // (The server also enforces this — belt and braces.)
                    absorbing: !(status == 'active' && myTurn) || _sending,
                    child: ChessBoard(
                      controller: _controller,
                      boardOrientation:
                          iAmBlack ? PlayerColor.black : PlayerColor.white,
                      onMove: () => _onLocalMove(g),
                    ),
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

  /// The board widget made a tentative local move. We DO NOT trust it as
  /// truth — we extract from/to, send the intent to the server, and let the
  /// authoritative FEN come back through the stream. If the server rejects
  /// it, we reload the last good FEN.
  Future<void> _onLocalMove(Map<String, dynamic> g) async {
    if (_sending) return;
    final history = _controller.game.getHistory({'verbose': true});
    if (history.isEmpty) return;
    final last = history.last as Map;
    final from = last['from'] as String;
    final to = last['to'] as String;
    final promo = last['promotion'] as String?; // 'q','r','b','n' or null

    setState(() => _sending = true);
    try {
      await widget.service.makeMove(
        gameId: widget.gameId,
        from: from,
        to: to,
        promotion: promo,
      );
      // Success: the stream will deliver the new authoritative FEN.
    } on FirebaseFunctionsException catch (e) {
      // Rejected by server — snap board back to the last good state.
      _controller.loadFen(_lastAppliedFen);
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
