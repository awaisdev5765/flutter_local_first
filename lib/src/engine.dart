import 'dart:async';
import 'dart:math' as math;

import 'attachments.dart';
import 'conflict.dart';
import 'connectivity.dart';
import 'local_store.dart';
import 'remote_store.dart';
import 'sync_config.dart';
import 'sync_event.dart';
import 'sync_record.dart';
import 'sync_state.dart';

/// A complete sync cycle's outcome.
class SyncOutcome {
  /// Creates a sync outcome.
  const SyncOutcome({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.failures,
    required this.duration,
    this.skippedBecauseOffline = false,
  });

  /// Records accepted by the backend.
  final int pushed;

  /// Records received from the backend.
  final int pulled;

  /// Conflicts detected and settled.
  final int conflicts;

  /// Failed batches.
  final int failures;

  /// How long the cycle took.
  final Duration duration;

  /// Whether the cycle was skipped because the device was offline.
  final bool skippedBecauseOffline;

  /// Whether the cycle changed anything.
  bool get didWork => pushed > 0 || pulled > 0;

  @override
  String toString() => skippedBecauseOffline
      ? 'SyncOutcome(offline)'
      : 'SyncOutcome(pushed: $pushed, pulled: $pulled, '
          'conflicts: $conflicts, failed: $failures, '
          'in ${duration.inMilliseconds}ms)';
}

/// A local-first sync engine.
///
/// Offline-first writes with eventual consistency: users write to the local
/// store and the UI updates immediately; the engine drains those changes to
/// your backend in the background, pulls whatever other devices wrote, and
/// settles conflicts.
///
/// ## The cycle
///
/// 1. **Push** — pending local changes are uploaded in batches. Accepted
///    records are marked synced; rejected ones stay pending so no edit is lost.
/// 2. **Pull** — everything newer than the stored cursor is fetched, paged, and
///    written into the local store.
/// 3. **Resolve** — a record changed on both sides is settled by
///    [ConflictPolicy], or your [SyncConfig.conflictResolver], and reported
///    through [events].
///
/// Pushing before pulling is deliberate: the cursor the engine advances to
/// already includes the server's acknowledgements, so a record this device just
/// wrote is not immediately pulled back.
///
/// ## Guarantees
///
/// - **No lost edits.** A record stays pending until the backend accepts it.
/// - **No duplicates.** Records are keyed by [SyncRecord.id] and pushes are
///   idempotent, so retries and reinstalls are safe.
/// - **No resurrection.** Deletions travel as tombstones and are only purged
///   after [SyncConfig.tombstoneTtl].
/// - **No clock trust.** Pull cursors come from the backend's clock, never from
///   a device.
class LocalFirstSync {
  /// Creates a sync engine.
  LocalFirstSync({
    required this.store,
    required this.remote,
    this.config = const SyncConfig(),
    ConnectivityMonitor? connectivity,
    this.attachments,
    DateTime Function()? clock,
  })  : connectivity = connectivity ?? const AlwaysOnlineMonitor(),
        _clock = clock ?? (() => DateTime.now().toUtc());

  /// Local persistence.
  final LocalStore store;

  /// The backend.
  final RemoteStore remote;

  /// Behaviour configuration.
  final SyncConfig config;

  /// Supplies the online/offline signal.
  final ConnectivityMonitor connectivity;

  /// Optional attachment queue, synced alongside records.
  final AttachmentQueue? attachments;

  final DateTime Function() _clock;

  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();

  final _SyncValueNotifier<SyncState> _state =
      _SyncValueNotifier<SyncState>(const Idle());

  Timer? _periodicTimer;
  Timer? _retryTimer;
  Timer? _debounceTimer;
  StreamSubscription<void>? _changeSubscription;
  StreamSubscription<bool>? _connectivitySubscription;

  bool _running = false;
  bool _syncing = false;
  Future<SyncOutcome>? _inFlight;
  int _consecutiveFailures = 0;

  SyncStats _stats = const SyncStats();
  DateTime? _cursor;
  final List<Object> _history = [];

  /// The current state. Listen to it to drive a status indicator.
  ValueListenable<SyncState> get state => _state;

  /// A stream of everything the engine does.
  Stream<SyncEvent> get events => _events.stream;

  /// Cumulative counters from completed cycles.
  SyncStats get stats => _stats;

  /// The backend-clock cursor used for pulls. Null until the first sync.
  DateTime? get cursor => _cursor;

