import 'adapters_a1.dart';
import 'adapters_engine.dart';

/// A migrated Python function receives one typed adapter keyed by its
/// inventory id. Each adapter decodes the recorded argument shape and returns
/// the same JSON-compatible shape as the Python oracle.
typedef GoldenInvoker = Object? Function(Map<String, Object?> input);

final Map<String, GoldenInvoker> goldenRegistry = <String, GoldenInvoker>{
  ...a1Adapters,
  ...engineAdapters,
};

/// Special fixtures use deterministic test-only setup for closures, callbacks,
/// injected state, or in-place mutation. A state fixture returns an envelope
/// containing `after`, `return`, and any recorded alias observations.
typedef SpecialGoldenInvoker = Object? Function(Map<String, Object?> input);

const Map<String, SpecialGoldenInvoker> specialGoldenRegistry =
    <String, SpecialGoldenInvoker>{};
