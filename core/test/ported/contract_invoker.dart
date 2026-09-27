import '../golden/golden_registry.dart';

/// Runs a named production adapter with the same tagged input shape as a
/// function golden. The owning test remains skipped until that adapter exists.
Object? callPorted(String functionId, Map<String, Object?> input) {
  final invoke = goldenRegistry[functionId];
  if (invoke == null) {
    throw StateError('No Dart production adapter registered for $functionId');
  }
  return invoke(input);
}