  /// Whether the engine is started and syncing periodically.
  bool get isRunning => _running;

  /// Whether a sync is in flight right now.
  bool get isSyncing => _syncing;

  /// Errors from the last few cycles, newest last. Capped at 20.
  List<Object> get recentErrors => List.unmodifiable(_history);

  /// How many local changes are waiting to be pushed.
  Future<int> pendingCount() async =>
      (await store.pendingChanges(limit: 100000)).length;

  /// Starts the engine: subscribes to connectivity and local changes, syncs
  /// immediately when [SyncConfig.syncOnStart] is set, then every
  /// [SyncConfig.syncInterval].
  ///
  /// Calling [start] twice is safe.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _state.value = const Idle();

    _connectivitySubscription = connectivity.changes.listen((online) {
      _emit(ConnectivityChanged(timestamp: _clock(), online: online));
      if (online) {
        if (config.syncOnReconnect) unawaited(sync());
      } else {
        unawaited(_reflectOffline());
      }
    });

    _changeSubscription = store.changes.listen((_) {
      // Local writes should reach the backend promptly rather than waiting for
      // the poll interval, but without stampeding: a debounce folds a burst of
      // edits into one cycle.
      _debounceSync();
    });

    if (!connectivity.isOnline && config.requireConnectivity) {
      await _reflectOffline();
    } else if (config.syncOnStart) {
      unawaited(sync());
    }

