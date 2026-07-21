import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/features/pairing/pairing_screen.dart';
import 'package:fastdrop_mobile/features/devices/devices_screen.dart';
import 'package:fastdrop_mobile/features/file_picker/file_picker_screen.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_screen.dart';
import 'package:fastdrop_mobile/features/history/history_screen.dart';
import 'package:fastdrop_mobile/features/settings/settings_screen.dart';
import 'package:fastdrop_mobile/core/providers.dart';

/// Central route definitions and generator for the FastDrop app.
class AppRoutes {
  AppRoutes._();

  // Route names
  static const String home = '/';
  static const String pairing = '/pairing';
  static const String devices = '/devices';
  static const String filePicker = '/file-picker';
  static const String transfer = '/transfer';
  static const String history = '/history';
  static const String settings = '/settings';

  /// Generates routes on demand.
  static Route<dynamic>? generateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case home:
        return _page(routeSettings, const _SplashGate());
      case pairing:
        return _page(routeSettings, const PairingScreen());
      case devices:
        return _page(routeSettings, const DevicesScreen());
      case filePicker:
        return _page(routeSettings, const FilePickerScreen());
      case transfer:
        return _page(routeSettings, const TransferScreen());
      case history:
        return _page(routeSettings, const HistoryScreen());
      case settings:
        return _page(routeSettings, const SettingsScreen());
      default:
        return _page(routeSettings, const _NotFoundScreen());
    }
  }

  static MaterialPageRoute<dynamic> _page(
    RouteSettings settings,
    Widget page,
  ) {
    return MaterialPageRoute(
      settings: settings,
      builder: (_) => page,
    );
  }
}

// ---------------------------------------------------------------------------
// Splash gate — checks for existing session and redirects accordingly.
// ---------------------------------------------------------------------------

final _sessionCheckProvider = FutureProvider<String?>((ref) async {
  final session = await ref.read(sessionStoreProvider).loadSession();
  if (session != null && session.isSessionValid) {
    return session.serverBaseUrl;
  }
  return null;
});

class _SplashGate extends ConsumerStatefulWidget {
  const _SplashGate();

  @override
  ConsumerState<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<_SplashGate> {
  bool _navigated = false;

  @override
  Widget build(BuildContext context) {
    final sessionCheck = ref.watch(_sessionCheckProvider);

    // Once the session check completes, redirect to the appropriate screen.
    // Navigation must be deferred to after the frame — calling Navigator
    // inside build() triggers a '!navigator._debugLocked' assertion.
    if (!_navigated) {
      sessionCheck.when(
        data: (serverBaseUrl) {
          _navigated = true;
          final target = serverBaseUrl != null ? AppRoutes.devices : AppRoutes.pairing;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).pushReplacementNamed(target);
            }
          });
        },
        error: (_, __) {
          // On error (e.g. SharedPreferences unavailable), go to pairing.
          _navigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).pushReplacementNamed(AppRoutes.pairing);
            }
          });
        },
        loading: () {},
      );
    }

    // Show branded splash while checking.
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swap_horiz,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'FastDrop',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

// -- 404 ----------------------------------------------------------------------

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Not Found')),
      body: const Center(
        child: Text('Route not found.'),
      ),
    );
  }
}
