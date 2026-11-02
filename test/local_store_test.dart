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

  group('InMemoryLocalStore', () {
    late InMemoryLocalStore store;

    setUp(() => store = InMemoryLocalStore());
    tearDown(() => store.dispose());

    test('a fresh record is pending', () async {
      await store.upsert(doc('a'));
      expect((await store.pendingChanges()).map((d) => d.id), ['a']);
    });

    test('an acknowledged record is no longer pending', () async {
      await store.upsert(doc('a'));
      await store.markSynced(['a'], t0);
      expect(await store.pendingChanges(), isEmpty);
    });

    test('a record edited after being synced becomes pending again', () async {
      await store.upsert(doc('a'));
      await store.markSynced(['a'], t0);
      await store.upsert(doc('a', at: t0.add(const Duration(minutes: 1))));
      expect(await store.pendingChanges(), hasLength(1));
    });

    test('pending changes are oldest first', () async {
      await store.upsert(doc('newest', at: t0.add(const Duration(hours: 2))));
      await store.upsert(doc('oldest', at: t0));
      await store.upsert(doc('middle', at: t0.add(const Duration(hours: 1))));
      expect(
        (await store.pendingChanges()).map((d) => d.id),
        ['oldest', 'middle', 'newest'],
      );
    });

    test('pendingChanges honours the limit', () async {
      for (var i = 0; i < 10; i++) {
        await store.upsert(doc('r$i', at: t0.add(Duration(minutes: i))));
      }
      expect(await store.pendingChanges(limit: 3), hasLength(3));
    });

    test('tombstones count as pending', () async {
      await store.upsert(doc('a'));
      await store.markSynced(['a'], t0);
      await store.upsert(
        doc('a', at: t0.add(const Duration(minutes: 1)), deleted: true),
      );
      expect((await store.pendingChanges()).single.isDeleted, isTrue);
    });

    test('markSynced does not clobber a concurrent local edit', () async {
      await store.upsert(doc('a', at: t0));
      await store.upsert(
        doc('a', at: t0.add(const Duration(seconds: 5)), data: const {'v': 2}),
      );
      await store.markSynced(['a'], t0);

      final stored = await store.byId('a');
      expect(stored!.data['v'], 2);
      expect(stored.hasPendingChanges, isTrue);
    });

    test('markSynced ignores unknown ids', () async {
      await store.markSynced(['missing'], t0);
      expect(await store.byId('missing'), isNull);
    });

    test('changedSince filters by timestamp', () async {
      await store.upsert(doc('old', at: t0));
      await store.upsert(doc('recent', at: t0.add(const Duration(hours: 1))));
      final changed = await store.changedSince(t0.add(const Duration(minutes: 30)));
      expect(changed.map((d) => d.id), ['recent']);
    });

    test('changedSince with null returns everything, oldest first', () async {
      await store.upsert(doc('b', at: t0.add(const Duration(hours: 1))));
      await store.upsert(doc('a', at: t0));
      expect((await store.changedSince(null)).map((d) => d.id), ['a', 'b']);
    });

    test('changedSince honours the limit', () async {
      for (var i = 0; i < 5; i++) {
        await store.upsert(doc('r$i', at: t0.add(Duration(minutes: i))));
      }
      expect(await store.changedSince(null, limit: 2), hasLength(2));
    });

    test('upsertAll writes a batch', () async {
      await store.upsertAll([doc('a'), doc('b'), doc('c')]);
      expect(await store.count(), 3);
      expect(await store.byId('b'), isNotNull);
    });

    test('count can exclude tombstones', () async {
      await store.upsertAll([doc('a'), doc('b', deleted: true)]);
      expect(await store.count(), 2);
      expect(await store.count(includeTombstones: false), 1);
    });

    test('purgeTombstones removes only old tombstones', () async {
      await store.upsertAll([
        doc('live', at: t0),
        doc('oldTombstone', at: t0, deleted: true),
        doc('freshTombstone', at: t0.add(const Duration(days: 10)), deleted: true),
      ]);

      final removed = await store.purgeTombstones(t0.add(const Duration(days: 5)));

      expect(removed, 1);
      expect(await store.byId('oldTombstone'), isNull);
      expect(await store.byId('freshTombstone'), isNotNull);
      expect(await store.byId('live'), isNotNull);
    });

    test('purgeTombstones never removes live records', () async {
      await store.upsert(doc('live', at: t0));
      expect(await store.purgeTombstones(t0.add(const Duration(days: 1))), 0);
      expect(await store.count(), 1);
    });

    test('changes emits when data is written', () async {
      final events = <void>[];
      final subscription = store.changes.listen(events.add);
      addTearDown(subscription.cancel);

      await store.upsert(doc('a'));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));

      await store.upsertAll([doc('b'), doc('c')]);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
    });

    test('upsertAll with nothing to write stays quiet', () async {
      final events = <void>[];
      final subscription = store.changes.listen(events.add);
      addTearDown(subscription.cancel);

      await store.upsertAll(const []);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });

    test('clear empties the store', () async {
      await store.upsertAll([doc('a'), doc('b')]);
      await store.clear();
      expect(await store.count(), 0);
    });

    test('the constructor can seed records', () async {
      final seeded = InMemoryLocalStore(initial: [doc('a'), doc('b')]);
      addTearDown(seeded.dispose);
      expect(await seeded.count(), 2);
    });
  });
}
