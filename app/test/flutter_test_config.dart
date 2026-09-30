import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/golden_platform.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final GoldenFileComparator comparator = goldenFileComparator;
  if (comparator is! LocalFileComparator) {
    throw StateError('Expected Flutter\'s local exact golden comparator.');
  }
  goldenFileComparator = PlatformGoldenFileComparator(
    comparator.basedir.resolve('flutter_test_config.dart'),
  );
  await testMain();
}
