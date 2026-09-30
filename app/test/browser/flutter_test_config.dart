import 'dart:async';

// Browser behavior tests do not compare golden files. Keep their bootstrap
// separate from the parent suite's macOS-only exact image comparator.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
