import 'dart:io';

/// The process environment as the Python engine saw `os.environ`.
///
/// It is mutable on purpose: the engine, its settings screen and tests change
/// model routes at run time exactly as the Python code assigned `os.environ`.
final Map<String, String> environ = Map<String, String>.of(
  Platform.environment,
);

/// `os.environ.get(key)` with Python's empty-string semantics preserved.
String? env(String key) => environ[key];
