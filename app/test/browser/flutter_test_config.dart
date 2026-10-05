import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

// Browser behavior tests do not compare golden files. Keep their bootstrap
// separate from the parent suite's macOS-only exact image comparator.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Chrome can route Flutter's debugPrint output to the browser console rather
  // than the test reporter, leaving CI with only "See exception logs above".
  // Mirror diagnostics through package:test's captured print without changing
  // the default reporter or consuming the failure.
  final TestExceptionReporter previous = reportTestException;
  reportTestException = (details, description) {
    // ignore: avoid_print
    print(
      'BROWSER TEST FAILURE ($description): ${details.exceptionAsString()}',
    );
    // ignore: avoid_print
    print(details.stack);
    previous(details, description);
  };
  await testMain();
}
