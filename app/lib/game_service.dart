import 'dart:math' as math;

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

  /// TEST-ONLY sign-in (email/password) for development against the Firebase
  /// Auth EMULATOR. The emulator accepts any email/password; if the account
  /// doesn't exist yet it's created, otherwise it signs in. This avoids the
  /// real-Google-token-to-emulator handoff that fails on physical devices.
  /// Not used in production (production uses Google sign-in).
  Future<User?> signInWithTestEmail(String email, String password) async {
    try {
      final result =
          await _auth.signInWithEmailAndPassword(email: email, password: password);
      return result.user;
    } on FirebaseAuthException catch (e) {
      // First time for this email → create it, then we're signed in.
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        final created = await _auth.createUserWithEmailAndPassword(
            email: email, password: password);
        return created.user;
      }
      rethrow;
    }
  }

  /// Sign out of both Firebase and Google (so the next sign-in re-prompts
  /// for account choice rather than silently reusing the last account).
  Future<void> signOut() async {
    // Each step is guarded: a stale/invalid token can make one throw, and we
    // still want the rest to run so local auth state is fully cleared.
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  /// True if an error is the stale-refresh-token / unauthenticated signature
  /// that appears after the emulator is restarted (its auth users are wiped,
  /// so the app's cached token is a ghost). When this happens the SDK spins in
  /// a retry loop; callers should force a clean sign-out so the user can
  /// re-authenticate instead of hanging.
  bool isStaleAuthError(Object error) {
    final s = error.toString();
    return s.contains('INVALID_REFRESH_TOKEN') ||
        s.contains('UNAUTHENTICATED') ||
        s.contains('user-token-expired') ||
        s.contains('user-disabled') ||
        s.contains('user-not-found');
  }

  /// Force a clean sign-out in response to a stale-token error, so the auth
  /// stream emits null and the app routes back to the sign-in screen (instead
  /// of looping on an unusable token).
  Future<void> recoverFromStaleAuth() async {
    await signOut();
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

  /// Ready-gate: signal that this player has arrived at the board of a
  /// PRE-SEATED staked/conquest game (peer / challenge_up / breach / gauntlet).
  /// The game stays `waiting` (clock frozen) until BOTH assigned players have
  /// called this; then it activates and the clock starts. Idempotent — safe to
  /// call repeatedly. Returns {status, started}. The client calls this when the
  /// GameScreen of a `waiting` staked game opens; readying is sticky, so the
  /// player may then leave freely (a waiting game never blocks other play).
  Future<Map<String, dynamic>> markReady(String gameId) async {
    final res = await _fns
        .httpsCallable('markReady')
        .call(<String, dynamic>{'gameId': gameId});
    return Map<String, dynamic>.from(res.data as Map);
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

  /// One-time fetch of a game document (e.g. to check who its players are
  /// before offering to enter it).
  Future<DocumentSnapshot<Map<String, dynamic>>> gameOnce(String gameId) {
    return _db.collection('games').doc(gameId).get();
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
  /// Reads the denormalized `cp` field on the user's profile doc — an O(1)
  /// read maintained transactionally by the server on every CP movement (the
  /// ledger remains the source of truth; `cp` is a read cache). This replaces
  /// the old approach of streaming and summing every ledger entry, which grew
  /// unbounded with a player's history. Falls back to 0 only until the field
  /// exists (a freshly created profile initializes cp before the grant lands).
  Stream<int> myCpBalanceStream() {
    final id = uid;
    if (id == null) return Stream<int>.value(0);
    return _db.collection('users').doc(id).snapshots().map((snap) {
      final v = snap.data()?['cp'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
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

  /// Ready-gate: games where I'm a player and the game is still `waiting` for
  /// both players to arrive (markReady). The HomeScreen/global banner watches
  /// this to offer an "Enter game" path INTO the waiting game (opening it
  /// triggers markReady).
  ///
  /// NOTE: queries ONLY by `players arrayContains me` (a single-field index
  /// that Firestore provides automatically) and filters `status == 'waiting'`
  /// in Dart. Combining arrayContains with a second `where` would require a
  /// COMPOSITE index, which fails silently in the emulator if absent — so we
  /// filter client-side instead. Returns the raw docs; callers filter.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      waitingGamesStream() {
    final id = uid;
    return _db
        .collection('games')
        .where('players', arrayContains: id)
        .snapshots()
        .map((snap) => snap.docs
            .where((d) => (d.data()['status'] as String?) == 'waiting')
            .toList());
  }

  /// In-app notifications addressed to me, newest first. Drives the global bell
  /// + notification center. Query is on recipientId only (single field — no
  /// composite index); we sort client-side to avoid an index requirement.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      notificationsStream() {
    final id = uid;
    return _db
        .collection('notifications')
        .where('recipientId', isEqualTo: id)
        .snapshots()
        .map((snap) {
      final docs = snap.docs.toList();
      docs.sort((a, b) {
        final ta = a.data()['createdAt'];
        final tb = b.data()['createdAt'];
        final va = ta is Timestamp ? ta.millisecondsSinceEpoch : 0;
        final vb = tb is Timestamp ? tb.millisecondsSinceEpoch : 0;
        return vb.compareTo(va); // newest first
      });
      return docs;
    });
  }

  /// Mark a single notification read (clears it from the unread badge count).
  Future<void> markNotificationRead(String notifId) async {
    final id = uid;
    if (id == null) return;
    await _db
        .collection('notifications')
        .doc(notifId)
        .update({'read': true});
  }

  /// Dismiss (delete) a notification — the × button on an informational item.
  Future<void> dismissNotification(String notifId) async {
    await _db.collection('notifications').doc(notifId).delete();
  }

  /// Mark all my unread notifications read (e.g. when the center is opened).
  Future<void> markAllNotificationsRead() async {
    final id = uid;
    if (id == null) return;
    // Single-field query (recipientId only — no composite index); filter unread
    // in Dart.
    final snap = await _db
        .collection('notifications')
        .where('recipientId', isEqualTo: id)
        .get();
    final batch = _db.batch();
    for (final d in snap.docs) {
      if (d.data()['read'] == true) continue;
      batch.update(d.reference, {'read': true});
    }
    await batch.commit();
  }

  // ---- Slice 3d: challenge-up (outside / asymmetric staking) ----------------

  /// Propose a challenge-up against another player. Stakes are asymmetric and
  /// computed at accept from the rating gap. CP is the entry fee for a shot at
  /// a rating climb (the underdog stakes more, for the bigger rating upside).
  Future<String> proposeChallengeUp(String opponentId,
      {String? circleId}) async {
    final res = await _fns.httpsCallable('proposeChallengeUp').call(
        <String, dynamic>{
          'opponentId': opponentId,
          if (circleId != null) 'circleId': circleId,
        });
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

  // ---- Slice 4: conquest (breach half) -------------------------------------

  /// Mount a breach against a circle you don't belong to. Locks your breach
  /// stake (challenge-up formula vs the circle owner's rating, 40% cap) and
  /// creates a conquest in `breach_pending`. Returns the new conquestId.
  ///
  /// Throws FirebaseFunctionsException with 'failed-precondition' for: breaching
  /// your own circle, a circle you're already in, having another active
  /// conquest, the circle already under an active breach, the weekly cooldown
  /// still active, or insufficient CP.
  Future<String> initiateBreach(String circleId) async {
    final res = await _fns
        .httpsCallable('initiateBreach')
        .call(<String, dynamic>{'circleId': circleId});
    return res.data['conquestId'] as String;
  }

  /// Defend a breach as the FIRST circle member to accept (first-come). Creates
  /// the breach game and returns its gameId so the caller can navigate into it.
  /// The defender stakes nothing.
  ///
  /// Throws 'failed-precondition' if the breach is no longer open / already
  /// being defended, or 'permission-denied' if you're not a circle member.
  Future<String> acceptBreachDefense(String conquestId) async {
    final res = await _fns
        .httpsCallable('acceptBreachDefense')
        .call(<String, dynamic>{'conquestId': conquestId});
    return res.data['gameId'] as String;
  }

  /// Live view of a single conquest document (status machine, breach/Gauntlet
  /// state). Used to drive the conquest screen as it advances.
  Stream<DocumentSnapshot<Map<String, dynamic>>> conquestStream(
      String conquestId) {
    return _db.collection('conquests').doc(conquestId).snapshots();
  }

  /// Breaches I have mounted as the challenger (any status) — to track my own
  /// active/finished conquests.
  Stream<QuerySnapshot<Map<String, dynamic>>> myBreachesStream() {
    final id = uid;
    return _db
        .collection('conquests')
        .where('challengerId', isEqualTo: id)
        .snapshots();
  }

  /// Breaches currently OPEN for defense on a given circle (status
  /// 'breach_pending'). A circle member watches this to see an incoming breach
  /// they can answer. Scoped to one circle so the rules' membership read passes.
  Stream<QuerySnapshot<Map<String, dynamic>>> openBreachesForCircleStream(
      String circleId) {
    return _db
        .collection('conquests')
        .where('circleId', isEqualTo: circleId)
        .where('status', isEqualTo: 'breach_pending')
        .snapshots();
  }

  /// Authoritative, read-only check: can I breach this circle right now, and
  /// what would it cost? Mirrors the server-side gates of initiateBreach but
  /// mutates nothing. Returns the raw map from the function:
  ///   eligible: bool
  ///   reason: String?   (own_circle | already_member | active_conquest |
  ///                       circle_under_breach | cooldown | insufficient_cp)
  ///   cooldownDaysLeft: int?
  ///   estimatedStake: int
  ///   ownerRating, myRating, myBalance: int
  ///
  /// Best-effort: eligibility can pass here and initiateBreach still fail if
  /// state changes in the gap — callers must catch that.
  Future<Map<String, dynamic>> getBreachEligibility(String circleId) async {
    final res = await _fns
        .httpsCallable('getBreachEligibility')
        .call(<String, dynamic>{'circleId': circleId});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Client-side preview of the breach stake (display only — the server is
  /// authoritative at initiateBreach). A pure Dart port of challengeStakeAmount
  /// (challenge.ts): the challenge-up fraction of [myBalance], scaled by the
  /// rating gap vs the circle owner, clamped at the 40% cap, floored to an int.
  ///
  /// Lets the challenger screen show an instant "~X CP" estimate before the
  /// getBreachEligibility round-trip returns the authoritative number.
  static int estimateBreachStake({
    required int myRating,
    required int ownerRating,
    required int myBalance,
  }) {
    const baseFraction = 0.05;
    const spread = 0.35;
    const maxFraction = 0.40; // raised 0.30 -> 0.40 (matches challenge.ts)
    // Elo expected score for the challenger vs the owner.
    final exp = 1 / (1 + math.pow(10, (ownerRating - myRating) / 400));
    final frac = baseFraction + (1 - exp) * spread;
    final capped = frac < maxFraction ? frac : maxFraction;
    return (myBalance * capped).floor();
  }

  // ---- Slice 4: Gauntlet (commit 2) ----------------------------------------

  /// Owner nominates the Gauntlet defender for a conquest at `gauntlet_pending`.
  /// Locks the defender's first per-game stake, creates Gauntlet game 1, and
  /// flips the conquest to `gauntlet_active`. Returns the new gameId.
  ///
  /// Throws 'permission-denied' if not the owner, 'failed-precondition' if the
  /// nominee isn't a member or the conquest isn't awaiting nomination.
  Future<String> nominateGauntletDefender({
    required String conquestId,
    required String defenderId,
  }) async {
    final res = await _fns.httpsCallable('nominateGauntletDefender').call(
      <String, dynamic>{'conquestId': conquestId, 'defenderId': defenderId},
    );
    return res.data['gameId'] as String;
  }

  /// Conquests on a given circle that are awaiting the owner's Gauntlet
  /// nomination (status 'gauntlet_pending'). The owner watches this to know a
  /// breach was survived and a champion must be nominated. Scoped to one circle
  /// so the rules' membership read passes.
  Stream<QuerySnapshot<Map<String, dynamic>>> gauntletPendingForCircleStream(
      String circleId) {
    return _db
        .collection('conquests')
        .where('circleId', isEqualTo: circleId)
        .where('status', isEqualTo: 'gauntlet_pending')
        .snapshots();
  }

  /// Live view of conquests on a circle that are in the Gauntlet (status
  /// 'gauntlet_active') — to show series progress (X–Y, current game).
  Stream<QuerySnapshot<Map<String, dynamic>>> activeGauntletForCircleStream(
      String circleId) {
    return _db
        .collection('conquests')
        .where('circleId', isEqualTo: circleId)
        .where('status', isEqualTo: 'gauntlet_active')
        .snapshots();
  }
}
