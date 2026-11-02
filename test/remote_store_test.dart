import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);

  SyncDocument doc(String id, {DateTime? at, Map<String, Object?> data = const {}}) =>
      SyncDocument(id: id, data: data, updatedAt: at ?? t0);

  group('InMemoryRemoteStore', () {
    test('accepts pushes and reports them', () async {
      final remote = InMemoryRemoteStore();
      final result = await remote.push([doc('a'), doc('b')]);

      expect(result.accepted, ['a', 'b']);
      expect(result.rejected, isEmpty);
      expect(result.isClean, isTrue);
      expect(remote.all, hasLength(2));
    });

    test('records received pushes verbatim', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([doc('a', data: const {'v': 1})]);
      expect(remote.received.single.data['v'], 1);
    });

    test('rejects a record with an empty id', () async {
      final remote = InMemoryRemoteStore();
      final result = await remote.push([doc('')]);

      expect(result.accepted, isEmpty);
      expect(result.rejected.keys, ['']);
      expect(result.isClean, isFalse);
    });

    test('marks stored records as fully synced', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([doc('a')]);
      expect(remote.peek('a')!.syncedAt, isNotNull);
      expect(remote.peek('a')!.hasPendingChanges, isFalse);
    });

    test('serverTime advances on every call', () async {
      final remote = InMemoryRemoteStore();
      final first = await remote.push([doc('a')]);
      final second = await remote.pull();
      expect(second.serverTime.isAfter(first.serverTime), isTrue);
    });

    test('pull returns everything when since is null', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([
        doc('a', at: t0),
        doc('b', at: t0.add(const Duration(hours: 1))),
      ]);

      final page = await remote.pull();
      expect(page.records.map((d) => d.id), ['a', 'b']);
      expect(page.hasMore, isFalse);
      expect(page.cursor, isNull);
    });

    test('pull filters by since', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([
        doc('old', at: t0),
        doc('new', at: t0.add(const Duration(hours: 2))),
      ]);

      final page = await remote.pull(since: t0.add(const Duration(hours: 1)));
      expect(page.records.map((d) => d.id), ['new']);
    });

    test('pull paginates and reports a cursor', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([
        for (var i = 0; i < 5; i++) doc('r$i', at: t0.add(Duration(minutes: i))),
      ]);

      final first = await remote.pull(limit: 2);
      expect(first.records.map((d) => d.id), ['r0', 'r1']);
      expect(first.hasMore, isTrue);
      expect(first.cursor, isNotNull);

      final second = await remote.pull(limit: 2, cursor: first.cursor);
      expect(second.records.map((d) => d.id), ['r2', 'r3']);
      expect(second.hasMore, isTrue);

      final third = await remote.pull(limit: 2, cursor: second.cursor);
      expect(third.records.map((d) => d.id), ['r4']);
      expect(third.hasMore, isFalse);
      expect(third.cursor, isNull);
    });

    test('getMany returns only known ids', () async {
      final remote = InMemoryRemoteStore(initial: [doc('a'), doc('b')]);
      final found = await remote.getMany(['a', 'missing', 'b']);
      expect(found.keys.toSet(), {'a', 'b'});
    });

    test('fault injection throws for the configured number of calls', () async {
      final remote = InMemoryRemoteStore(failuresBeforeSuccess: 2);

      await expectLater(remote.pull(), throwsA(isA<RemoteUnavailable>()));
      await expectLater(remote.pull(), throwsA(isA<RemoteUnavailable>()));
      await expectLater(remote.pull(), completes);
    });

    test('callCount includes failures', () async {
      final remote = InMemoryRemoteStore(failuresBeforeSuccess: 1);
      try {
        await remote.pull();
      } on RemoteUnavailable {
        // expected
      }
      await remote.pull();
      expect(remote.callCount, 2);
    });

    test('latency delays the response', () async {
      final remote = InMemoryRemoteStore(latency: const Duration(milliseconds: 30));
      final watch = Stopwatch()..start();
      await remote.pull();
      watch.stop();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(25));
    });

    test('advanceClock moves the server clock forward', () async {
      final remote = InMemoryRemoteStore();
      final before = (await remote.pull()).serverTime;
      remote.advanceClock(const Duration(hours: 3));
      final after = (await remote.pull()).serverTime;
      expect(after.isAfter(before.add(const Duration(hours: 2))), isTrue);
    });

    test('purgeTombstones removes only old deletions', () async {
      final remote = InMemoryRemoteStore();
      await remote.push([
        doc('live', at: t0),
        SyncDocument(id: 'old', updatedAt: t0, deletedAt: t0),
        SyncDocument(
          id: 'fresh',
          updatedAt: t0.add(const Duration(days: 30)),
          deletedAt: t0.add(const Duration(days: 30)),
        ),
      ]);

      final removed = await remote.purgeTombstones(t0.add(const Duration(days: 10)));

      expect(removed, 1);
      expect(remote.peek('old'), isNull);
      expect(remote.peek('fresh'), isNotNull);
      expect(remote.peek('live'), isNotNull);
    });

    test('the constructor can seed the store', () async {
      final remote = InMemoryRemoteStore(initial: [doc('seeded')]);
      expect(remote.all, hasLength(1));
      expect(remote.peek('seeded')!.syncedAt, isNotNull);
    });
  });

  group('RemoteUnavailable', () {
    test('carries a message', () {
      expect(const RemoteUnavailable().toString(), contains('unavailable'));
      expect(const RemoteUnavailable('DNS failure').message, 'DNS failure');
    });
  });
}
