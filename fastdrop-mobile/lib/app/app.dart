import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/app/routes.dart';
import 'package:fastdrop_mobile/app/theme.dart';
import 'package:fastdrop_mobile/core/server/server_providers.dart';
import 'package:fastdrop_mobile/features/pairing/pair_confirm_dialog.dart';
import 'package:fastdrop_mobile/features/transfer/receive_confirm_dialog.dart';

/// Root widget of the FastDrop mobile app.
///
/// The splash gate (`/` route) checks for an existing session and redirects
/// to the appropriate screen — no session-logic lives at this level.
///
/// Phase 3: wraps the app with dialog watchers for incoming pair requests
/// and transfer offers, and manages the embedded server lifecycle.
class FastDropApp extends ConsumerStatefulWidget {
  const FastDropApp({super.key});

  @override
  ConsumerState<FastDropApp> createState() => _FastDropAppState();
}

class _FastDropAppState extends ConsumerState<FastDropApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Eagerly initialize the embedded server so it starts on app launch
    // (the provider is lazy by default — reading it triggers the constructor
    // which calls _loadEnabled → start).
    ref.read(fastdropServerProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Ensure the embedded server is running when the app comes back.
      ref.read(fastdropServerProvider.notifier).ensureRunning();
    }
    // On paused: keep the server running for background transfers.
    // On detach: the server will be stopped via dispose.
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastDrop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.light,
      navigatorKey: _navigatorKey,
      initialRoute: AppRoutes.home,
      onGenerateRoute: AppRoutes.generateRoute,
      // Dialog watchers live in the builder (above the Navigator), so they
      // use the navigatorKey to get a context *inside* the Navigator for
      // showDialog.  Without this, Navigator.of(builderContext) throws
      // because the builder context has no Navigator ancestor.
      builder: (context, child) {
        return PairConfirmDialogWatcher(
          navigatorKey: _navigatorKey,
          child: ReceiveConfirmDialogWatcher(
            navigatorKey: _navigatorKey,
            child: child!,
          ),
        );
      },
    );
  }
}
