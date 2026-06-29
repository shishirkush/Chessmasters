/// Chess Masters — FCM client setup (Stage 1a, Android).
///
/// What this does:
///   - a top-level BACKGROUND handler (required by FCM, registered in main()),
///   - setupFcm(): request notification permission, fetch the device token,
///     register it server-side, and keep it fresh when it rotates.
///
/// Display policy (Stage 1a):
///   - App in BACKGROUND or KILLED → for a "notification" message the OS shows
///     the system notification automatically (using the default channel). We do
///     not draw anything ourselves, so no flutter_local_notifications needed.
///   - App in FOREGROUND → Android does NOT auto-display notification messages,
///     and that's fine: the in-app notification bell (the notifications stream)
///     already surfaces the event on-screen. So we deliberately do nothing on
///     foreground messages here.
///
/// Only the server's allowlist (game_ready / breach_initiated /
/// gauntlet_nominated) ever results in a push — see fcm.ts. The client doesn't
/// decide what pushes; it just registers the device and lets pushes arrive.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'game_service.dart';

/// Background / terminated message handler. MUST be a top-level or static
/// function annotated with @pragma('vm:entry-point') (it runs in a separate
/// isolate). Registered via FirebaseMessaging.onBackgroundMessage in main()
/// BEFORE runApp. For a notification message the OS handles display; we have no
/// work to do for Stage 1a, but the handler must exist for background delivery.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No-op for Stage 1a. (Future: handle data payload / deep-link prep here.)
}

/// Guards the onTokenRefresh subscription so repeated setupFcm() calls (e.g. a
/// second sign-in in the same app session) don't stack duplicate listeners.
bool _tokenRefreshListenerAdded = false;

/// One-time-per-sign-in messaging setup. Call once the user is signed in (we
/// invoke it from _HomeScreenState.initState, which the AuthGate only reaches
/// when authed). Safe to call again on a later sign-in: it re-registers the
/// current token for the now-current user, and only ever adds ONE refresh
/// listener for the whole process.
Future<void> setupFcm(GameService service) async {
  final messaging = FirebaseMessaging.instance;

  // Android 13+ (API 33) shows a runtime notification-permission prompt here.
  // Older Android returns authorized without prompting. We request but don't
  // hard-gate on the result — an un-permitted device simply won't display
  // pushes, which is acceptable (the in-app bell still works).
  await messaging.requestPermission();

  // Register the current token for the signed-in user.
  try {
    final token = await messaging.getToken();
    if (token != null) {
      await service.registerFcmToken(token);
    }
  } catch (e) {
    debugPrint('FCM: token registration failed: $e');
  }

  // Re-register whenever FCM rotates the token (can happen any time). One
  // listener for the app's lifetime; it registers against whoever is currently
  // signed in (the callable uses the live auth context).
  if (!_tokenRefreshListenerAdded) {
    _tokenRefreshListenerAdded = true;
    messaging.onTokenRefresh.listen((token) async {
      try {
        await service.registerFcmToken(token);
      } catch (e) {
        debugPrint('FCM: token refresh registration failed: $e');
      }
    });
  }
}
