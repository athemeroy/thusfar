import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/screens/background_processing_screen.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('thusfar/background_settings');
  final List<String> calls = <String>[];
  bool exempt = false;

  setUp(() {
    exempt = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          if (call.method == 'status') {
            return <String, Object>{
              'batteryExempt': exempt,
              'powerSave': false,
              'backgroundRestricted': false,
              'notifications': true,
              'manufacturer': 'OPPO',
            };
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'denying the system request does not mark background access granted',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const BackgroundProcessingScreen(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '允许后台运行'));
      await tester.pumpAndSettle();
      expect(calls, contains('requestBatteryExemption'));
      expect(find.widgetWithText(FilledButton, '已允许'), findsNothing);
      expect(find.widgetWithText(FilledButton, '允许后台运行'), findsOneWidget);
    },
  );

  testWidgets(
    'returning from settings reads the real grant and retains OEM guidance',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const BackgroundProcessingScreen(),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      exempt = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '已允许'), findsOneWidget);
      expect(find.textContaining('页读无法读取所有厂商的开关'), findsOneWidget);
      await tester.ensureVisible(find.text('打开页读的手机设置'));
      await tester.tap(find.text('打开页读的手机设置'));
      await tester.pumpAndSettle();
      expect(calls, contains('openAppSettings'));
    },
  );
}
