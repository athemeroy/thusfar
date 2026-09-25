/// Wall and monotonic time are supplied by the caller, including in tests.
abstract interface class ClockSource {
  double wallSeconds();

  double monotonicSeconds();
}

/// Jitter and sampling are supplied by the caller, including in tests.
abstract interface class RandomSource {
  double nextUnit();
}
