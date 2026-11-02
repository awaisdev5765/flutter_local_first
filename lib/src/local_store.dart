import 'dart:async';

import 'sync_record.dart';

/// The contract the engine needs from your local persistence layer.
///
/// The engine deliberately knows nothing about SQLite, Hive, Isar or Drift.
/// Implement this interface over whatever you already use — the engine only
/// asks for pending changes, changed records, and a way to mark a record as
/// synced.
///
/// For SQLite the whole interface maps to five queries, for example:
///
/// ```sql
/// -- pendingChanges(): records with unsynced edits or deletions
/// SELECT * FROM notes WHERE synced_at IS NULL OR updated_at > synced_at
///   ORDER BY updated_at LIMIT ?;
///
/// -- changedSince(): detects local edits that raced a remote pull
/// SELECT * FROM notes WHERE updated_at > ? ORDER BY updated_at LIMIT ?;
/// ```
///
/// See [InMemoryLocalStore] for a complete reference implementation.
abstract interface class LocalStore {
  /// Records with local changes the backend has not acknowledged.
  ///
  /// Must include tombstones, and must be ordered oldest-first so the backend
  /// sees writes in the order the user made them.
  Future<List<SyncDocument>> pendingChanges({int limit = 100});

  /// Records modified after [since], oldest first. Pass null for everything.
  Future<List<SyncDocument>> changedSince(DateTime? since, {int limit = 200});

  /// A single record by id, or null.
  Future<SyncDocument?> byId(String id);

  /// Inserts or replaces a record.
  Future<void> upsert(SyncDocument document);

  /// Inserts or replaces many records in one transaction where possible.
  Future<void> upsertAll(Iterable<SyncDocument> documents);

  /// Marks records as acknowledged by the backend at [syncedAt].
  ///
  /// Implementations must only clear the pending flag when the stored
  /// [SyncDocument.updatedAt] has not moved on since the push started —
  /// otherwise a concurrent local edit would be silently marked as synced and
  /// the user's change would never reach the backend.
  Future<void> markSynced(Iterable<String> ids, DateTime syncedAt);

  /// Permanently removes tombstones older than [olderThan].
  Future<int> purgeTombstones(DateTime olderThan);

  /// Total number of records, including tombstones by default.
  Future<int> count({bool includeTombstones = true});

  /// Fires whenever local data changes, so the engine can react quickly
  /// instead of waiting for the next poll.
  ///
  /// Optional: return a stream that never emits if you only want polling.
  Stream<void> get changes;
}

/// An in-memory [LocalStore] for tests, prototypes and small datasets.
///
/// It implements the full contract — pending detection, the concurrent-write
/// guard, tombstones, purge and change notifications — so anything you build
/// against it works unchanged against a real database.
class InMemoryLocalStore implements LocalStore {
  /// Creates an in-memory store, optionally seeded with [initial].
  InMemoryLocalStore({Iterable<SyncDocument> initial = const []}) {
    for (final document in initial) {
      _records[document.id] = document;
    }
  }

  final Map<String, SyncDocument> _records = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Every record currently held, for assertions in tests.
  List<SyncDocument> get all => _records.values.toList(growable: false);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<SyncDocument>> pendingChanges({int limit = 100}) async {
    final pending = _records.values.where(_isPending).toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return pending.take(limit).toList(growable: false);
  }

  @override
  Future<List<SyncDocument>> changedSince(
    DateTime? since, {
    int limit = 200,
  }) async {
    final changed = _records.values
        .where((d) => since == null || d.updatedAt.isAfter(since))
        .toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return changed.take(limit).toList(growable: false);
  }

  @override
  Future<SyncDocument?> byId(String id) async => _records[id];

  @override
  Future<void> upsert(SyncDocument document) async {
    _records[document.id] = document;
    _notify();
  }

  @override
  Future<void> upsertAll(Iterable<SyncDocument> documents) async {
    var wrote = false;
    for (final document in documents) {
      _records[document.id] = document;
      wrote = true;
    }
    if (wrote) _notify();
  }

  @override
  Future<void> markSynced(Iterable<String> ids, DateTime syncedAt) async {
    for (final id in ids) {
      final current = _records[id];
      if (current == null) continue;
      // Guard against a write that landed while the push was in flight: only
      // clear the pending flag if the record has not moved on since.
      if (!current.hasPendingChanges) continue;
      if (current.updatedAt.isAfter(syncedAt)) continue;
      _records[id] = current.markSynced(syncedAt);
    }
    _notify();
  }

  @override
  Future<int> purgeTombstones(DateTime olderThan) async {
    final doomed = _records.values
        .where((d) => d.isDeleted && d.updatedAt.isBefore(olderThan))
        .map((d) => d.id)
        .toList();
    for (final id in doomed) {
      _records.remove(id);
    }
    if (doomed.isNotEmpty) _notify();
    return doomed.length;
  }

  @override
  Future<int> count({bool includeTombstones = true}) async {
    if (includeTombstones) return _records.length;
    return _records.values.where((d) => !d.isDeleted).length;
  }

  /// Removes everything, for test isolation.
  Future<void> clear() async {
    _records.clear();
    _notify();
  }

  /// Releases the change stream. Call this when you are done with the store.
  Future<void> dispose() => _changes.close();

  static bool _isPending(SyncDocument d) {
    final synced = d.syncedAt;
    if (synced == null) return true;
    return d.updatedAt.isAfter(synced);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
