import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);
  final t1 = t0.add(const Duration(minutes: 1));

  SyncDocument doc(
    String id,
    Map<String, Object?> data,
    DateTime at, {
    bool deleted = false,
  }) =>
      SyncDocument(
        id: id,
        data: data,
        updatedAt: at,
        deletedAt: deleted ? at : null,
      );

  group('resolveConflict', () {
    test('identical content needs no resolution', () {
      final a = doc('x', const {'v': 1}, t0);
      final b = doc('x', const {'v': 1}, t1);
      expect(
        resolveConflict(ConflictPolicy.lastWriteWins, local: a, remote: b),
        ConflictResolution.identical,
      );
    });

    test('a differing deletion state is not identical', () {
      final live = doc('x', const {'v': 1}, t0);
      final dead = doc('x', const {'v': 1}, t1, deleted: true);
      expect(
        resolveConflict(ConflictPolicy.lastWriteWins, local: live, remote: dead),
        isNot(ConflictResolution.identical),
      );
    });

    test('lastWriteWins prefers the newer local version', () {
      expect(
        resolveConflict(
          ConflictPolicy.lastWriteWins,
          local: doc('x', const {'v': 1}, t1),
          remote: doc('x', const {'v': 2}, t0),
        ),
        ConflictResolution.localWon,
      );
    });

    test('lastWriteWins prefers the newer remote version', () {
      expect(
        resolveConflict(
          ConflictPolicy.lastWriteWins,
          local: doc('x', const {'v': 1}, t0),
          remote: doc('x', const {'v': 2}, t1),
        ),
        ConflictResolution.remoteWon,
      );
    });

    test('equal timestamps resolve in favour of local', () {
      expect(
        resolveConflict(
          ConflictPolicy.lastWriteWins,
          local: doc('x', const {'v': 1}, t0),
          remote: doc('x', const {'v': 2}, t0),
        ),
        ConflictResolution.localWon,
      );
    });

    test('remoteWins always yields to the backend', () {
      expect(
        resolveConflict(
          ConflictPolicy.remoteWins,
          local: doc('x', const {'v': 1}, t1),
          remote: doc('x', const {'v': 2}, t0),
        ),
        ConflictResolution.remoteWon,
      );
    });

    test('localWins always keeps the device version', () {
      expect(
        resolveConflict(
          ConflictPolicy.localWins,
          local: doc('x', const {'v': 1}, t0),
          remote: doc('x', const {'v': 2}, t1),
        ),
        ConflictResolution.localWon,
      );
    });

    test('manual defers every conflict', () {
      expect(
        resolveConflict(
          ConflictPolicy.manual,
          local: doc('x', const {'v': 1}, t0),
          remote: doc('x', const {'v': 2}, t1),
        ),
        ConflictResolution.deferred,
      );
    });
  });

  group('winnerFor', () {
    test('picks the newer document under lastWriteWins', () {
      final older = doc('x', const {'v': 'old'}, t0);
      final newer = doc('x', const {'v': 'new'}, t1);
      expect(
        winnerFor(ConflictPolicy.lastWriteWins, local: older, remote: newer)
            .data['v'],
        'new',
      );
      expect(
        winnerFor(ConflictPolicy.lastWriteWins, local: newer, remote: older)
            .data['v'],
        'new',
      );
    });

    test('returns local under manual so the caller decides', () {
      final local = doc('x', const {'v': 'local'}, t0);
      final remote = doc('x', const {'v': 'remote'}, t1);
      expect(
        winnerFor(ConflictPolicy.manual, local: local, remote: remote)
            .data['v'],
        'local',
      );
    });
  });

  group('sameContent', () {
    test('ignores timestamps and revisions', () {
      final a = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t0, revision: 1);
      final b = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t1, revision: 9);
      expect(sameContent(a, b), isTrue);
    });

    test('detects a differing value', () {
      final a = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t0);
      final b = SyncDocument(id: 'x', data: const {'v': 2}, updatedAt: t0);
      expect(sameContent(a, b), isFalse);
    });

    test('detects an extra key', () {
      final a = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t0);
      final b = SyncDocument(id: 'x', data: const {'v': 1, 'w': 2}, updatedAt: t0);
      expect(sameContent(a, b), isFalse);
    });

    test('detects a differing deletion state', () {
      final a = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t0);
      final b = SyncDocument(id: 'x', data: const {'v': 1}, updatedAt: t0, deletedAt: t0);
      expect(sameContent(a, b), isFalse);
    });
  });

  group('ConflictResolution', () {
    test('only remote-won and merged require a local write', () {
      expect(ConflictResolution.remoteWon.requiresLocalUpdate, isTrue);
      expect(ConflictResolution.merged.requiresLocalUpdate, isTrue);
      expect(ConflictResolution.localWon.requiresLocalUpdate, isFalse);
      expect(ConflictResolution.deferred.requiresLocalUpdate, isFalse);
      expect(ConflictResolution.identical.requiresLocalUpdate, isFalse);
    });
  });

  test('Conflict describes both sides', () {
    final conflict = Conflict(
      id: 'x',
      local: doc('x', const {'v': 1}, t0),
      remote: doc('x', const {'v': 2}, t1),
      resolution: ConflictResolution.remoteWon,
    );
    expect(conflict.toString(), contains('x'));
    expect(conflict.toString(), contains('remoteWon'));
  });
}
