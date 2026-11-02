import 'dart:math' as math;

/// Controls how the engine waits between retries after a failed sync.
///
/// Retries use exponential backoff with jitter by default. Jitter matters at
/// scale: without it, every device that lost connectivity during the same
/// outage retries in lockstep and stampedes the backend the moment it returns.
class RetryPolicy {
  /// Creates a retry policy.
  const RetryPolicy({
    this.maxAttempts = 6,
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
    this.multiplier = 2.0,
    this.jitter = 0.25,
    this.retryOn = const {},
  });

  /// A policy that never retries, useful in tests and for one-shot syncs.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  /// How many times a single batch is attempted before the engine gives up
  /// and surfaces the failure. Set to 1 to disable retrying.
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Ceiling for the computed delay.
  final Duration maxDelay;

  /// Growth factor applied per attempt.
  final double multiplier;

  /// Random spread applied to each delay, as a fraction of the delay.
  /// `0.25` means the delay lands within 25 percent of the computed value.
  final double jitter;

  /// Error types that should be retried. When empty, every error is retried
  /// except those the transport explicitly marks as permanent.
  final Set<Type> retryOn;

  /// Whether [error] warrants another attempt.
  bool shouldRetry(Object error, int attempt) {
    if (attempt >= maxAttempts) return false;
    if (retryOn.isNotEmpty) {
      return retryOn.any((type) => error.runtimeType == type);
    }
    return true;
  }

  /// The delay before attempt number [attempt] (0-based).
  ///
  /// Pass [random] to make the jitter reproducible in tests.
  Duration delayFor(int attempt, {math.Random? random}) {
    if (attempt <= 0) return Duration.zero;

    final base =
        initialDelay.inMicroseconds * math.pow(multiplier, attempt - 1).toDouble();
    final capped = math.min(base, maxDelay.inMicroseconds.toDouble());

    if (jitter <= 0) return Duration(microseconds: capped.round());

    final rng = random ?? math.Random();
    final spread = capped * jitter;
    final offset = (rng.nextDouble() * 2 - 1) * spread;
    final value = (capped + offset).clamp(0, maxDelay.inMicroseconds.toDouble());
    return Duration(microseconds: value.round());
  }

  /// A copy with selected fields replaced.
  RetryPolicy copyWith({
    int? maxAttempts,
    Duration? initialDelay,
    Duration? maxDelay,
    double? multiplier,
    double? jitter,
    Set<Type>? retryOn,
  }) {
    return RetryPolicy(
      maxAttempts: maxAttempts ?? this.maxAttempts,
      initialDelay: initialDelay ?? this.initialDelay,
      maxDelay: maxDelay ?? this.maxDelay,
      multiplier: multiplier ?? this.multiplier,
      jitter: jitter ?? this.jitter,
      retryOn: retryOn ?? this.retryOn,
    );
  }
}
