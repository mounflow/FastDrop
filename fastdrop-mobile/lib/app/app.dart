import 'package:flutter/material.dart';

import 'package:fastdrop_mobile/app/routes.dart';
import 'package:fastdrop_mobile/app/theme.dart';

/// Root widget of the FastDrop mobile app.
///
/// The splash gate (`/` route) checks for an existing session and redirects
/// to the appropriate screen — no session-logic lives at this level.
class FastDropApp extends StatelessWidget {
  const FastDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastDrop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.home,
      onGenerateRoute: AppRoutes.generateRoute,
    );
  }
}
