/// What the engine is doing right now.
///
/// The engine exposes this through a `ValueListenable<SyncState>`, so a status
/// indicator is one `ValueListenableBuilder` away in Flutter.
sealed class SyncState {
  /// Creates a sync state.
  const SyncState();

  /// Whether a sync is currently in flight.
  bool get isBusy => this is Syncing;

  /// Whether the engine can reach the backend.
  bool get isOnline => this is! Offline;

  /// A short human-readable label, handy for a status line or a tooltip.
  String get label => switch (this) {
        Idle() => 'Up to date',
        Syncing(:final phase) => phase.label,
        Offline() => 'Offline',
        Failed(:final error) => 'Sync failed: $error',
        Stopped() => 'Paused',
      };
}

/// Nothing to do; the last sync succeeded (or none has run yet).
class Idle extends SyncState {
  /// Creates an idle state.
  const Idle({this.lastSyncedAt});

  /// When the last fully successful sync finished.
  final DateTime? lastSyncedAt;
}

/// A sync is in flight.
class Syncing extends SyncState {
  /// Creates a syncing state.
  const Syncing({
    this.phase = SyncPhase.pushing,
    this.completed = 0,
    this.total,
  });

  /// Which half of the cycle is running.
  final SyncPhase phase;

  /// Records handled so far in this phase.
  final int completed;

  /// Records expected in this phase, when known.
  final int? total;

  /// Progress in the range 0..1, or null when the total is unknown.
  double? get progress {
    final t = total;
    if (t == null || t == 0) return null;
    return (completed / t).clamp(0.0, 1.0);
  }
}

/// The engine is running but the device is offline.
class Offline extends SyncState {
  /// Creates an offline state.
  const Offline({this.pendingChanges = 0});

  /// How many local changes are waiting for connectivity.
  final int pendingChanges;
}

/// The last sync failed and the engine is waiting to retry.
class Failed extends SyncState {
  /// Creates a failed state.
  const Failed({
    required this.error,
    this.attempt = 1,
    this.retryIn,
  });

  /// The error that caused the failure.
  final Object error;

  /// Which attempt failed, starting at 1.
  final int attempt;

  /// How long until the next attempt, when one is scheduled.
  final Duration? retryIn;
}

/// The engine has been stopped by the caller.
class Stopped extends SyncState {
  /// Creates a stopped state.
  const Stopped();
}

/// The phases of a sync cycle.
enum SyncPhase {
  /// Uploading local changes.
  pushing,

  /// Downloading remote changes.
  pulling,

  /// Writing remote changes into the local store.
  applying;

  /// A short label for this phase.
  String get label => switch (this) {
        SyncPhase.pushing => 'Uploading changes...',
        SyncPhase.pulling => 'Downloading changes...',
        SyncPhase.applying => 'Applying changes...',
      };
}

/// Counters describing what the engine has done.
///
/// [SyncStats] is a snapshot: read it from the engine after a sync, or
/// accumulate deltas from the event stream.
class SyncStats {
  /// Creates a stats snapshot.
  const SyncStats({
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.deletions = 0,
    this.failures = 0,
    this.lastSyncedAt,
    this.lastDuration,
  });

  /// Records accepted by the backend.
  final int pushed;

  /// Records received from the backend.
  final int pulled;

  /// Conflicts detected.
  final int conflicts;

  /// Tombstones pushed.
  final int deletions;

  /// Failed attempts.
  final int failures;

  /// When the last successful sync finished.
  final DateTime? lastSyncedAt;

  /// How long the last successful sync took.
  final Duration? lastDuration;

  /// A copy with selected fields replaced.
  SyncStats copyWith({
    int? pushed,
    int? pulled,
    int? conflicts,
    int? deletions,
    int? failures,
    DateTime? lastSyncedAt,
    Duration? lastDuration,
  }) {
    return SyncStats(
      pushed: pushed ?? this.pushed,
      pulled: pulled ?? this.pulled,
      conflicts: conflicts ?? this.conflicts,
      deletions: deletions ?? this.deletions,
      failures: failures ?? this.failures,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastDuration: lastDuration ?? this.lastDuration,
    );
  }

  @override
  String toString() => 'SyncStats(pushed: $pushed, pulled: $pulled, '
      'conflicts: $conflicts, failures: $failures)';
}
