import 'package:flutter/material.dart';

import 'ui/theme.dart';
import 'web/web_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ThusfarWebApp());
}

class ThusfarWebApp extends StatelessWidget {
  const ThusfarWebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '页读 · Thusfar',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const WebShelf(),
  );
}
