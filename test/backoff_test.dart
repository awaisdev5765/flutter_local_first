import 'dart:math' as math;

import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  group('RetryPolicy', () {
    const policy = RetryPolicy(
      maxAttempts: 5,
      initialDelay: Duration(seconds: 2),
      maxDelay: Duration(seconds: 30),
      multiplier: 2,
      jitter: 0,
    );

    test('no delay before the first attempt', () {
      expect(policy.delayFor(0), Duration.zero);
    });

    test('grows exponentially', () {
      expect(policy.delayFor(1), const Duration(seconds: 2));
      expect(policy.delayFor(2), const Duration(seconds: 4));
      expect(policy.delayFor(3), const Duration(seconds: 8));
      expect(policy.delayFor(4), const Duration(seconds: 16));
    });

    test('never exceeds maxDelay', () {
      expect(policy.delayFor(10), const Duration(seconds: 30));
    });

    test('jitter stays within the configured spread', () {
      const jittery = RetryPolicy(
        initialDelay: Duration(seconds: 10),
        jitter: 0.25,
        multiplier: 1,
      );
      final random = math.Random(42);
      for (var i = 0; i < 50; i++) {
        final delay = jittery.delayFor(1, random: random);
        expect(delay.inMilliseconds, greaterThanOrEqualTo(7500));
        expect(delay.inMilliseconds, lessThanOrEqualTo(12500));
      }
    });

    test('jittered delays differ across calls', () {
      const jittery = RetryPolicy(
        initialDelay: Duration(seconds: 10),
        jitter: 0.5,
        multiplier: 1,
      );
      final random = math.Random(7);
      final seen = <int>{};
      for (var i = 0; i < 20; i++) {
        seen.add(jittery.delayFor(1, random: random).inMilliseconds);
      }
      expect(seen.length, greaterThan(1));
    });

    test('shouldRetry stops at maxAttempts', () {
      expect(policy.shouldRetry(Exception('x'), 1), isTrue);
      expect(policy.shouldRetry(Exception('x'), 4), isTrue);
      expect(policy.shouldRetry(Exception('x'), 5), isFalse);
      expect(policy.shouldRetry(Exception('x'), 99), isFalse);
    });

    test('retryOn narrows retries to specific error types', () {
      final typed = policy.copyWith(retryOn: {RemoteUnavailable});
      expect(typed.shouldRetry(const RemoteUnavailable(), 1), isTrue);
      expect(typed.shouldRetry(StateError('nope'), 1), isFalse);
    });

    test('none disables retrying', () {
      expect(RetryPolicy.none.maxAttempts, 1);
      expect(RetryPolicy.none.shouldRetry(Exception('x'), 1), isFalse);
    });

    test('copyWith replaces only the named fields', () {
      final changed = policy.copyWith(maxAttempts: 9);
      expect(changed.maxAttempts, 9);
      expect(changed.initialDelay, policy.initialDelay);
      expect(changed.jitter, policy.jitter);
    });
  });
}
