import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// All backend contact lives here. The app sends INTENTS (callable
/// functions) and READS state (Firestore stream). It never writes
/// game state directly — the server owns truth.
class GameService {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _fns = FirebaseFunctions.instance;
  final _googleSignIn = GoogleSignIn();

  String? get uid => _auth.currentUser?.uid;
  User? get currentUser => _auth.currentUser;

  /// Stream of auth state — the app's auth gate listens to this to decide
  /// whether to show the sign-in screen or the home screen.
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  /// Sign in with Google. Returns the signed-in [User], or null if the user
  /// cancelled. Throws FirebaseAuthException on a real failure.
  ///
  /// Flow (classic google_sign_in 6.x + firebase_auth 4.x):
  ///   GoogleSignIn().signIn()  -> interactive account picker
  ///   account.authentication   -> idToken + accessToken
  ///   GoogleAuthProvider.credential(...) -> Firebase credential
  ///   _auth.signInWithCredential(...)    -> Firebase user
  Future<User?> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null; // user cancelled the picker

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final result = await _auth.signInWithCredential(credential);
    return result.user;
  }

  /// Sign out of both Firebase and Google (so the next sign-in re-prompts
  /// for account choice rather than silently reusing the last account).
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
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

  // ---- Slice 2c: circles ---------------------------------------------------

  /// Create a circle owned by the current user. Returns the new circle id.
  /// Throws FirebaseFunctionsException (e.g. 'failed-precondition' if the user
  /// already owns a circle).
  Future<String> createCircle(String name) async {
    final res = await _fns
        .httpsCallable('createCircle')
        .call(<String, dynamic>{'name': name});
    return res.data['circleId'] as String;
  }

  /// Leave a circle (owner cannot leave their own).
  Future<void> leaveCircle(String circleId) async {
    await _fns
        .httpsCallable('leaveCircle')
        .call(<String, dynamic>{'circleId': circleId});
  }

  /// Delete a circle (owner only).
  Future<void> deleteCircle(String circleId) async {
    await _fns
        .httpsCallable('deleteCircle')
        .call(<String, dynamic>{'circleId': circleId});
  }

  /// Live view of the current user's profile (rating, ownedCircleId, etc.).
  Stream<DocumentSnapshot<Map<String, dynamic>>> myProfileStream() {
    final id = uid;
    return _db.collection('users').doc(id).snapshots();
  }

  /// Live CP balance for the current user.
  ///
  /// CP uses a PURE LEDGER-SUM model: there is no stored balance field. The
  /// balance is the sum of all of this user's ledger entries (grants are
  /// positive, stakes negative, pot wins positive, etc.). We stream the user's
  /// own ledger entries (rules allow reading only your own) and sum them
  /// client-side, so the balance updates live as the server appends entries.
  ///
  /// The ledger is the single source of truth; this stream just adds it up.
  Stream<int> myCpBalanceStream() {
    final id = uid;
    if (id == null) return Stream<int>.value(0);
    return _db
        .collection('ledger')
        .where('account', isEqualTo: id)
        .snapshots()
        .map((snap) {
      var sum = 0;
      for (final doc in snap.docs) {
        final amount = doc.data()['amount'];
        if (amount is int) {
          sum += amount;
        } else if (amount is num) {
          sum += amount.toInt();
        }
      }
      return sum;
    });
  }

  /// Live view of a single circle document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> circleStream(String circleId) {
    return _db.collection('circles').doc(circleId).snapshots();
  }

  /// Live list of circles the current user is a member of.
  Stream<QuerySnapshot<Map<String, dynamic>>> myCirclesStream() {
    final id = uid;
    return _db
        .collection('circles')
        .where('members', arrayContains: id)
        .snapshots();
  }

  /// One-off fetch of multiple user profiles (e.g. to show a circle's member
  /// list with names + ratings for the crown). Firestore 'in' queries are
  /// capped at 10 ids per call, so we batch.
  Future<List<Map<String, dynamic>>> fetchProfiles(List<String> uids) async {
    final results = <Map<String, dynamic>>[];
    for (var i = 0; i < uids.length; i += 10) {
      final batch = uids.sublist(i, i + 10 > uids.length ? uids.length : i + 10);
      if (batch.isEmpty) continue;
      final snap = await _db
          .collection('users')
          .where(FieldPath.documentId, whereIn: batch)
          .get();
      for (final doc in snap.docs) {
        results.add({'uid': doc.id, ...doc.data()});
      }
    }
    return results;
  }

  // ---- Slice 2d: search + join + owner approval ----------------------------

  /// Search circles by name prefix (case-insensitive). Firestore has no
  /// full-text search, so this is a prefix range query on a lowercased name
  /// field: matches circles whose name starts with [query].
  Future<List<Map<String, dynamic>>> searchCircles(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    // Prefix range trick: names in [q, q + '\uf8ff') all start with q.
    final snap = await _db
        .collection('circles')
        .where('nameLower', isGreaterThanOrEqualTo: q)
        .where('nameLower', isLessThan: '$q\uf8ff')
        .limit(20)
        .get();
    return snap.docs.map((d) => {'circleId': d.id, ...d.data()}).toList();
  }

  /// Request to join a circle (creates a pending request for the owner).
  Future<void> requestJoin(String circleId) async {
    await _fns
        .httpsCallable('requestJoin')
        .call(<String, dynamic>{'circleId': circleId});
  }

  /// Cancel your own pending join request.
  Future<void> cancelJoinRequest(String circleId) async {
    await _fns
        .httpsCallable('cancelJoinRequest')
        .call(<String, dynamic>{'circleId': circleId});
  }

  /// Owner: approve a pending join request.
  Future<void> approveJoin(String circleId, String applicantUid) async {
    await _fns.httpsCallable('approveJoin').call(<String, dynamic>{
      'circleId': circleId,
      'applicantUid': applicantUid,
    });
  }

  /// Owner: reject a pending join request.
  Future<void> rejectJoin(String circleId, String applicantUid) async {
    await _fns.httpsCallable('rejectJoin').call(<String, dynamic>{
      'circleId': circleId,
      'applicantUid': applicantUid,
    });
  }

  /// Live list of pending join requests for a circle (owner view).
  Stream<QuerySnapshot<Map<String, dynamic>>> joinRequestsStream(
      String circleId) {
    return _db
        .collection('circles')
        .doc(circleId)
        .collection('joinRequests')
        .snapshots();
  }

  /// Live view of the current user's own join request on a circle (to show
  /// "pending" state on the search result). Returns null doc if none.
  Stream<DocumentSnapshot<Map<String, dynamic>>> myJoinRequestStream(
      String circleId) {
    final id = uid;
    return _db
        .collection('circles')
        .doc(circleId)
        .collection('joinRequests')
        .doc(id)
        .snapshots();
  }

  // ---- Slice 3c: peer staking ----------------------------------------------

  /// Propose a peer stake to a circle-mate. [amount] is absolute CP (both
  /// sides stake this). No CP moves until the opponent accepts.
  Future<String> proposeStake({
    required String opponentId,
    required String circleId,
    required int amount,
  }) async {
    final res = await _fns.httpsCallable('proposeStake').call(<String, dynamic>{
      'opponentId': opponentId,
      'circleId': circleId,
      'amount': amount,
    });
    return res.data['stakeId'] as String;
  }

  /// Accept a pending stake offer. Locks both stakes and creates the game;
  /// returns the new gameId so the caller can navigate into it.
  Future<String> acceptStake(String stakeId) async {
    final res = await _fns
        .httpsCallable('acceptStake')
        .call(<String, dynamic>{'stakeId': stakeId});
    return res.data['gameId'] as String;
  }

  /// Issuer cancels their own pending offer.
  Future<void> cancelStake(String stakeId) async {
    await _fns
        .httpsCallable('cancelStake')
        .call(<String, dynamic>{'stakeId': stakeId});
  }

  /// Opponent declines a pending offer.
  Future<void> declineStake(String stakeId) async {
    await _fns
        .httpsCallable('declineStake')
        .call(<String, dynamic>{'stakeId': stakeId});
  }

  /// Pending stake offers made TO me (I'm the opponent) — to accept/decline.
  Stream<QuerySnapshot<Map<String, dynamic>>> incomingStakesStream() {
    final id = uid;
    return _db
        .collection('stakes')
        .where('opponentId', isEqualTo: id)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Pending stake offers I made (I'm the issuer) — to cancel / await.
  Stream<QuerySnapshot<Map<String, dynamic>>> outgoingStakesStream() {
    final id = uid;
    return _db
        .collection('stakes')
        .where('issuerId', isEqualTo: id)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  /// Live list of the current user's ACTIVE games (in progress). Used to show
  /// a "Resume game" entry on the home screen — needed because a staked game
  /// is created server-side when the opponent accepts, so the issuer has no
  /// other way back into the board.
  Stream<QuerySnapshot<Map<String, dynamic>>> activeGamesStream() {
    final id = uid;
    return _db
        .collection('games')
        .where('players', arrayContains: id)
        .where('status', isEqualTo: 'active')
        .snapshots();
  }

  // ---- Slice 3d: challenge-up (outside / asymmetric staking) ----------------

  /// Propose a challenge-up against another player. Stakes are asymmetric and
  /// computed at accept from the rating gap. CP is the entry fee for a shot at
  /// a rating climb (the underdog stakes more, for the bigger rating upside).
  Future<String> proposeChallengeUp(String opponentId) async {
    final res = await _fns
        .httpsCallable('proposeChallengeUp')
        .call(<String, dynamic>{'opponentId': opponentId});
    return res.data['stakeId'] as String;
  }

  /// Accept a challenge-up offer. Locks both asymmetric stakes and creates the
  /// game; returns the gameId.
  Future<String> acceptChallengeUp(String stakeId) async {
    final res = await _fns
        .httpsCallable('acceptChallengeUp')
        .call(<String, dynamic>{'stakeId': stakeId});
    return res.data['gameId'] as String;
  }
}
