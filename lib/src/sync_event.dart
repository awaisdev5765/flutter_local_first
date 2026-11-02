import 'conflict.dart';
import 'sync_record.dart';
import 'sync_state.dart';

/// Something the engine did, for logging, analytics or a debug console.
///
/// Events are a stream, so you can log them, count them, or render them in a
/// developer screen without touching the engine's internals.
///
/// ```dart
/// engine.events.listen((event) => debugPrint('[sync] $event'));
/// ```
sealed class SyncEvent {
  /// Creates an event.
  const SyncEvent();

  /// When the event happened.
  DateTime get timestamp;
}

/// A sync cycle began.
class SyncStarted extends SyncEvent {
  /// Creates a started event.
  const SyncStarted({required this.timestamp, this.pendingCount = 0});

  @override
  final DateTime timestamp;

  /// Local changes waiting to be pushed when the cycle started.
  final int pendingCount;
}

/// A sync cycle finished successfully.
class SyncCompleted extends SyncEvent {
  /// Creates a completed event.
  const SyncCompleted({
    required this.timestamp,
    required this.stats,
    required this.duration,
  });

  @override
  final DateTime timestamp;

  /// Cumulative stats after this cycle.
  final SyncStats stats;

  /// How long the cycle took.
  final Duration duration;
}

/// A sync cycle failed; a retry may be scheduled.
class SyncFailed extends SyncEvent {
  /// Creates a failed event.
  const SyncFailed({
    required this.timestamp,
    required this.error,
    required this.attempt,
    this.retryIn,
  });

  @override
  final DateTime timestamp;

  /// The error.
  final Object error;

  /// Which attempt failed.
  final int attempt;

  /// When the next attempt is due, if any.
  final Duration? retryIn;
}

/// Records were accepted by the backend.
class RecordsPushed extends SyncEvent {
  /// Creates a pushed event.
  const RecordsPushed({
    required this.timestamp,
    required this.ids,
    required this.rejected,
  });

  @override
  final DateTime timestamp;

  /// Ids the backend accepted.
  final List<String> ids;

  /// Ids the backend refused, with reasons.
  final Map<String, String> rejected;
}

/// Records arrived from the backend and were written locally.
class RecordsPulled extends SyncEvent {
  /// Creates a pulled event.
  const RecordsPulled({required this.timestamp, required this.ids});

  @override
  final DateTime timestamp;

  /// Ids written into the local store.
  final List<String> ids;
}

/// A record changed on both sides and was settled by policy.
class ConflictResolved extends SyncEvent {
  /// Creates a conflict event.
  const ConflictResolved({required this.timestamp, required this.conflict});

  @override
  final DateTime timestamp;

  /// The conflict and how it was settled.
  final Conflict conflict;
}

/// A local record was written as the result of a pull or a conflict.
class LocalRecordChanged extends SyncEvent {
  /// Creates a local change event.
  const LocalRecordChanged({
    required this.timestamp,
    required this.record,
    required this.reason,
  });

  @override
  final DateTime timestamp;

  /// The record as it now stands locally.
  final SyncDocument record;

  /// Why it changed.
  final LocalChangeReason reason;
}

/// Why a local record changed outside of a direct user write.
enum LocalChangeReason {
  /// It arrived from the backend.
  pulled,

  /// The backend's version won a conflict.
  conflictRemoteWon,

  /// A custom resolver produced a merged version.
  conflictMerged,

  /// A local change was acknowledged by the backend.
  pushed,
}

/// Connectivity changed.
class ConnectivityChanged extends SyncEvent {
  /// Creates a connectivity event.
  const ConnectivityChanged({required this.timestamp, required this.online});

  @override
  final DateTime timestamp;

  /// Whether the backend is now reachable.
  final bool online;
}

/// Tombstones older than the configured TTL were removed.
class TombstonesPurged extends SyncEvent {
  /// Creates a purge event.
  const TombstonesPurged({required this.timestamp, required this.count});

  @override
  final DateTime timestamp;

  /// How many tombstones were removed.
  final int count;
}
