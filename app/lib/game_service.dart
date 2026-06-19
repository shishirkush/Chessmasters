import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// All backend contact lives here. The app sends INTENTS (callable
/// functions) and READS state (Firestore stream). It never writes
/// game state directly — the server owns truth.
class GameService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _fns = FirebaseFunctions.instance;

  String? get uid => _auth.currentUser?.uid;

  /// Anonymous sign-in is enough for slice 1. Real accounts come later.
  Future<void> ensureSignedIn() async {
    if (_auth.currentUser == null) {
      await _auth.signInAnonymously();
    }
  }

  /// Quick match: join any open game, or create one and wait.
  Future<String> quickMatch() async {
    final res = await _fns.httpsCallable('joinGame').call(<String, dynamic>{});
    return res.data['gameId'] as String;
  }

  /// Create a specific open game (used later for invites/private games).
  Future<String> createGame() async {
    final res = await _fns.httpsCallable('createGame').call();
    return res.data['gameId'] as String;
  }

  /// Join a specific game by id.
  Future<String> joinGame(String gameId) async {
    final res = await _fns
        .httpsCallable('joinGame')
        .call(<String, dynamic>{'gameId': gameId});
    return res.data['gameId'] as String;
  }

  /// Send a move intent. The server validates legality and turn order;
  /// it throws (FirebaseFunctionsException) if the move is rejected.
  Future<void> makeMove({
    required String gameId,
    required String from,
    required String to,
    String? promotion,
  }) async {
    await _fns.httpsCallable('makeMove').call(<String, dynamic>{
      'gameId': gameId,
      'from': from,
      'to': to,
      if (promotion != null) 'promotion': promotion,
    });
  }

  Future<void> resign(String gameId) async {
    await _fns
        .httpsCallable('resign')
        .call(<String, dynamic>{'gameId': gameId});
  }

  /// Ask the server to check whether the player-to-move has flagged (run out
  /// of time) or abandoned (idle past the 90s window). The SERVER decides from
  /// its own clock — this is just a prompt. A waiting opponent calls this to
  /// resolve a stalled/disconnected game. Never report client time.
  Future<Map<String, dynamic>> claimTimeout(String gameId) async {
    final res = await _fns
        .httpsCallable('claimTimeout')
        .call(<String, dynamic>{'gameId': gameId});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Live view of the canonical game document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> gameStream(String gameId) {
    return _db.collection('games').doc(gameId).snapshots();
  }
}
