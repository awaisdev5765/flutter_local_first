import 'dart:async';

import 'sync_record.dart';

/// What a push achieved.
class PushResult {
  /// Creates a push result.
  const PushResult({
    this.accepted = const [],
    this.rejected = const {},
    required this.serverTime,
  });

  /// Ids the backend stored.
  final List<String> accepted;

  /// Ids the backend refused, mapped to a human-readable reason. A rejected
  /// record stays pending locally so the user's edit is never lost.
  final Map<String, String> rejected;

  /// The backend's clock when it handled the push. The engine uses this as the
  /// next pull cursor, so it must be monotonic on the server. Returning a
  /// client-supplied timestamp here would let records be skipped.
  final DateTime serverTime;

  /// Whether everything sent was accepted.
  bool get isClean => rejected.isEmpty;
}

/// A page of remote changes.
class PullResult {
  /// Creates a pull result.
  const PullResult({
    this.records = const [],
    this.cursor,
    this.hasMore = false,
    required this.serverTime,
  });

  /// The changes in this page, oldest first.
  final List<SyncDocument> records;

  /// Opaque continuation token for the next page. The engine round-trips it
  /// untouched, so you can use a document id, an offset, or a snapshot token.
  final String? cursor;

  /// Whether another page is waiting.
  final bool hasMore;

  /// The backend's clock at the time of the pull.
  final DateTime serverTime;
}

/// The contract the engine needs from your backend.
///
/// Implement it over Firestore, Supabase, REST, GraphQL, an S3 bucket, or use
/// [InMemoryRemoteStore] to develop before the backend exists.
///
/// Two requirements matter more than they look:
///
/// 1. **[PullResult.serverTime] must be the server's clock**, not the client's.
///    The engine stores it as the next pull cursor. If each device supplied its
///    own time, a device with a slow clock would never see other devices'
///    writes.
/// 2. **Push must be idempotent per record id.** Retries are normal, so a
///    second push of the same payload must not create a duplicate.
abstract interface class RemoteStore {
  /// Uploads [documents].
  ///
  /// Throw to signal a transport failure, which the engine will retry according
  /// to its `RetryPolicy`. Return [PushResult] with entries in
  /// [PushResult.rejected] for per-record business failures.
  Future<PushResult> push(List<SyncDocument> documents);

  /// Downloads changes newer than [since], or everything when null.
  Future<PullResult> pull({
    DateTime? since,
    int limit = 200,
    String? cursor,
  });

  /// Optionally removes server-side tombstones older than [olderThan].
  /// Returning 0 is a perfectly good implementation.
  Future<int> purgeTombstones(DateTime olderThan) async => 0;
}

/// An optional extension of [RemoteStore] for backends that can fetch several
/// records by id in one round trip.
///
/// The engine uses this to detect conflicts before pushing. Without it the
/// engine falls back to scanning recent pages, which is correct for any backend
/// but does more I/O. Implement it when your backend offers a batch read
/// (Firestore `getAll`, a `WHERE id IN (...)` query, a GraphQL nodes lookup).
abstract interface class BatchRemoteStore implements RemoteStore {
  /// Returns the current server version of each id it knows about. Ids that do
  /// not exist are simply absent from the map.
  Future<Map<String, SyncDocument>> getMany(List<String> ids);
}

/// An in-memory backend with fault injection, for tests and local development.
///
/// It behaves like a real server: it stamps incoming writes with its own clock,
/// detects conflicts against the version it already holds, paginates pulls, and
/// can be told to fail, stall, or go down entirely.
class InMemoryRemoteStore implements BatchRemoteStore {
  /// Creates an in-memory backend.
  InMemoryRemoteStore({
    Iterable<SyncDocument> initial = const [],
    this.latency = Duration.zero,
    this.failuresBeforeSuccess = 0,
    this.error = const RemoteUnavailable(),
  }) {
    for (final document in initial) {
      _records[document.id] = document;
      _stamp(document);
    }
    _serverTime = DateTime.utc(2024);
  }

  final Map<String, SyncDocument> _records = {};
  late DateTime _serverTime;

  /// Artificial delay applied to every call, to model a slow network.
  final Duration latency;

  /// How many upcoming calls should fail before succeeding. Decrements once per
  /// call, across pushes and pulls.
  int failuresBeforeSuccess;

  /// The error thrown while [failuresBeforeSuccess] is above zero.
  final Object error;

  /// Every document the backend has ever received, in push order. Useful for
  /// asserting exactly what a device uploaded.
  final List<SyncDocument> received = [];

  /// Number of push and pull calls, including failed ones.
  int callCount = 0;

  /// Records currently held, for assertions.
  List<SyncDocument> get all => _records.values.toList(growable: false);

  /// Makes time move forward on the server, so a later pull sees more.
  void advanceClock(Duration by) {
    _serverTime = _serverTime.add(by);
  }

  DateTime _tick() {
    _serverTime = _serverTime.add(const Duration(milliseconds: 1));
    return _serverTime;
  }

  /// Stores the document as the server sees it: everything marked synced.
  void _stamp(SyncDocument document) {
    _records[document.id] = SyncDocument(
      id: document.id,
      data: document.data,
      updatedAt: document.updatedAt,
      deletedAt: document.deletedAt,
      revision: document.revision,
      syncedAt: document.updatedAt,
    );
  }

  Future<void> _simulate() async {
    callCount++;
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw error;
    }
  }

  /// The stored version of a record, or null.
  SyncDocument? peek(String id) => _records[id];

  @override
  Future<PushResult> push(List<SyncDocument> documents) async {
    await _simulate();
    final accepted = <String>[];
    final rejected = <String, String>{};

    for (final document in documents) {
      if (document.id.isEmpty) {
        rejected[document.id] = 'Record id must not be empty';
        continue;
      }
      received.add(document);
      _stamp(document);
      accepted.add(document.id);
    }

    return PushResult(
      accepted: accepted,
      rejected: rejected,
      serverTime: _tick(),
    );
  }

  @override
  Future<Map<String, SyncDocument>> getMany(List<String> ids) async {
    await _simulate();
    return {
      for (final id in ids)
        if (_records[id] != null) id: _records[id]!,
    };
  }

  @override
  Future<PullResult> pull({
    DateTime? since,
    int limit = 200,
    String? cursor,
  }) async {
    await _simulate();

    final start = cursor == null ? 0 : int.tryParse(cursor) ?? 0;
    final all = _records.values.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final changed = all
        .where((d) => since == null || d.updatedAt.isAfter(since))
        .toList();

    final page = changed.skip(start).take(limit).toList();
    final nextOffset = start + page.length;
    final hasMore = nextOffset < changed.length;

    return PullResult(
      records: page,
      cursor: hasMore ? '$nextOffset' : null,
      hasMore: hasMore,
      serverTime: _tick(),
    );
  }

  @override
  Future<int> purgeTombstones(DateTime olderThan) async {
    await _simulate();
    final doomed = _records.values
        .where((d) => d.isDeleted && d.updatedAt.isBefore(olderThan))
        .map((d) => d.id)
        .toList();
    for (final id in doomed) {
      _records.remove(id);
    }
    return doomed.length;
  }
}

/// Thrown by [InMemoryRemoteStore] when configured to fail, and a reasonable
/// base class for transport errors in your own [RemoteStore].
class RemoteUnavailable implements Exception {
  /// Creates the error.
  const RemoteUnavailable([this.message = 'Remote store is unavailable']);

  /// A human-readable description.
  final String message;

  @override
  String toString() => 'RemoteUnavailable: $message';
}
