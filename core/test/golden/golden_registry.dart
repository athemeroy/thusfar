/// A migrated Python function receives one typed adapter keyed by its
/// inventory id. Each adapter decodes the recorded argument shape and returns
/// the same JSON-compatible shape as the Python oracle.
typedef GoldenInvoker = Object? Function(Map<String, Object?> input);

const Map<String, GoldenInvoker> goldenRegistry = <String, GoldenInvoker>{};