    _periodicTimer = Timer.periodic(config.syncInterval, (_) {
      unawaited(sync());
    });
  }

  /// Stops the engine and cancels its timers and subscriptions.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _changeSubscription?.cancel();
    _changeSubscription = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _state.value = const Stopped();
  }

  /// Releases every resource, including the connectivity monitor.
  ///
  /// The engine cannot be restarted afterwards. Use this in `dispose`.
  Future<void> dispose() async {
    await stop();
    await connectivity.dispose();
    await _events.close();
    _state.dispose();
  }

  void _debounceSync() {
    if (!_running || _debounceTimer != null) return;
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      _debounceTimer = null;
      unawaited(sync());
    });
  }

  /// Runs one full sync cycle.
  ///
  /// Concurrent calls share a single cycle: the second caller receives the
  /// first caller's future rather than starting a competing sync.
  Future<SyncOutcome> sync() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _runCycle();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<SyncOutcome> _runCycle() async {
    final stopwatch = Stopwatch()..start();

    if (config.requireConnectivity && !connectivity.isOnline) {
      await _reflectOffline();
      return SyncOutcome(
        pushed: 0,
        pulled: 0,
        conflicts: 0,
        failures: 0,
        duration: stopwatch.elapsed,
        skippedBecauseOffline: true,
      );
    }

    _syncing = true;
    final pending = await pendingCount();
    _emit(SyncStarted(timestamp: _clock(), pendingCount: pending));
    _state.value = const Syncing(phase: SyncPhase.pushing);

    var pushed = 0;
    var pulled = 0;
    var conflicts = 0;
    var failures = 0;

    try {
      final pushOutcome = await _pushAll();
      pushed = pushOutcome.pushed;
      conflicts += pushOutcome.conflicts;
      failures += pushOutcome.failures;

      _state.value = const Syncing(phase: SyncPhase.pulling);
      final pullOutcome = await _pullAll();
      pulled = pullOutcome.pulled;
      conflicts += pullOutcome.conflicts;
      failures += pullOutcome.failures;

      stopwatch.stop();
      _consecutiveFailures = 0;
      _stats = _stats.copyWith(
        pushed: _stats.pushed + pushed,
        pulled: _stats.pulled + pulled,
        conflicts: _stats.conflicts + conflicts,
        failures: _stats.failures + failures,
        lastSyncedAt: _clock(),
        lastDuration: stopwatch.elapsed,
      );

      _emit(SyncCompleted(
        timestamp: _clock(),
        stats: _stats,
        duration: stopwatch.elapsed,
      ));
      _state.value = Idle(lastSyncedAt: _stats.lastSyncedAt);

      return SyncOutcome(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        failures: failures,
        duration: stopwatch.elapsed,
      );
    } on Object catch (error) {
      stopwatch.stop();
      _consecutiveFailures++;
      _history.add(error);
      if (_history.length > 20) _history.removeAt(0);
      _stats = _stats.copyWith(failures: _stats.failures + 1);

      final retryIn = config.retryPolicy.shouldRetry(error, _consecutiveFailures)
          ? config.retryPolicy.delayFor(_consecutiveFailures)
          : null;

      _emit(SyncFailed(
        timestamp: _clock(),
        error: error,
        attempt: _consecutiveFailures,
        retryIn: retryIn,
      ));
      _state.value = Failed(
        error: error,
        attempt: _consecutiveFailures,
        retryIn: retryIn,
      );

      if (retryIn != null) {
        _retryTimer?.cancel();
        _retryTimer = Timer(retryIn, () {
          if (_running) unawaited(sync());
        });
      }

      return SyncOutcome(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        failures: failures + 1,
        duration: stopwatch.elapsed,
      );
    } finally {
      _syncing = false;
    }
  }

  // ── Push ───────────────────────────────────────────────────────────────────

  Future<_PhaseOutcome> _pushAll() async {
    var pushed = 0;
    var conflicts = 0;
    var failures = 0;
    var total = 0;

    // Ids already attempted this cycle. A record stays pending until the backend
    // acknowledges it, so without this guard a record that is accepted but
    // concurrently re-edited could keep the loop running forever.
    final attempted = <String>{};

    while (true) {
      final batch = (await store.pendingChanges(limit: config.pushBatchSize))
          .where((d) => !attempted.contains(d.id))
          .toList();
      if (batch.isEmpty) break;
      attempted.addAll(batch.map((d) => d.id));

      total += batch.length;
      _state.value =
          Syncing(phase: SyncPhase.pushing, completed: pushed, total: total);

      // Settle conflicts before uploading: sending a stale copy would make the
      // backend's version look newer for no reason.
      final settled = await _settleConflicts(batch);
      conflicts += settled.conflicts;

      if (settled.documents.isEmpty) continue;

      final result = await remote.push(settled.documents);
      pushed += result.accepted.length;

      if (result.accepted.isNotEmpty) {
        await store.markSynced(result.accepted, _clock());
      }

      _emit(RecordsPushed(
        timestamp: _clock(),
        ids: result.accepted,
        rejected: result.rejected,
      ));

      // A rejection is permanent for this payload: leave it pending so the
      // user's data survives, but stop looping on it.
      if (result.rejected.isNotEmpty) {
        failures += result.rejected.length;
        break;
      }
      if (result.accepted.isEmpty) break;
    }

    return _PhaseOutcome(
      pushed: pushed,
      conflicts: conflicts,
      failures: failures,
    );
  }

  Future<_SettledBatch> _settleConflicts(List<SyncDocument> batch) async {
    final out = <SyncDocument>[];
    var conflicts = 0;

    final remoteVersions =
        await _fetchRemoteVersions(batch.map((d) => d.id).toList());

    for (final local in batch) {
      final remoteDocument = remoteVersions[local.id];
      if (remoteDocument == null) {
        // Never seen by the backend: a plain insert.
        out.add(local);
        continue;
      }

      // The backend only knows the version we already pushed.
      if (!local.hasPendingChanges) continue;

      final resolution = _resolutionFor(local, remoteDocument);

      if (resolution == ConflictResolution.identical) {
        out.add(local);
        continue;
      }

      conflicts++;
      _emit(ConflictResolved(
        timestamp: _clock(),
        conflict: Conflict(
          id: local.id,
          local: local,
          remote: remoteDocument,
          resolution: resolution,
        ),
      ));

      if (resolution.requiresLocalUpdate) {
        final resolved = _applyResolution(local, remoteDocument, resolution);
        await store.upsert(resolved);
        _emit(LocalRecordChanged(
          timestamp: _clock(),
          record: resolved,
          reason: resolution == ConflictResolution.merged
              ? LocalChangeReason.conflictMerged
              : LocalChangeReason.conflictRemoteWon,
        ));
        // The remote version wins locally; do not push it back.
        continue;
      }

      out.add(_applyResolution(local, remoteDocument, resolution));
    }

    return _SettledBatch(documents: out, conflicts: conflicts);
  }

  /// Decides how a local/remote pair should be settled.
  ///
  /// A [SyncConfig.conflictResolver] always wins: if you wrote a merge function
  /// you meant it, and letting the policy short-circuit it would silently
  /// discard half of every conflict.
  ConflictResolution _resolutionFor(SyncDocument local, SyncDocument remote) {
    if (config.conflictPolicy == ConflictPolicy.manual) {
      return ConflictResolution.deferred;
    }
    if (config.conflictResolver != null) return ConflictResolution.merged;
    return resolveConflict(
      config.conflictPolicy,
      local: local,
      remote: remote,
    );
  }

  SyncDocument _applyResolution(
    SyncDocument local,
    SyncDocument remote,
    ConflictResolution resolution,
  ) {
    final custom = config.conflictResolver;
    if (custom != null) return custom(local, remote);
    if (resolution == ConflictResolution.remoteWon) return remote;
    if (resolution == ConflictResolution.localWon) return local;
    return winnerFor(config.conflictPolicy, local: local, remote: remote);
  }

  /// Asks the backend for the current version of each id.
  Future<Map<String, SyncDocument>> _fetchRemoteVersions(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};

    // Preferred path: one round trip for every id in the batch.
    final remoteStore = remote;
    if (remoteStore is BatchRemoteStore) {
      return remoteStore.getMany(ids);
    }

    // Fallback: page through recent changes. Correct for any RemoteStore, at
    // the cost of more I/O.
    final wanted = ids.toSet();
    final found = <String, SyncDocument>{};
    String? cursor;
    var pages = 0;

    while (pages < config.maxPullPages && found.length < wanted.length) {
      final page = await remote.pull(
        limit: math.max(config.pullBatchSize, wanted.length),
        cursor: cursor,
      );
      for (final record in page.records) {
        if (wanted.contains(record.id)) found[record.id] = record;
      }
      if (!page.hasMore || page.cursor == null) break;
      cursor = page.cursor;
      pages++;
    }
    return found;
  }

  // ── Pull ───────────────────────────────────────────────────────────────────

  Future<_PhaseOutcome> _pullAll() async {
    var pulled = 0;
    var conflicts = 0;

    String? cursor;
    var pages = 0;

    while (pages < config.maxPullPages) {
      final page = await remote.pull(
        since: _cursor,
        limit: config.pullBatchSize,
        cursor: cursor,
      );

      if (page.records.isNotEmpty) {
        _state.value = Syncing(phase: SyncPhase.applying, completed: pulled);
        final applied = await _applyPulled(page.records);
        pulled += applied.pulled;
        conflicts += applied.conflicts;
      }

      // The cursor always comes from the server's clock. If it did not move,
      // stop rather than looping on the same page forever.
      final advanced = _cursor == null || page.serverTime.isAfter(_cursor!);
      if (advanced) _cursor = page.serverTime;

      if (!page.hasMore || page.cursor == null || !advanced) break;
      cursor = page.cursor;
      pages++;
    }

    return _PhaseOutcome(pulled: pulled, conflicts: conflicts);
  }

  Future<_PhaseOutcome> _applyPulled(List<SyncDocument> records) async {
    var pulled = 0;
    var conflicts = 0;
    final toWrite = <SyncDocument>[];

    for (final remoteDocument in records) {
      final local = await store.byId(remoteDocument.id);
      if (local == null) {
        // New to this device.
        toWrite.add(_fromRemote(remoteDocument));
        pulled++;
        continue;
      }

      // Already up to date — comparing the payload avoids a pointless write.
      if (_sameOrNewer(local, remoteDocument)) continue;

      if (!local.hasPendingChanges) {
        // No local edits in flight: the remote version is simply newer.
        toWrite.add(_fromRemote(remoteDocument));
        pulled++;
        continue;
      }

      // Both sides changed: settle it with the same policy used on push, so the
      // outcome does not depend on which direction the sync ran first.
      conflicts++;
      final resolution = _resolutionFor(local, remoteDocument);

      _emit(ConflictResolved(
        timestamp: _clock(),
        conflict: Conflict(
          id: local.id,
          local: local,
          remote: remoteDocument,
          resolution: resolution,
        ),
      ));

      switch (resolution) {
        case ConflictResolution.localWon:
        case ConflictResolution.deferred:
          // Keep it pending so the next push uploads it.
          continue;
        case ConflictResolution.remoteWon:
          toWrite.add(_fromRemote(remoteDocument));
        case ConflictResolution.merged:
          final resolved = _applyResolution(
            local,
            remoteDocument,
            ConflictResolution.merged,
          );
          toWrite.add(_fromRemote(resolved));
        case ConflictResolution.identical:
          continue;
      }
      pulled++;
    }

    if (toWrite.isNotEmpty) {
      await store.upsertAll(toWrite);
      for (final record in toWrite) {
        _emit(LocalRecordChanged(
          timestamp: _clock(),
          record: record,
          reason: LocalChangeReason.pulled,
        ));
      }
      _emit(RecordsPulled(
        timestamp: _clock(),
        ids: toWrite.map((d) => d.id).toList(),
      ));

      final queue = attachments;
      if (queue != null) {
        for (final record in toWrite.where((d) => d.isDeleted)) {
          await queue.removeForRecord(record.id);
        }
      }
    }

    return _PhaseOutcome(pulled: pulled, conflicts: conflicts);
  }

  /// Marks a remote record as acknowledged locally: it carries no pending
  /// changes as far as this device is concerned.
  SyncDocument _fromRemote(SyncDocument remoteDocument) => SyncDocument(
        id: remoteDocument.id,
        data: remoteDocument.data,
        updatedAt: remoteDocument.updatedAt,
        deletedAt: remoteDocument.deletedAt,
        revision: remoteDocument.revision,
        syncedAt: remoteDocument.updatedAt,
      );

  bool _sameOrNewer(SyncDocument local, SyncDocument remote) {
    if (!sameContent(local, remote)) return false;
    return !remote.updatedAt.isAfter(local.updatedAt);
  }

  // ── Local writes ───────────────────────────────────────────────────────────

  /// Writes a record locally and schedules a sync.
  ///
  /// The write is durable the moment this future completes — the UI can render
  /// immediately and never has to wait for the network.
  Future<void> write(SyncDocument document) async {
    await store.upsert(document);
    if (_running) _debounceSync();
  }

  /// Writes several records in one batch.
  Future<void> writeAll(Iterable<SyncDocument> documents) async {
    await store.upsertAll(documents);
    if (_running) _debounceSync();
  }

  /// Records a deletion as a tombstone and schedules a sync.
  ///
  /// Never hard-delete locally: the tombstone is what stops another device from
  /// resurrecting the record.
  Future<void> delete(String id, {DateTime? at}) async {
    final existing = await store.byId(id);
    final stamp = at ?? _clock();
    final tombstone = existing?.tombstone(stamp) ??
        SyncDocument(id: id, updatedAt: stamp, deletedAt: stamp, revision: 1);
    await store.upsert(tombstone);

    final queue = attachments;
    if (queue != null) await queue.removeForRecord(id);

    if (_running) _debounceSync();
  }

  /// Removes local tombstones older than [SyncConfig.tombstoneTtl] and asks the
  /// backend to do the same.
  ///
  /// Only call this once every device is expected to have synced within the
  /// TTL, otherwise a long-offline device could resurrect deleted records.
  Future<int> purgeTombstones() async {
    final cutoff = _clock().subtract(config.tombstoneTtl);
    final local = await store.purgeTombstones(cutoff);
    final remotePurged = await remote.purgeTombstones(cutoff);
    final total = local + remotePurged;
    if (total > 0) {
      _emit(TombstonesPurged(timestamp: _clock(), count: total));
    }
    return total;
  }

  /// Performs a full resync by forgetting the pull cursor.
  ///
  /// Useful after a reinstall or a schema change. The next sync re-pulls the
  /// whole remote history, so expect it to be slower than a normal cycle.
  void resetCursor() {
    _cursor = null;
  }

  Future<void> _reflectOffline() async {
    final pending = await pendingCount();
    _state.value = Offline(pendingChanges: pending);
  }

  void _emit(SyncEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Minimal `ValueListenable` so the package needs no Flutter dependency.
///
/// Flutter's `ValueNotifier` implements the same shape, so the engine works
/// unchanged in a Flutter app — `ValueListenableBuilder` accepts it.
abstract interface class ValueListenable<T> {
  /// The current value.
  T get value;

  /// Registers [listener], which is called whenever the value changes.
  void addListener(void Function() listener);

  /// Unregisters a listener.
  void removeListener(void Function() listener);
}

class _SyncValueNotifier<T> implements ValueListenable<T> {
  _SyncValueNotifier(this._value);

  T _value;
  final List<void Function()> _listeners = [];
  bool _disposed = false;

  @override
  T get value => _value;

  set value(T next) {
    if (_disposed || next == _value) return;
    _value = next;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}

class _PhaseOutcome {
  const _PhaseOutcome({
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.failures = 0,
  });

  final int pushed;
  final int pulled;
  final int conflicts;
  final int failures;
}

class _SettledBatch {
  const _SettledBatch({required this.documents, required this.conflicts});

  final List<SyncDocument> documents;
  final int conflicts;
}
