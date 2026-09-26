/// Exceptions whose Python type and message are part of the oracle contract.
///
/// [pyType] is the fully qualified Python class the 1.7.5 engine raised, so
/// goldens can compare both the kind of failure and its user-facing text.
sealed class PyException implements Exception {
  const PyException(this.message);

  final String message;

  String get pyType;

  @override
  String toString() => message;
}

/// Python `ValueError`: invalid input or data.
base class ValueError extends PyException {
  const ValueError(super.message);

  @override
  String get pyType => 'builtins.ValueError';
}

/// Python `RuntimeError`: a policy or state refusal.
base class RuntimeError extends PyException {
  const RuntimeError(super.message);

  @override
  String get pyType => 'builtins.RuntimeError';
}

/// Python `TimeoutError`.
final class PyTimeoutError extends PyException {
  const PyTimeoutError(super.message);

  @override
  String get pyType => 'builtins.TimeoutError';
}

/// Python `json.JSONDecodeError` (a `ValueError`), raised when text is not JSON.
final class PyJsonDecodeError extends ValueError {
  const PyJsonDecodeError(super.message);

  @override
  String get pyType => 'json.decoder.JSONDecodeError';
}

/// Python `KeyError`; [message] is the Python `str()` of the exception.
final class PyKeyError extends PyException {
  const PyKeyError(super.message);

  @override
  String get pyType => 'builtins.KeyError';
}

/// Extension point for module-specific Python exception classes.
base class PyCustomException extends PyException {
  const PyCustomException(super.message, this.pyType);

  @override
  final String pyType;
}
