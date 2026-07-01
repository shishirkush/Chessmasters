import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:simple_chess_board/simple_chess_board.dart';

import 'game_service.dart';
import 'fcm_messaging.dart';

// Toggle this to true while testing against the local Firebase emulators.
const bool kUseEmulator = false;

// Host the app uses to reach the Firebase emulators.
//   - Android EMULATOR  → '10.0.2.2'   (special alias for the host machine)
//   - Real Android PHONE → your computer's LAN IP, e.g. '192.168.1.42'
//     (phone and computer must be on the SAME Wi-Fi; the emulator must be
//      started bound to 0.0.0.0 — see firebase.json — and Windows Firewall
//      must allow inbound on ports 8080/9099/5001.)
// Change this ONE line to switch between emulator and phone testing.
const String kEmulatorHost = '192.168.18.99'; // ← set to your LAN IP for phones

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // uses google-services.json on Android

  if (kUseEmulator) {
    FirebaseFirestore.instance.useFirestoreEmulator(kEmulatorHost, 8080);
    FirebaseFunctions.instance.useFunctionsEmulator(kEmulatorHost, 5001);
    await FirebaseAuth.instance.useAuthEmulator(kEmulatorHost, 9099);
  }

  // FCM background/terminated message handler. Must be registered before
  // runApp and must reference a top-level function. (Note: FCM has no emulator
  // and is not affected by kUseEmulator — pushes always go through real
  // Firebase / Google Play Services on the device.)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  runApp(const ChessMastersApp());
}

/// Global navigator key so the app-wide waiting-game banner can push the
/// GameScreen from above any screen.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

/// True whenever a game board (GameScreen) is the top-most route. Driven by a
/// NavigatorObserver below — push/pop are guaranteed paired by the framework, so
/// unlike a hand-maintained initState/dispose counter this can NEVER desync and
/// leave the bell/banner wrongly hidden. Replaces the old `gameScreensOpen`
/// integer counter that kept leaking.
final ValueNotifier<bool> gameRouteOnTop = ValueNotifier<bool>(false);

/// Observes route changes on the root navigator and flips `gameRouteOnTop` when
/// a GameScreen is pushed/popped. Any route whose settings.name is 'game' (or
/// whose widget is a GameScreen) counts. We recompute from the live stack on
/// every transition rather than incrementing, so it's always exactly correct.
class _GameRouteObserver extends NavigatorObserver {
  void _recompute() {
    // Defer to post-frame: navigator notifies observers mid-transition, and we
    // must not mutate a ValueNotifier that global widgets listen to during their
    // build. Post-frame is safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gameRouteOnTop.value = _topIsGame;
    });
  }

  bool _topIsGame = false;
  void _set(Route<dynamic>? top) {
    _topIsGame = top?.settings.name == 'game';
    _recompute();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _set(newRoute);
}

final _GameRouteObserver gameRouteObserver = _GameRouteObserver();

/// A single shared GameService for the whole app (so the global banner and the
/// screens read the same auth/uid).
final GameService rootService = GameService();

class ChessMastersApp extends StatelessWidget {
  const ChessMastersApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chess Masters',
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [gameRouteObserver],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B5B92),
      ),
      // Overlay a global "you have a game waiting" banner ABOVE every screen,
      // so a player learns about a waiting staked/conquest game no matter which
      // screen they're on (not just HomeScreen). The banner is tappable and
      // never blocks the screen beneath it; it hides itself when there's no
      // waiting game or when the player is already on a game board.
      builder: (context, child) {
        return _GlobalWaitingOverlay(child: child ?? const SizedBox.shrink());
      },
      home: const AuthGate(),
    );
  }
}

/// Pins the global waiting-game banner at the top of the screen, above the
/// current route. Watches the signed-in player's waiting games; renders nothing
/// when there are none. Tapping "Enter" navigates into the game via the root
/// navigator (which triggers markReady on the GameScreen).
class _GlobalWaitingOverlay extends StatelessWidget {
  final Widget child;
  const _GlobalWaitingOverlay({required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        // Waiting-game banner across the top.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: _GlobalWaitingBanner(service: rootService),
          ),
        ),
        // Notification bell, floating BOTTOM-right (clear of every AppBar's
        // actions, so it can never cover the game screen's Resign button). It
        // also hides entirely while a game board is open.
        Positioned(
          bottom: 16,
          right: 12,
          child: SafeArea(
            top: false,
            child: _GlobalNotificationBell(service: rootService),
          ),
        ),
      ],
    );
  }
}

