import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);

  group('SyncDocument', () {
    test('exposes id, payload and timestamp', () {
      final doc = SyncDocument(id: 'n1', data: const {'title': 'Hi'}, updatedAt: t0);
      expect(doc.id, 'n1');
      expect(doc.data['title'], 'Hi');
      expect(doc.updatedAt, t0);
      expect(doc.isDeleted, isFalse);
      expect(doc.revision, 0);
    });

    test('payload is immutable', () {
      final source = <String, Object?>{'a': 1};
      final doc = SyncDocument(id: 'x', data: source, updatedAt: t0);
      source['b'] = 2;
      expect(doc.data.containsKey('b'), isFalse);
      expect(() => doc.data['c'] = 3, throwsUnsupportedError);
    });

    test('hasPendingChanges is true until acknowledged', () {
      final doc = SyncDocument(id: 'x', updatedAt: t0);
      expect(doc.hasPendingChanges, isTrue);
      expect(doc.markSynced(t0).hasPendingChanges, isFalse);
    });

    test('hasPendingChanges returns after a newer local edit', () {
      final synced = SyncDocument(id: 'x', updatedAt: t0).markSynced(t0);
      final edited = synced.merge(const {'a': 1}, at: t0.add(const Duration(minutes: 1)));
      expect(edited.hasPendingChanges, isTrue);
    });

    test('merge combines payloads and clears the synced flag', () {
      final doc =
          SyncDocument(id: 'x', data: const {'a': 1}, updatedAt: t0).markSynced(t0);
      final merged = doc.merge(const {'b': 2}, at: t0.add(const Duration(minutes: 5)));
      expect(merged.data, {'a': 1, 'b': 2});
      expect(merged.syncedAt, isNull);
      expect(merged.revision, 1);
    });

    test('merge can clear a tombstone to resurrect a record', () {
      final deleted = SyncDocument(id: 'x', updatedAt: t0).tombstone(t0);
      final restored = deleted.merge(
        const {},
        at: t0.add(const Duration(days: 1)),
        deleted: false,
      );
      expect(restored.isDeleted, isFalse);
    });

    test('tombstone keeps the payload so a losing delete can be undone', () {
      final doc =
          SyncDocument(id: 'x', data: const {'title': 'Keep me'}, updatedAt: t0);
      final tomb = doc.tombstone(t0.add(const Duration(minutes: 1)));
      expect(tomb.isDeleted, isTrue);
      expect(tomb.data['title'], 'Keep me');
      expect(tomb.deletedAt, t0.add(const Duration(minutes: 1)));
      expect(tomb.revision, 1);
    });

    test('markSynced preserves content and stamps the time', () {
      final doc = SyncDocument(id: 'x', data: const {'a': 1}, updatedAt: t0);
      final synced = doc.markSynced(t0.add(const Duration(seconds: 3)));
      expect(synced.data, doc.data);
      expect(synced.updatedAt, t0);
      expect(synced.syncedAt, isNotNull);
    });

    test('envelope round-trips through JSON', () {
      final original = SyncDocument(
        id: 'n1',
        data: const {'title': 'Groceries', 'pinned': true, 'count': 3},
        updatedAt: t0,
        deletedAt: t0.add(const Duration(hours: 1)),
        revision: 4,
        syncedAt: t0.add(const Duration(hours: 2)),
      );

      final decoded = SyncDocument.fromJson(
        Map<String, Object?>.from(original.toEnvelope()),
      );

      expect(decoded.id, original.id);
      expect(decoded.data, original.data);
      expect(decoded.updatedAt, original.updatedAt);
      expect(decoded.deletedAt, original.deletedAt);
      expect(decoded.revision, original.revision);
      expect(decoded.syncedAt, original.syncedAt);
    });

    test('fromJson tolerates a missing payload', () {
      final decoded = SyncDocument.fromJson({
        'id': 'x',
        'updatedAt': t0.toIso8601String(),
      });
      expect(decoded.data, isEmpty);
      expect(decoded.deletedAt, isNull);
      expect(decoded.revision, 0);
    });

    test('toString flags deletions', () {
      expect(SyncDocument(id: 'x', updatedAt: t0).toString(), contains('x'));
      expect(
        SyncDocument(id: 'x', updatedAt: t0).tombstone(t0).toString(),
        contains('DELETED'),
      );
    });
  });

  group('SyncCodec', () {
    test('round-trips a domain model', () {
      const codec = _NoteCodec();
      final note = _Note(id: 'n1', title: 'Hello', updatedAt: t0);

      final document = codec.encode(note);
      expect(document.id, 'n1');
      expect(document.data['title'], 'Hello');

      final decoded = codec.decode(document);
      expect(decoded.id, note.id);
      expect(decoded.title, note.title);
      expect(decoded.updatedAt, note.updatedAt);
    });
  });
}

class _Note {
  const _Note({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

class _NoteCodec extends SyncCodec<_Note> {
  const _NoteCodec();

  @override
  SyncDocument encode(_Note note) => SyncDocument(
        id: note.id,
        data: {'title': note.title},
        updatedAt: note.updatedAt,
        deletedAt: note.deletedAt,
      );

  @override
  _Note decode(SyncDocument document) => _Note(
        id: document.id,
        title: document.data['title']! as String,
        updatedAt: document.updatedAt,
        deletedAt: document.deletedAt,
      );
}
