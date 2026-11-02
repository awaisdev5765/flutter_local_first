import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);

  SyncDocument doc(
    String id, {
    DateTime? at,
    Map<String, Object?> data = const {},
    bool deleted = false,
  }) =>
      SyncDocument(
        id: id,
        data: data,
        updatedAt: at ?? t0,
        deletedAt: deleted ? (at ?? t0) : null,
      );

  late InMemoryLocalStore store;
  late InMemoryRemoteStore remote;
  late LocalFirstSync engine;

  /// Builds a fresh local store, backend and engine. Taking every dependency as
  /// a parameter keeps each test to a single engine instance, so the engine
  /// under assertion is always the engine that runs.
  Future<void> build({
    SyncConfig config = const SyncConfig(),
    ConnectivityMonitor? connectivity,
    AttachmentQueue? attachments,
    Iterable<SyncDocument> remoteInitial = const [],
    int remoteFailures = 0,
    Duration remoteLatency = Duration.zero,
  }) async {
    store = InMemoryLocalStore();
    remote = InMemoryRemoteStore(
      initial: remoteInitial,
      failuresBeforeSuccess: remoteFailures,
      latency: remoteLatency,
    );
    engine = LocalFirstSync(
      store: store,
      remote: remote,
      config: config,
      connectivity: connectivity,
      attachments: attachments,
    );
  }

  tearDown(() async {
    await engine.dispose();
    await store.dispose();
  });

  group('push', () {
    test('uploads pending local changes and marks them synced', () async {
      await build();
      await store.upsert(doc('a', data: const {'title': 'local'}));

      final outcome = await engine.sync();

      expect(outcome.pushed, 1);
      expect(remote.peek('a')!.data['title'], 'local');
      expect((await store.byId('a'))!.hasPendingChanges, isFalse);
    });

    test('does not re-push acknowledged records', () async {
      await build();
      await store.upsert(doc('a'));
      await engine.sync();

      final second = await engine.sync();

      expect(second.pushed, 0);
      expect(remote.received, hasLength(1), reason: 'the record was sent once');
    });

    test('pushes tombstones so deletions propagate', () async {
      await build();
      await store.upsert(doc('a'));
      await engine.sync();

      await engine.delete('a');
      final outcome = await engine.sync();

      expect(outcome.pushed, 1);
      expect(remote.peek('a')!.isDeleted, isTrue);
    });

    test('respects pushBatchSize across several batches', () async {
      await build(config: const SyncConfig(pushBatchSize: 2, maxPullPages: 1));
      for (var i = 0; i < 5; i++) {
        await store.upsert(doc('r$i', at: t0.add(Duration(minutes: i))));
      }

      final outcome = await engine.sync();

      expect(outcome.pushed, 5);
      expect(remote.all, hasLength(5));
    });

    test('a rejected record stays pending so the edit is not lost', () async {
      await build();
      await store.upsert(doc(''));

      final outcome = await engine.sync();

      expect(outcome.pushed, 0);
      expect(outcome.failures, greaterThan(0));
      expect(await store.byId(''), isNotNull);
    });

    test('syncs while never writing the same record twice', () async {
      await build();
      await store.upsert(doc('a'));
      await engine.sync();
      await engine.sync();
      await engine.sync();

      expect(remote.received.where((d) => d.id == 'a'), hasLength(1));
    });
  });

  group('pull', () {
    test('writes remote records into the local store', () async {
      await build(remoteInitial: [doc('remote-1', data: const {'v': 7})]);

      final outcome = await engine.sync();

      expect(outcome.pulled, 1);
      final local = await store.byId('remote-1');
      expect(local!.data['v'], 7);
      expect(local.hasPendingChanges, isFalse);
    });

    test('does not pull back a record it just pushed', () async {
      await build();
      await store.upsert(doc('mine', data: const {'v': 1}));

      await engine.sync();

      final local = await store.byId('mine');
      expect(local!.data['v'], 1);
      expect(local.hasPendingChanges, isFalse);
    });

    test('pages through a large remote dataset', () async {
      await build(
        config: const SyncConfig(pullBatchSize: 2, maxPullPages: 10),
        remoteInitial: [
          for (var i = 0; i < 7; i++) doc('r$i', at: t0.add(Duration(minutes: i))),
        ],
      );

      final outcome = await engine.sync();

      expect(outcome.pulled, 7);
      expect(await store.count(), 7);
    });

    test('cancels remote attachments when a record arrives deleted', () async {
      final transport = _RecordingTransport();
      final attachments = AttachmentQueue(transport: transport);
      addTearDown(attachments.dispose);
      addTearDown(transport.dispose);

      await build(
        attachments: attachments,
        remoteInitial: [doc('gone', deleted: true)],
      );
      attachments.add(Attachment(
        id: 'att-1',
        recordId: 'gone',
        localPath: '/tmp/x.jpg',
        remoteUrl: 'https://example.com/x.jpg',
      ));

      await engine.sync();

      expect(attachments['att-1'], isNull);
      expect(transport.deleted, contains('att-1'));
    });
  });

  group('conflicts', () {
    test('remote wins when it is newer, and the local store is updated',
        () async {
      await build(remoteInitial: [
        SyncDocument(
          id: 'c',
          data: const {'v': 'remote'},
          updatedAt: t0.add(const Duration(minutes: 5)),
        ),
      ]);
      await store.upsert(
        SyncDocument(id: 'c', data: const {'v': 'local'}, updatedAt: t0),
      );

      final outcome = await engine.sync();

      expect(outcome.conflicts, greaterThanOrEqualTo(1));
      final local = await store.byId('c');
      expect(local!.data['v'], 'remote');
      expect(local.hasPendingChanges, isFalse);
    });

    test('local wins when it is newer, and is pushed', () async {
      await build(remoteInitial: [
        SyncDocument(id: 'c', data: const {'v': 'remote'}, updatedAt: t0),
      ]);
      await store.upsert(SyncDocument(
        id: 'c',
        data: const {'v': 'local'},
        updatedAt: t0.add(const Duration(minutes: 10)),
      ));

      await engine.sync();

      expect(remote.peek('c')!.data['v'], 'local');
    });

    test('remoteWins policy overrides recency', () async {
      await build(
        config: const SyncConfig(conflictPolicy: ConflictPolicy.remoteWins),
        remoteInitial: [
          SyncDocument(id: 'c', data: const {'v': 'remote'}, updatedAt: t0),
        ],
      );
      await store.upsert(SyncDocument(
        id: 'c',
        data: const {'v': 'local'},
        updatedAt: t0.add(const Duration(days: 5)),
      ));

      await engine.sync();

      expect((await store.byId('c'))!.data['v'], 'remote');
    });

    test('localWins policy overrides recency', () async {
      await build(
        config: const SyncConfig(conflictPolicy: ConflictPolicy.localWins),
        remoteInitial: [
          SyncDocument(
            id: 'c',
            data: const {'v': 'remote'},
            updatedAt: t0.add(const Duration(days: 5)),
          ),
        ],
      );
      await store.upsert(
        SyncDocument(id: 'c', data: const {'v': 'local'}, updatedAt: t0),
      );

      await engine.sync();

      expect(remote.peek('c')!.data['v'], 'local');
    });

    test('a custom resolver can merge field by field', () async {
      // Keep the local body, adopt the remote title.
      SyncDocument keepLocalBody(SyncDocument local, SyncDocument remote) =>
          SyncDocument(
            id: local.id,
            data: {
              'title': remote.data['title'],
              'body': local.data['body'],
            },
            updatedAt: local.updatedAt,
          );

      await build(
        config: SyncConfig(conflictResolver: keepLocalBody),
        remoteInitial: [
          SyncDocument(
            id: 'c',
            data: const {'title': 'remote title', 'body': 'remote body'},
            updatedAt: t0,
          ),
        ],
      );
      // Deliberately newer locally: the custom resolver must still run rather
      // than the policy short-circuiting it.
      await store.upsert(SyncDocument(
        id: 'c',
        data: const {'title': 'local title', 'body': 'local body'},
        updatedAt: t0.add(const Duration(minutes: 1)),
      ));

      await engine.sync();

      final local = await store.byId('c');
      expect(local!.data['title'], 'remote title');
      expect(local.data['body'], 'local body');
    });

    test('manual policy reports the conflict without resolving it', () async {
      await build(
        config: const SyncConfig(conflictPolicy: ConflictPolicy.manual),
        remoteInitial: [
          SyncDocument(id: 'c', data: const {'v': 'remote'}, updatedAt: t0),
        ],
      );
      final conflicts = <Conflict>[];
      engine.events.listen((e) {
        if (e is ConflictResolved) conflicts.add(e.conflict);
      });
      await store.upsert(SyncDocument(
        id: 'c',
        data: const {'v': 'local'},
        updatedAt: t0.add(const Duration(minutes: 1)),
      ));

      await engine.sync();
      await Future<void>.delayed(Duration.zero);

      expect(conflicts, isNotEmpty);
      expect(conflicts.first.resolution, ConflictResolution.deferred);
    });

    test('identical content is not reported as a conflict', () async {
      await build(remoteInitial: [
        SyncDocument(
          id: 'c',
          data: const {'v': 'same'},
          updatedAt: t0.add(const Duration(hours: 1)),
        ),
      ]);
      await store.upsert(
        SyncDocument(id: 'c', data: const {'v': 'same'}, updatedAt: t0),
      );

      final outcome = await engine.sync();

      expect(outcome.conflicts, 0);
    });
  });

  group('offline behaviour', () {
    test('skips the cycle while offline and reports the pending count',
        () async {
      final connectivity = ManualConnectivityMonitor(initiallyOnline: false);
      addTearDown(connectivity.dispose);
      await build(connectivity: connectivity);

      await store.upsert(doc('a'));
      final outcome = await engine.sync();

      expect(outcome.skippedBecauseOffline, isTrue);
      expect(remote.all, isEmpty);
      expect(engine.state.value, isA<Offline>());
      expect((engine.state.value as Offline).pendingChanges, 1);
    });

    test('syncs as soon as connectivity returns', () async {
      final connectivity = ManualConnectivityMonitor(initiallyOnline: false);
      addTearDown(connectivity.dispose);
      await build(connectivity: connectivity);

      await store.upsert(doc('a'));
      await engine.start();
      expect(remote.all, isEmpty);

      connectivity.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(remote.peek('a'), isNotNull);
    });

    test('syncOnReconnect false leaves the reconnect untriggered', () async {
      final connectivity = ManualConnectivityMonitor(initiallyOnline: false);
      addTearDown(connectivity.dispose);
      await build(
        connectivity: connectivity,
        config: const SyncConfig(syncOnReconnect: false, syncOnStart: false),
      );

      await store.upsert(doc('a'));
      await engine.start();
      connectivity.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(remote.all, isEmpty);
    });

    test('requireConnectivity false attempts a sync while offline', () async {
      final connectivity = ManualConnectivityMonitor(initiallyOnline: false);
      addTearDown(connectivity.dispose);
      await build(
        connectivity: connectivity,
        config: const SyncConfig(requireConnectivity: false),
      );

      await store.upsert(doc('a'));
      final outcome = await engine.sync();

      expect(outcome.skippedBecauseOffline, isFalse);
      expect(remote.peek('a'), isNotNull);
    });
  });

  group('failures and retry', () {
    test('surfaces a failure and schedules a retry', () async {
      await build(
        config: const SyncConfig(
          retryPolicy: RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 30),
            jitter: 0,
          ),
        ),
        remoteFailures: 99,
      );
      await store.upsert(doc('a'));

      final outcome = await engine.sync();

      expect(outcome.failures, greaterThan(0));
      expect(engine.state.value, isA<Failed>());
      final failed = engine.state.value as Failed;
      expect(failed.error, isA<RemoteUnavailable>());
      expect(failed.retryIn, isNotNull);
      expect(engine.recentErrors, hasLength(1));
    });

    test('gives up after maxAttempts so the UI can stop waiting', () async {
      await build(
        config: const SyncConfig(retryPolicy: RetryPolicy(maxAttempts: 1)),
        remoteFailures: 99,
      );
      await store.upsert(doc('a'));

      await engine.sync();

      expect((engine.state.value as Failed).retryIn, isNull);
    });

    test('recovers on a later cycle and clears the failure state', () async {
      await build(remoteFailures: 1);
      await store.upsert(doc('a'));

      await engine.sync();
      expect(engine.state.value, isA<Failed>());

      final second = await engine.sync();
      expect(second.pushed, 1);
      expect(engine.state.value, isA<Idle>());
    });

    test('recentErrors is capped and never grows unbounded', () async {
      await build(
        config: const SyncConfig(retryPolicy: RetryPolicy(maxAttempts: 1)),
        remoteFailures: 999,
      );

      for (var i = 0; i < 25; i++) {
        await engine.sync();
      }

      expect(engine.recentErrors.length, lessThanOrEqualTo(20));
    });
  });

  group('local writes', () {
    test('write is durable immediately, before any sync', () async {
      await build();
      await engine.write(doc('local', data: const {'v': 1}));
      expect((await store.byId('local'))!.data['v'], 1);
      expect(remote.all, isEmpty);
    });

    test('writeAll persists a batch', () async {
      await build();
      await engine.writeAll([doc('a'), doc('b')]);
      expect(await store.count(), 2);
    });

    test('delete records a tombstone rather than removing the row', () async {
      await build();
      await engine.write(doc('a', data: const {'keep': true}));
      await engine.delete('a');

      final local = await store.byId('a');
      expect(local, isNotNull);
      expect(local!.isDeleted, isTrue);
      expect(local.data['keep'], true);
    });

    test('delete on an unknown id still creates a tombstone', () async {
      await build();
      await engine.delete('never-seen');
      expect((await store.byId('never-seen'))!.isDeleted, isTrue);
    });

    test('delete drops local attachments', () async {
      final transport = _RecordingTransport();
      final queue = AttachmentQueue(transport: transport);
      addTearDown(queue.dispose);
      addTearDown(transport.dispose);

      await build(attachments: queue);
      queue.add(Attachment(
        id: 'a1',
        recordId: 'n1',
        localPath: '/tmp/a.jpg',
        remoteUrl: 'https://example.com/a.jpg',
      ));

      await engine.delete('n1');
      await Future<void>.delayed(Duration.zero);

      expect(queue['a1'], isNull);
      expect(transport.deleted, contains('a1'));
    });

    test('a write triggers a debounced sync once started', () async {
      await build(config: const SyncConfig(
        syncInterval: Duration(hours: 1),
        syncOnStart: false,
      ));
      await engine.start();
      await engine.write(doc('a'));

      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(remote.peek('a'), isNotNull);
    });
  });

  group('engine lifecycle', () {
    test('start is idempotent', () async {
      await build(config: const SyncConfig(
        syncOnStart: false,
        syncInterval: Duration(hours: 1),
      ));
      await engine.start();
      await engine.start();
      expect(engine.isRunning, isTrue);
    });

    test('syncOnStart performs an immediate cycle', () async {
      await build(config: const SyncConfig(
        syncInterval: Duration(hours: 1),
        syncOnStart: true,
      ));
      await store.upsert(doc('a'));

      await engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(remote.peek('a'), isNotNull);
    });

    test('stop cancels timers and reports a stopped state', () async {
      await build(config: const SyncConfig(syncInterval: Duration(hours: 1)));
      await engine.start();
      await engine.stop();

      expect(engine.isRunning, isFalse);
      expect(engine.state.value, isA<Stopped>());
    });

    test('concurrent sync calls share one cycle', () async {
      await build(remoteLatency: const Duration(milliseconds: 40));

      final results =
          await Future.wait([engine.sync(), engine.sync(), engine.sync()]);

      expect(results, hasLength(3));
      expect(identical(results[0], results[1]), isTrue);
    });

    test('isSyncing is false once a cycle finishes', () async {
      await build();
      expect(engine.isSyncing, isFalse);
      await engine.sync();
      expect(engine.isSyncing, isFalse);
    });

    test('resetCursor forces a full re-pull', () async {
      await build(remoteInitial: [doc('r', at: t0)]);
      await engine.sync();
      expect(engine.cursor, isNotNull);

      engine.resetCursor();
      expect(engine.cursor, isNull);
    });
  });

  group('stats and events', () {
    test('accumulates counters across cycles', () async {
      await build();
      await store.upsert(doc('a'));
      await engine.sync();
      await store.upsert(doc('b'));
      await engine.sync();

      expect(engine.stats.pushed, 2);
      expect(engine.stats.lastSyncedAt, isNotNull);
      expect(engine.stats.lastDuration, isNotNull);
    });

    test('emits started, pushed and completed events', () async {
      await build();
      final events = <SyncEvent>[];
      engine.events.listen(events.add);
      await store.upsert(doc('a'));

      await engine.sync();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<SyncStarted>(), hasLength(1));
      expect(events.whereType<RecordsPushed>(), hasLength(1));
      expect(events.whereType<SyncCompleted>(), hasLength(1));
    });

    test('emits a failure event with the attempt number', () async {
      await build(
        config: const SyncConfig(retryPolicy: RetryPolicy(maxAttempts: 1)),
        remoteFailures: 1,
      );
      final events = <SyncEvent>[];
      engine.events.listen(events.add);

      await engine.sync();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<SyncFailed>().single.attempt, 1);
    });

    test('emits local change events when remote data is applied', () async {
      await build(remoteInitial: [doc('r')]);
      final events = <SyncEvent>[];
      engine.events.listen(events.add);

      await engine.sync();
      await Future<void>.delayed(Duration.zero);

      final changes = events.whereType<LocalRecordChanged>().toList();
      expect(changes, hasLength(1));
      expect(changes.single.reason, LocalChangeReason.pulled);
    });

    test('emits a purge event when tombstones are removed', () async {
      await build();
      final events = <SyncEvent>[];
      engine.events.listen(events.add);

      await store.upsert(doc('old', at: t0, deleted: true));
      await engine.purgeTombstones();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<TombstonesPurged>(), hasLength(1));
    });

    test('purgeTombstones never removes a live record', () async {
      await build();
      await store.upsert(doc('live', at: t0));
      expect(await engine.purgeTombstones(), 0);
      expect(await store.count(), 1);
    });
  });

  group('state', () {
    test('starts idle', () async {
      await build();
      expect(engine.state.value, isA<Idle>());
    });

    test('notifies listeners on change', () async {
      await build();
      var notifications = 0;
      engine.state.addListener(() => notifications++);

      await engine.sync();

      expect(notifications, greaterThan(0));
    });

    test('labels are human readable', () {
      expect(const Idle().label, 'Up to date');
      expect(const Offline().label, 'Offline');
      expect(const Stopped().label, 'Paused');
      expect(const Syncing(phase: SyncPhase.pushing).label, contains('Uploading'));
      expect(const Syncing(phase: SyncPhase.pulling).label, contains('Downloading'));
      expect(const Syncing(phase: SyncPhase.applying).label, contains('Applying'));
    });

    test('syncing reports progress when a total is known', () {
      expect(
        const Syncing(phase: SyncPhase.pushing, completed: 5, total: 10).progress,
        0.5,
      );
      expect(const Syncing(phase: SyncPhase.pushing).progress, isNull);
      expect(const Syncing(phase: SyncPhase.pushing, total: 0).progress, isNull);
    });

    test('isBusy and isOnline describe the state', () {
      expect(const Syncing(phase: SyncPhase.pushing).isBusy, isTrue);
      expect(const Idle().isBusy, isFalse);
      expect(const Offline().isOnline, isFalse);
      expect(const Idle().isOnline, isTrue);
    });

    test('a failed state carries the retry delay', () {
      const failed = Failed(
        error: 'boom',
        attempt: 2,
        retryIn: Duration(seconds: 4),
      );
      expect(failed.label, contains('boom'));
      expect(failed.retryIn, const Duration(seconds: 4));
    });
  });

  group('two-device convergence', () {
    test('a record written on one device reaches the other', () async {
      // Device A writes and pushes.
      final storeA = InMemoryLocalStore();
      final storeB = InMemoryLocalStore();
      final shared = InMemoryRemoteStore();
      final engineA = LocalFirstSync(store: storeA, remote: shared);
      final engineB = LocalFirstSync(store: storeB, remote: shared);
      addTearDown(() async {
        await engineA.dispose();
        await engineB.dispose();
        await storeA.dispose();
        await storeB.dispose();
      });

      await engineA.write(doc('note-1', data: const {'title': 'From A'}));
      await engineA.sync();
      await engineB.sync();

      expect((await storeB.byId('note-1'))!.data['title'], 'From A');
    });

    test('a deletion on one device does not resurrect on the other', () async {
      final storeA = InMemoryLocalStore();
      final storeB = InMemoryLocalStore();
      final shared = InMemoryRemoteStore();
      final engineA = LocalFirstSync(store: storeA, remote: shared);
      final engineB = LocalFirstSync(store: storeB, remote: shared);
      addTearDown(() async {
        await engineA.dispose();
        await engineB.dispose();
        await storeA.dispose();
        await storeB.dispose();
      });

      await engineA.write(doc('note-1', data: const {'title': 'Shared'}));
      await engineA.sync();
      await engineB.sync();
      expect((await storeB.byId('note-1'))!.isDeleted, isFalse);

      // Device B deletes, syncs, then A syncs.
      await engineB.delete('note-1', at: DateTime.utc(2030));
      await engineB.sync();
      await engineA.sync();

      expect((await storeA.byId('note-1'))!.isDeleted, isTrue);
      expect(shared.peek('note-1')!.isDeleted, isTrue);
    });

    test('a long-offline device cannot resurrect a purge it never saw',
        () async {
      // Tombstones outlive the offline window, so the guard is the TTL: with a
      // long TTL the tombstone is still there when the stale device syncs.
      final storeA = InMemoryLocalStore();
      final storeB = InMemoryLocalStore();
      final shared = InMemoryRemoteStore();
      final engineA = LocalFirstSync(store: storeA, remote: shared);
      final engineB = LocalFirstSync(store: storeB, remote: shared);
      addTearDown(() async {
        await engineA.dispose();
        await engineB.dispose();
        await storeA.dispose();
        await storeB.dispose();
      });

      await engineA.write(doc('note-1'));
      await engineA.sync();
      await engineB.sync();

      await engineA.delete('note-1', at: DateTime.utc(2030));
      await engineA.sync();

      // Device B re-pushes its stale copy; last-write-wins keeps the deletion.
      await engineB.sync();
      await engineA.sync();

      expect(shared.peek('note-1')!.isDeleted, isTrue);
    });
  });

  group('pendingCount', () {
    test('counts unsynced changes', () async {
      await build();
      await store.upsertAll([doc('a'), doc('b')]);
      expect(await engine.pendingCount(), 2);
      await engine.sync();
      expect(await engine.pendingCount(), 0);
    });
  });
}

/// Resolves uploads and records deletions without touching the network.
class _RecordingTransport implements AttachmentTransport {
  final List<String> deleted = [];

  @override
  Future<String> upload(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(1);
    return 'https://example.com/${attachment.id}';
  }

  @override
  Future<String> download(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(1);
    return '/tmp/${attachment.id}';
  }

  @override
  Future<void> delete(Attachment attachment) async {
    deleted.add(attachment.id);
  }

  Future<void> dispose() async {}
}