/// A floating bell (top-right, on every screen) with an unread badge. Tapping
/// opens the notification center. Hidden while a game board is open and when
/// signed out.
class _GlobalNotificationBell extends StatefulWidget {
  final GameService service;
  const _GlobalNotificationBell({required this.service});

  @override
  State<_GlobalNotificationBell> createState() =>
      _GlobalNotificationBellState();
}

class _GlobalNotificationBellState extends State<_GlobalNotificationBell> {
  // Cache the stream per signed-in user. Creating service.notificationsStream()
  // inside build() spawns a new Firestore listener on every rebuild; with this
  // widget rebuilding on every route change, listeners pile up until the
  // emulator throttles the connection (too_many_pings) and drops OTHER streams
  // (which starved the waiting-game banner). So we cache — but we must (re)build
  // the stream when the user changes, because this widget mounts ABOVE auth (in
  // MaterialApp.builder) and first runs initState BEFORE anyone is signed in.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _stream;
  String? _streamUid;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _syncStream();
    // Rebuild the cached stream whenever auth changes (sign-in/out). This is the
    // key fix: at first build no one is signed in, so we can't create the stream
    // yet — we create it the moment a user appears.
    _authSub = widget.service.authStateChanges().listen((_) {
      if (mounted) setState(_syncStream);
    });
  }

  void _syncStream() {
    final uid = widget.service.uid;
    if (uid != _streamUid) {
      _streamUid = uid;
      _stream = uid == null ? null : widget.service.notificationsStream();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.service.uid;
    if (uid == null || _stream == null) return const SizedBox.shrink();
    final service = widget.service;
    // The bell is visible on every screen EXCEPT an open game board. It uses
    // gameRouteOnTop, driven by a NavigatorObserver (push/pop are framework-
    // paired, so it never desyncs). Everywhere off the board the bell is ALWAYS
    // present (even with zero notifications); only the red BADGE is conditional.
    return ValueListenableBuilder<bool>(
      valueListenable: gameRouteOnTop,
      builder: (context, onBoard, _) {
        if (onBoard) return const SizedBox.shrink();
        return StreamBuilder<
            List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          stream: _stream,
          builder: (context, snap) {
            final docs = snap.data ?? const [];
            final unread =
                docs.where((d) => d.data()['read'] != true).length;
            final scheme = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.only(top: 4, right: 2),
              child: Material(
                color: scheme.surface,
                shape: const CircleBorder(),
                elevation: 2,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _openCenter(context, service),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(Icons.notifications,
                            color: scheme.onSurface, size: 24),
                        if (unread > 0)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: scheme.error,
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                  minWidth: 18, minHeight: 18),
                              child: Text(
                                unread > 9 ? '9+' : '$unread',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: scheme.onError,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openCenter(BuildContext context, GameService service) {
    // Mark all read when the center opens (clears the badge); items remain
    // visible until dismissed.
    service.markAllNotificationsRead();
    // Use the ROOT navigator's context to host the sheet. The bell lives inside
    // MaterialApp.builder, which is ABOVE the Navigator — using that local
    // context, showModalBottomSheet can't find a Navigator and silently does
    // nothing. The root navigator context is the correct host.
    final navContext = rootNavigatorKey.currentContext ?? context;
    showModalBottomSheet<void>(
      context: navContext,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NotificationCenter(service: service),
    );
  }
}

/// The notification center: a scrollable list of the user's notifications,
/// each tappable to navigate to the relevant page and dismissible with ×.
class _NotificationCenter extends StatelessWidget {
  final GameService service;
  const _NotificationCenter({required this.service});

  IconData _iconFor(String type) {
    switch (type) {
      case 'join_request':
        return Icons.person_add;
      case 'join_approved':
        return Icons.check_circle;
      case 'join_rejected':
        return Icons.cancel;
      case 'stake_offer':
      case 'challenge_up':
        return Icons.sports_kabaddi;
      case 'stake_accepted':
        return Icons.handshake;
      case 'breach_initiated':
        return Icons.shield;
      case 'breach_won':
        return Icons.emoji_events;
      case 'breach_lost':
        return Icons.heart_broken;
      case 'member_left':
        return Icons.person_remove;
      case 'gauntlet_nominated':
        return Icons.military_tech;
      case 'game_ready':
      case 'game_activated':
        return Icons.sports_esports;
      case 'forfeit':
      case 'expired':
        return Icons.timer_off;
      default:
        return Icons.notifications;
    }
  }

  Future<void> _onTap(BuildContext context, GameService service,
      String notifId, Map<String, dynamic> data, String type) async {
    final gameId = data['gameId'] as String?;
    final isGameType = type == 'game_ready' ||
        type == 'game_activated' ||
        type == 'stake_accepted';

    // For game notifications, check the game's CURRENT status before navigating.
    // If the game is already finished (resigned/abandoned/decided), the
    // notification is stale: delete it and DON'T route to a dead board. If it's
    // still live/waiting, navigate AND delete the notification (it's consumed).
    if (isGameType && gameId != null) {
      bool finished = false;
      try {
        final snap = await service.gameOnce(gameId);
        final status = snap.data()?['status'] as String?;
        finished = status == 'finished';
      } catch (_) {
        // If we can't read it, treat as stale to be safe (don't dead-end).
        finished = true;
      }
      // Consumed either way → remove it.
      await service.dismissNotification(notifId);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close the sheet
      if (finished) {
        // Stale: tell the user instead of routing to a dead board.
        final messenger = ScaffoldMessenger.maybeOf(
            rootNavigatorKey.currentContext ?? context);
        messenger?.showSnackBar(
          const SnackBar(content: Text('That game has already ended.')),
        );
        return;
      }
      // Live/waiting → open the board (deferred so it runs after the pop).
      Future.microtask(() {
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'game'),
            builder: (_) => GameScreen(gameId: gameId, service: service),
          ),
        );
      });
      return;
    }

    // Offer / circle-action notifications → open the relevant Circle page,
    // where the Accept / Approve / Defend controls live. These carry a circleId
    // in their data. (challenge_up is outside-circle and has no circleId; if
    // absent we fall through to informational.)
    final circleId = data['circleId'] as String?;
    final isCircleAction = type == 'stake_offer' ||
        type == 'challenge_up' ||
        type == 'join_request' ||
        type == 'join_approved' ||
        type == 'breach_initiated' ||
        type == 'member_left' ||
        type == 'gauntlet_nominated';
    if (isCircleAction && circleId != null) {
      // Don't delete these — the action (accept/approve) still needs to be
      // taken on the circle page; mark read so the badge clears.
      await service.markNotificationRead(notifId);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close the sheet
      Future.microtask(() {
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) =>
                CircleDetailScreen(service: service, circleId: circleId),
          ),
        );
      });
      return;
    }

    // Everything else (informational, or challenge_up with no circle) just
    // closes the sheet. The notification stays until dismissed with ×.
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Notifications',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<
                  List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                stream: service.notificationsStream(),
                builder: (context, snap) {
                  final docs = snap.data ?? const [];
                  if (docs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Text('No notifications',
                            style: TextStyle(color: scheme.outline)),
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: scrollController,
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final d = docs[i];
                      final n = d.data();
                      final type = n['type'] as String? ?? '';
                      final data =
                          (n['data'] as Map?)?.cast<String, dynamic>() ??
                              const {};
                      final read = n['read'] == true;
                      return ListTile(
                        leading: Icon(_iconFor(type),
                            color: read ? scheme.outline : scheme.primary),
                        title: Text(n['title'] as String? ?? 'Notification',
                            style: TextStyle(
                                fontWeight: read
                                    ? FontWeight.normal
                                    : FontWeight.bold)),
                        subtitle: Text(n['body'] as String? ?? ''),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Dismiss',
                          onPressed: () =>
                              service.dismissNotification(d.id),
                        ),
                        onTap: () => _onTap(context, service, d.id, data, type),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// An error strip that the user can dismiss (×), so a transient error can never
/// permanently cover UI beneath the global overlay.
class _DismissibleErrorStrip extends StatefulWidget {
  final String message;
  const _DismissibleErrorStrip({required this.message});
  @override
  State<_DismissibleErrorStripState> createState() => _DismissibleErrorStripState();
}

class _DismissibleErrorStripState extends State<_DismissibleErrorStrip> {
  bool _dismissed = false;
  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Expanded(
              child: Text(widget.message,
                  style:
                      TextStyle(color: scheme.onErrorContainer, fontSize: 11)),
            ),
            InkWell(
              onTap: () => setState(() => _dismissed = true),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close,
                    size: 16, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The actual banner content: watches waitingGamesStream and shows a compact,
/// tappable strip when the player has a game waiting to start. Hidden entirely
/// when there is no waiting game. Uses the root navigator to enter the board.
class _GlobalWaitingBanner extends StatefulWidget {
  final GameService service;
  const _GlobalWaitingBanner({required this.service});

  @override
  State<_GlobalWaitingBanner> createState() => _GlobalWaitingBannerState();
}

class _GlobalWaitingBannerState extends State<_GlobalWaitingBanner> {
  // Cache the waiting-games stream per signed-in user (see _GlobalNotificationBell
  // for the full rationale). Must (re)create on auth change: this widget mounts
  // ABOVE auth and first runs initState before anyone is signed in.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _stream;
  String? _streamUid;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _syncStream();
    _authSub = widget.service.authStateChanges().listen((_) {
      if (mounted) setState(_syncStream);
    });
  }

  void _syncStream() {
    final uid = widget.service.uid;
    if (uid != _streamUid) {
      _streamUid = uid;
      _stream = uid == null ? null : widget.service.waitingGamesStream();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final uid = service.uid;
    final scheme = Theme.of(context).colorScheme;

    if (uid == null || _stream == null) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: gameRouteOnTop,
      builder: (context, onBoard, _) {
        if (onBoard) return const SizedBox.shrink();
        return StreamBuilder<
            List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
          stream: _stream,
          builder: (context, snap) {
            // Only surface real errors (quietly); otherwise stay invisible when
            // there's nothing to show. Dismissible so it can never block UI.
            if (snap.hasError) {
              final err = snap.error!;
              // A stale refresh token (after an emulator restart) makes every
              // read fail with UNAUTHENTICATED and the SDK loops. Force a clean
              // sign-out so the app routes back to sign-in instead of hanging.
              if (service.isStaleAuthError(err)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  service.recoverFromStaleAuth();
                });
                return const _DismissibleErrorStrip(
                    message: 'Session expired — please sign in again.');
              }
              return _DismissibleErrorStrip(
                  message: 'Waiting-games error: $err');
            }
            final docs = snap.data ?? const [];
            if (docs.isEmpty) return const SizedBox.shrink();
            final d = docs.first;
            final g = d.data();
            final ready =
                (g['ready'] as List?)?.cast<String>() ?? const <String>[];
            final iAmReady = ready.contains(uid);

            return Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(Icons.sports_esports,
                        color: scheme.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        iAmReady
                            ? 'Your game is waiting for your opponent to join.'
                            : 'You have a game ready to start.',
                        style: TextStyle(
                            color: scheme.onTertiaryContainer, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Before readying: a prominent "Enter" call to action.
                    // After readying: a quiet "Open" — you've done your part, so
                    // we don't pester you to keep tapping. When your opponent
                    // readies, the game activates and you're pulled in
                    // automatically (no tap needed).
                    if (iAmReady)
                      TextButton(
                        onPressed: () {
                          rootNavigatorKey.currentState?.push(
                            MaterialPageRoute(
                              settings: const RouteSettings(name: 'game'),
                              builder: (_) =>
                                  GameScreen(gameId: d.id, service: service),
                            ),
                          );
                        },
                        child: const Text('Open'),
                      )
                    else
                      FilledButton(
                        onPressed: () {
                          rootNavigatorKey.currentState?.push(
                            MaterialPageRoute(
                              settings: const RouteSettings(name: 'game'),
                              builder: (_) =>
                                  GameScreen(gameId: d.id, service: service),
                            ),
                          );
                        },
                        child: const Text('Enter'),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
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

  // TEST-ONLY: email/password sign-in against the auth emulator (Google
  // sign-in does not complete against the emulator on physical devices).
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController(text: 'test1234');

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _signInTest() async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.length < 6) {
      setState(() => _error = 'Enter an email and a 6+ char password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.signInWithTestEmail(email, pass);
      // AuthGate stream routes to HomeScreen on success.
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Test sign-in failed.');
    } catch (e) {
      setState(() => _error = 'Test sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
            // ---- TEST-ONLY email/password (auth emulator) ----
            if (!_busy) ...[
              const SizedBox(height: 28),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Divider(),
              ),
              const SizedBox(height: 8),
              const Text('Test sign-in (emulator)',
                  style: TextStyle(fontSize: 12, color: Colors.black45)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  children: [
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        hintText: 'a@test.com',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _signInTest,
                      child: const Text('Sign in (test)'),
                    ),
                  ],
                ),
              ),
            ],
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

  String? _currentGameId;

  @override
  void initState() {
    super.initState();
    setupFcm(_service);
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _enterGame(String gameId) async {
    if (_currentGameId != null) return;
    _currentGameId = gameId;
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'game'),
      builder: (_) => GameScreen(gameId: gameId, service: _service),
    ));
    if (mounted) _currentGameId = null;
  }

  Future<void> _quickMatch() async {
    setState(() {
      _busy = true;
      _status = 'Finding a game…';
    });
    try {
      final gameId = await _service.quickMatch();
      if (!mounted) return;
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
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chess Masters'),
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => _service.signOut(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== PROFILE HEADER =====
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          scheme.primary,
                          scheme.secondary,
                        ],
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.castle,
                        size: 32,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Name & subtitle
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Chess Masters',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Signed in as $name',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ===== STATS CARDS =====
            Row(
              children: [
                // CP Card
                Expanded(
                  child: _StatCard(
                    icon: Icons.toll,
                    label: 'CP',
                    child: StreamBuilder<int>(
                      stream: _service.myCpBalanceStream(),
                      builder: (context, snap) {
                        final cp = snap.data;
                        return Text(
                          cp == null ? '…' : '${cp ~/ 1}',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Rating Card
                Expanded(
                  child: _StatCard(
                    icon: Icons.military_tech,
                    label: 'RATING',
                    child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: _service.myProfileStream(),
                      builder: (context, snap) {
                        final rating = (snap.data?.data()?['rating'] as num?)?.round();
                        return Text(
                          rating == null ? '…' : '$rating',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Rank Card
                Expanded(
                  child: _StatCard(
                    icon: Icons.leaderboard,
                    label: 'RANK',
                    child: Text(
                      '—',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            // ===== MENU ITEMS =====
            _MenuItem(
              icon: Icons.play_circle_outlined,
              label: 'Quick Match',
              subtitle: 'Find a random opponent',
              onTap: _busy ? null : _quickMatch,
            ),
            const SizedBox(height: 12),
            _MenuItem(
              icon: Icons.groups,
              label: 'Circles',
              subtitle: 'Join communities & play friends',
              onTap: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CirclesScreen(service: _service),
                      )),
            ),
            const SizedBox(height: 12),
            _MenuItem(
              icon: Icons.public,
              label: 'Open Lobby',
              subtitle: 'Stake CP against strangers',
              onTap: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => LobbyScreen(service: _service),
                      )),
            ),
            const SizedBox(height: 12),
            _MenuItem(
              icon: Icons.leaderboard,
              label: 'Leaderboards',
              subtitle: 'View top players & circles',
              onTap: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => LeaderboardScreen(service: _service),
                      )),
            ),
            const SizedBox(height: 12),
            _MenuItem(
              icon: Icons.chat_bubble_outline,
              label: 'Chat',
              subtitle: 'Coming soon',
              badge: 'soon',
              onTap: null,
            ),

            const SizedBox(height: 24),

            // Status indicator
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _status ?? 'Loading…',
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Individual stat card widget
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.outline,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Menu item tile
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final String? badge;
  final VoidCallback? onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDisabled = onTap == null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDisabled
                ? scheme.surfaceContainerLowest.withOpacity(0.5)
                : scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: scheme.outlineVariant.withOpacity(isDisabled ? 0.3 : 1),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDisabled
                      ? scheme.surfaceVariant.withOpacity(0.5)
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: isDisabled
                      ? scheme.outline.withOpacity(0.5)
                      : scheme.onPrimaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDisabled
                            ? scheme.outline.withOpacity(0.5)
                            : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDisabled
                            ? scheme.outline.withOpacity(0.4)
                            : scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
              if (badge == null)
                Icon(
                  Icons.chevron_right,
                  color: isDisabled
                      ? scheme.outline.withOpacity(0.3)
                      : scheme.outline,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
