import 'package:flutter/material.dart';

import 'ui/theme.dart';
import 'web/web_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ThusfarWebApp());
}

class ThusfarWebApp extends StatefulWidget {
  const ThusfarWebApp({super.key});

  @override
  State<ThusfarWebApp> createState() => _ThusfarWebAppState();
}

class _ThusfarWebAppState extends State<ThusfarWebApp> {
  final WebReadingRouter _router = WebReadingRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: '页读 · Thusfar',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    routerDelegate: _router,
    routeInformationParser: const WebReadingRouteParser(),
  );
}
