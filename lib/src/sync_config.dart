import 'backoff.dart';
import 'conflict.dart';

/// How the engine should behave: batching, conflict policy, retry and timers.
///
/// Every field has a sensible default, so `const SyncConfig()` is a reasonable
/// starting point and you only override what matters to your app.
class SyncConfig {
  /// Creates a sync configuration.
  const SyncConfig({
    this.pushBatchSize = 100,
    this.pullBatchSize = 200,
    this.maxPullPages = 20,
    this.conflictPolicy = ConflictPolicy.lastWriteWins,
    this.conflictResolver,
    this.retryPolicy = const RetryPolicy(),
    this.syncInterval = const Duration(minutes: 5),
    this.syncOnStart = true,
    this.syncOnReconnect = true,
    this.tombstoneTtl = const Duration(days: 90),
    this.requireConnectivity = true,
    this.deviceId,
  });

  /// Maximum number of records sent in a single push.
  final int pushBatchSize;

  /// Maximum number of records requested in a single pull page.
  final int pullBatchSize;

  /// Safety valve: the most pages a single sync will pull before yielding.
  /// Prevents an unbounded first sync from monopolising the isolate.
  final int maxPullPages;

  /// How conflicts are settled. See [ConflictPolicy].
  final ConflictPolicy conflictPolicy;

  /// A custom merge function. When provided it wins over [conflictPolicy] for
  /// every pair it is asked to resolve.
  final ConflictResolver? conflictResolver;

  /// Retry behaviour after failures.
  final RetryPolicy retryPolicy;

  /// How often the engine pushes and pulls while running.
  final Duration syncInterval;

  /// Whether `LocalFirstSync.start` performs an immediate sync.
  final bool syncOnStart;

  /// Whether to sync as soon as connectivity returns.
  final bool syncOnReconnect;

  /// How long tombstones are kept locally before being purged. They must
  /// outlive the longest plausible offline period of any device.
  final Duration tombstoneTtl;

  /// Whether syncs are skipped entirely while offline.
  ///
  /// Leave this true. Setting it false is only useful when your
  /// `ConnectivityMonitor` reports the server rather than the device, or when
  /// you are running against a local backend that is always reachable.
  final bool requireConnectivity;

  /// Identifies this device in diagnostics and conflict reports.
  final String? deviceId;

  /// A copy with selected fields replaced.
  SyncConfig copyWith({
    int? pushBatchSize,
    int? pullBatchSize,
    int? maxPullPages,
    ConflictPolicy? conflictPolicy,
    ConflictResolver? conflictResolver,
    RetryPolicy? retryPolicy,
    Duration? syncInterval,
    bool? syncOnStart,
    bool? syncOnReconnect,
    Duration? tombstoneTtl,
    bool? requireConnectivity,
    String? deviceId,
  }) {
    return SyncConfig(
      pushBatchSize: pushBatchSize ?? this.pushBatchSize,
      pullBatchSize: pullBatchSize ?? this.pullBatchSize,
      maxPullPages: maxPullPages ?? this.maxPullPages,
      conflictPolicy: conflictPolicy ?? this.conflictPolicy,
      conflictResolver: conflictResolver ?? this.conflictResolver,
      retryPolicy: retryPolicy ?? this.retryPolicy,
      syncInterval: syncInterval ?? this.syncInterval,
      syncOnStart: syncOnStart ?? this.syncOnStart,
      syncOnReconnect: syncOnReconnect ?? this.syncOnReconnect,
      tombstoneTtl: tombstoneTtl ?? this.tombstoneTtl,
      requireConnectivity: requireConnectivity ?? this.requireConnectivity,
      deviceId: deviceId ?? this.deviceId,
    );
  }
}
