import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keep the render surface, MediaQuery and pointer coordinates on one device
/// profile. setSurfaceSize alone leaves the test view's physical metrics intact.
Future<void> setTestViewport(WidgetTester tester, Size? size) async {
  if (size == null) {
    tester.view.resetPhysicalSize();
  } else {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
  }
  await tester.binding.setSurfaceSize(size);
}
