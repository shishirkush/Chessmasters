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
  State<_DismissibleErrorStrip> createState() => _DismissibleErrorStripState();
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

  // Auto-navigation into active games. A staked/challenge game is created
  // server-side when the OPPONENT accepts, so the issuer (challenger) has no
  // action that returns a gameId — without this they'd sit on whatever screen
  // they were on while their game (and clock) is live. This listener watches
  // the user's active games and pulls them into the board the moment one
  // appears, no matter which screen is on top. Works uniformly for the
  // accepter and the issuer, peer stakes and challenge-ups.
  // NOTE: auto-navigation into newly-active games is intentionally DISABLED.
  // The flow is "always tap Enter": the global waiting banner and the
  // notification center both give every player an explicit Enter/Open button,
  // so entering a game is always a deliberate tap — predictable and consistent,
  // never a surprise yank onto a board. `_enterGame` remains for the cases where
  // WE initiated and should follow our own action (e.g. quick match).
  String? _currentGameId; // the game whose board is currently on top, if any

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _enterGame(String gameId) async {
    if (_currentGameId != null) return; // already on a board
    _currentGameId = gameId;
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'game'),
      builder: (_) => GameScreen(gameId: gameId, service: _service),
    ));
    // Returned from the board (game over or user backed out).
    if (mounted) _currentGameId = null;
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
      // _enterGame guards against double-push via _currentGameId; the active-
      // games listener won't stack because of the same guard.
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
                        settings: const RouteSettings(name: 'game'),
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
  bool _finishedHandled = false; // ensures auto-return fires only once

  /// Called from build when the game reaches a terminal `finished` state. Shows
  /// the result for a few seconds so the player sees the outcome, then returns
  /// them to wherever they came from (Home/Circle) — so a finished/abandoned
  /// game never strands the player on a dead board. Fires exactly once.
  void _handleFinished() {
    if (_finishedHandled) return;
    _finishedHandled = true;
    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    });
  }

  @override
  void initState() {
    super.initState();
    // The global bell/banner hide themselves while a board is on top via the
    // NavigatorObserver (gameRouteOnTop) — no per-screen counter to manage here.
    // Ready-gate: signal presence as soon as this board opens. For a pre-seated
    // staked/conquest game in `waiting`, this adds us to `ready`; the game
    // activates (clock starts) only once BOTH players have done so. For casual
    // games (or already-active games) the server no-ops / rejects cleanly, so we
    // swallow errors. Readying is sticky — we can leave after this; the game
    // won't block other play.
    _markReadyOnce();
  }

  Future<void> _markReadyOnce() async {
    try {
      await widget.service.markReady(widget.gameId);
    } catch (_) {
      // Casual games and already-active/finished games throw or no-op here —
      // harmless. The stream remains the source of truth for what to show.
    }
  }

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
          // When the game reaches a terminal state, show the result briefly then
          // auto-return so the player isn't stranded on a dead board.
          if (status == 'finished') {
            _handleFinished();
          }
          final fen = g['fen'] as String;
          final turn = g['turn'] as String; // 'w' | 'b'
          final whiteId = g['whiteId'] as String?;
          final blackId = g['blackId'] as String?;
          final result = g['result'] as String?;
          final reason = g['resultReason'] as String?;
          final gameType = g['gameType'] as String?;
          final contextId = g['contextId'] as String?;

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
              // Ready-gate: while the pre-seated game is `waiting`, the board is
              // locked and clocks are frozen (handled by canMove/_trackClock).
              // Show WHY — we're waiting for the other player to arrive. The
              // clock only starts once both have opened the board (markReady).
              if (status == 'waiting')
                Builder(builder: (context) {
                  final ready =
                      (g['ready'] as List?)?.cast<String>() ?? const <String>[];
                  final iAmReady = myUid != null && ready.contains(myUid);
                  final scheme = Theme.of(context).colorScheme;
                  return Container(
                    width: double.infinity,
                    color: scheme.secondaryContainer,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            iAmReady
                                ? 'Waiting for your opponent to join… The clock '
                                    'starts when both of you are here. You can '
                                    'leave and come back — your spot is held.'
                                : 'Joining…',
                            style: TextStyle(
                                color: scheme.onSecondaryContainer,
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              // Slice 4: when a finished BREACH/GAUNTLET game's conquest has a
              // next game ready (or a terminal outcome), show a prompt here so
              // the player explicitly enters the next game. This drives the
              // whole chain (breach → gauntlet 1 → 2 → 3 → terminal) reliably
              // from the board, independent of HomeScreen's auto-nav.
              if (status == 'finished' &&
                  (gameType == 'gauntlet' || gameType == 'breach') &&
                  contextId != null)
                _ConquestNextStep(
                  service: widget.service,
                  conquestId: contextId,
                  finishedGameId: widget.gameId,
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

/// Shown under the board on a FINISHED breach/gauntlet game. Watches the
/// conquest and tells the player what's next:
///   - a new game is ready and I'm in it  → "Enter next game" (pushReplacement)
///   - breach won, Gauntlet not yet started → "Awaiting the Gauntlet…"
///   - terminal (won / ejected / breach failed) → outcome message
/// This drives the conquest chain reliably from the board itself, so each
/// player explicitly enters each game (no dependency on HomeScreen auto-nav).
class _ConquestNextStep extends StatelessWidget {
  final GameService service;
  final String conquestId;
  final String finishedGameId;
  const _ConquestNextStep({
    required this.service,
    required this.conquestId,
    required this.finishedGameId,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myUid = service.uid;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: service.conquestStream(conquestId),
      builder: (context, snap) {
        final q = snap.data?.data();
        if (q == null) return const SizedBox.shrink();

        final status = q['status'] as String?;
        final gauntlet = q['gauntlet'] as Map<String, dynamic>?;
        final currentGameId = gauntlet?['currentGameId'] as String?;

        // Terminal outcomes.
        if (status == 'challenger_won') {
          return _banner(
            scheme.primaryContainer,
            scheme.onPrimaryContainer,
            Icons.emoji_events,
            'Conquest won — full membership granted!',
          );
        }
        if (status == 'challenger_ejected') {
          return _banner(
            scheme.errorContainer,
            scheme.onErrorContainer,
            Icons.block,
            'Ejected — the Gauntlet was held.',
          );
        }
        if (status == 'breach_failed') {
          return _banner(
            scheme.errorContainer,
            scheme.onErrorContainer,
            Icons.block,
            'Breach failed.',
          );
        }

        // Breach won, awaiting the owner's Gauntlet nomination.
        if (status == 'gauntlet_pending') {
          return _banner(
            scheme.tertiaryContainer,
            scheme.onTertiaryContainer,
            Icons.hourglass_top,
            'Breach won — awaiting the Gauntlet defender.',
          );
        }

        // A next game is live. Offer to enter it IF I'm a player in it and it
        // isn't the game I just finished.
        if (status == 'gauntlet_active' &&
            currentGameId != null &&
            currentGameId != finishedGameId) {
          return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            future: service.gameOnce(currentGameId),
            builder: (context, gSnap) {
              final game = gSnap.data?.data();
              if (game == null) return const SizedBox.shrink();
              final players =
                  (game['players'] as List?)?.cast<String>() ?? <String>[];
              if (myUid == null || !players.contains(myUid)) {
                // I'm not in the next game (e.g. I was the breach defender, not
                // the Gauntlet defender). Just show series state.
                final cw = (gauntlet?['challengerWins'] as num?)?.toInt() ?? 0;
                final dw = (gauntlet?['defenderWins'] as num?)?.toInt() ?? 0;
                return _banner(
                  scheme.secondaryContainer,
                  scheme.onSecondaryContainer,
                  Icons.sports_kabaddi,
                  'Gauntlet in progress — challenger $cw : $dw defender.',
                );
              }
              final cw = (gauntlet?['challengerWins'] as num?)?.toInt() ?? 0;
              final dw = (gauntlet?['defenderWins'] as num?)?.toInt() ?? 0;
              return Container(
                width: double.infinity,
                color: scheme.tertiaryContainer,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.sports_kabaddi,
                        color: scheme.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Next Gauntlet game is ready (challenger $cw : $dw '
                        'defender).',
                        style: TextStyle(
                            color: scheme.onTertiaryContainer, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        // Replace this finished board with the next game.
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            settings: const RouteSettings(name: 'game'),
                            builder: (_) => GameScreen(
                              gameId: currentGameId,
                              service: service,
                            ),
                          ),
                        );
                      },
                      child: const Text('Enter next game'),
                    ),
                  ],
                ),
              );
            },
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _banner(Color bg, Color fg, IconData icon, String text) {
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(icon, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: fg, fontSize: 13)),
          ),
        ],
      ),
    );
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

              // My own position in the ranked list. Challenge-up is only valid
              // against players ranked ABOVE me (design §: the lower-ranked
              // player challenges up for a rating climb). If I'm not found
              // (shouldn't happen for a member), default to last so no Challenge
              // buttons show.
              final myIndex = profiles.indexWhere((p) => p['uid'] == myUid);
              final myRank = myIndex < 0 ? profiles.length : myIndex;

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
                  // Slice 4: owner-only nominate prompt when a breach was won
                  // and the Gauntlet awaits a champion (renders nothing else).
                  _GauntletNominateBanner(
                    service: service,
                    circleId: circleId,
                    ownerId: ownerId ?? '',
                    members: members,
                  ),
                  // Slice 4: live Gauntlet series score while one is active.
                  _GauntletProgressBanner(
                      service: service, circleId: circleId),
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
                                // Challenge-up only targets players ranked ABOVE
                                // me (a shot at a rating climb against a stronger
                                // player). i < myRank means this member outranks
                                // me, so the button is shown; otherwise hidden.
                                if (i < myRank)
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
                                      circleId: circleId,
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
                        settings: const RouteSettings(name: 'game'),
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

/// Owner-only: when a conquest on this circle reaches `gauntlet_pending` (the
/// challenger won the breach), the owner must nominate a champion to play the
/// best-of-3 Gauntlet. Tapping "Nominate" opens a member picker; choosing a
/// member calls nominateGauntletDefender, which locks their first stake and
/// starts game 1 (both players are auto-pushed into the board by the active-
/// games listener). Renders nothing if the viewer isn't the owner or there's
/// no pending Gauntlet.
class _GauntletNominateBanner extends StatelessWidget {
  final GameService service;
  final String circleId;
  final String ownerId;
  final List<String> members;
  const _GauntletNominateBanner({
    required this.service,
    required this.circleId,
    required this.ownerId,
    required this.members,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only the owner nominates.
    if (service.uid != ownerId) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: service.gauntletPendingForCircleStream(circleId),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final conquest = docs.first;
        final conquestId = conquest.id;
        final challengerId =
            conquest.data()['challengerId'] as String? ?? '';

        return Container(
          width: double.infinity,
          color: scheme.tertiaryContainer,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.military_tech, color: scheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Your circle is breached — nominate your champion to defend '
                  'the Gauntlet (best of 3).',
                  style: TextStyle(
                      color: scheme.onTertiaryContainer, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _showNominateDialog(
                    context, service, conquestId, challengerId, members),
                child: const Text('Nominate'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Member picker for the Gauntlet nomination. Lists circle members (excluding
/// the challenger), showing name + rating; tapping one nominates them.
Future<void> _showNominateDialog(
  BuildContext context,
  GameService service,
  String conquestId,
  String challengerId,
  List<String> members,
) async {
  // Eligible nominees: members who are not the challenger.
  final eligible = members.where((m) => m != challengerId).toList();
  final profiles = await service.fetchProfiles(eligible);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      bool busy = false;
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Nominate your champion'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'They play the challenger best-of-3. They stake a small '
                    'discounted amount each game: lose a game and it burns; '
                    'win or draw and it returns. You may nominate yourself.',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: profiles.map((p) {
                        final uid = p['uid'] as String;
                        final name = p['displayName'] as String? ?? 'Player';
                        final rating = (p['rating'] as num?)?.toInt() ?? 1500;
                        return ListTile(
                          leading: const Icon(Icons.person),
                          title: Text(name),
                          trailing: Text('$rating'),
                          onTap: busy
                              ? null
                              : () async {
                                  setState(() {
                                    busy = true;
                                    error = null;
                                  });
                                  try {
                                    final gameId = await service
                                        .nominateGauntletDefender(
                                      conquestId: conquestId,
                                      defenderId: uid,
                                    );
                                    if (dialogContext.mounted) {
                                      Navigator.of(dialogContext).pop();
                                      // If the owner nominated THEMSELVES, push
                                      // them straight into game 1 (the reliable
                                      // path — don't depend on HomeScreen's
                                      // auto-nav, which only fires from Home).
                                      // A nominated OTHER member is on their own
                                      // device; they enter via their HomeScreen
                                      // auto-nav or the conquest prompt.
                                      if (uid == service.uid &&
                                          dialogContext.mounted) {
                                        Navigator.of(dialogContext).push(
                                          MaterialPageRoute(
                                            settings: const RouteSettings(name: 'game'),
                                            builder: (_) => GameScreen(
                                              gameId: gameId,
                                              service: service,
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  } on FirebaseFunctionsException catch (e) {
                                    setState(() {
                                      busy = false;
                                      error = e.message ?? 'Failed';
                                    });
                                  }
                                },
                        );
                      }).toList(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Shows live Gauntlet series progress for any active Gauntlet on this circle
/// (challenger X – Y defender, current game). Visible to all members so they
/// can follow the trial. Renders nothing if no Gauntlet is active.
class _GauntletProgressBanner extends StatelessWidget {
  final GameService service;
  final String circleId;
  const _GauntletProgressBanner({
    required this.service,
    required this.circleId,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: service.activeGauntletForCircleStream(circleId),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final g = docs.first.data()['gauntlet'] as Map<String, dynamic>?;
        final cWins = (g?['challengerWins'] as num?)?.toInt() ?? 0;
        final dWins = (g?['defenderWins'] as num?)?.toInt() ?? 0;

        return Container(
          width: double.infinity,
          color: scheme.secondaryContainer,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.sports_kabaddi, color: scheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Gauntlet in progress — challenger $cWins : $dWins defender '
                  '(first to 2 wins).',
                  style: TextStyle(
                      color: scheme.onSecondaryContainer, fontSize: 13),
                ),
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
              trailing = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Breach: opens the challenger screen (all eligibility
                  // checks + stake preview live there). Makes the conquest
                  // path discoverable beside Join.
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.deepOrange,
                      side: const BorderSide(color: Colors.deepOrange),
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChallengerCircleScreen(
                          service: service,
                          circleId: circleId,
                          circleName: name,
                        ),
                      ),
                    ),
                    child: const Text('Breach'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
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
                  ),
                ],
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
                            error = e.message ?? 'Failed to send offer';
                          });
                        } catch (e) {
                          // Non-Functions errors (e.g. a stale auth token throws
                          // a platform ExecutionException "1 of 2 underlying
                          // tasks failed"). Show a friendly, actionable message
                          // rather than a raw Java stack trace.
                          final raw = e.toString();
                          final isStaleAuth = raw.contains('ExecutionException') ||
                              raw.contains('underlying tasks failed') ||
                              raw.contains('UNAUTHENTICATED') ||
                              raw.contains('INVALID_REFRESH_TOKEN');
                          setState(() {
                            busy = false;
                            error = isStaleAuth
                                ? 'Session expired. Sign out and back in, then try again.'
                                : 'Could not send offer. Please try again.';
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
  String? circleId,
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
                          await service.proposeChallengeUp(opponentId,
                              circleId: circleId);
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
