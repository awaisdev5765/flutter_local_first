// A runnable end-to-end demonstration of flutter_local_first.
//
//   dart run example/main.dart
//
// It builds two "devices" over one shared in-memory backend and walks through
// offline writes, a two-device sync, a conflict, a deletion, and attachment
// cleanup — printing what happens at each step. No network required.

import 'package:flutter_local_first/flutter_local_first.dart';

Future<void> main() async {
  section('1. Set up two devices sharing one backend');

  final backend = InMemoryRemoteStore();
  final engineA = LocalFirstSync(store: InMemoryLocalStore(), remote: backend);
  final engineB = LocalFirstSync(store: InMemoryLocalStore(), remote: backend);

  // Log every event so the walkthrough is visible.
  for (final (name, engine) in [('A', engineA), ('B', engineB)]) {
    engine.events.listen((event) {
      final detail = switch (event) {
        SyncStarted(:final pendingCount) => 'started ($pendingCount pending)',
        RecordsPushed(:final ids) => 'pushed ${ids.length} record(s)',
        RecordsPulled(:final ids) => 'pulled ${ids.length} record(s)',
        ConflictResolved(:final conflict) =>
          'conflict on ${conflict.id} -> ${conflict.resolution.name}',
        SyncCompleted(:final stats) => 'done ($stats)',
        SyncFailed(:final error) => 'FAILED: $error',
        ConnectivityChanged(:final online) => 'connectivity: $online',
        TombstonesPurged(:final count) => 'purged $count tombstone(s)',
        LocalRecordChanged(:final record) => 'local change: ${record.id}',
      };
      print('   [device $name] $detail');
    });
  }

  section('2. Write on device A while "offline"');
  final offline = ManualConnectivityMonitor(initiallyOnline: false);
  final offlineEngine = LocalFirstSync(
    store: InMemoryLocalStore(),
    remote: backend,
    connectivity: offline,
  );
  await offlineEngine.write(_note('offline-1', 'Written on a plane'));
  final skipped = await offlineEngine.sync();
  print('   sync skipped because offline: ${skipped.skippedBecauseOffline}');
  print('   state: ${offlineEngine.state.value.label}');
  print('   pending locally: ${await offlineEngine.pendingCount()}');

  section('3. Write and sync on device A');
  await engineA.write(_note('note-1', 'Groceries', at: DateTime.utc(2026, 1, 1)));
  final firstSync = await engineA.sync();
  print('   $firstSync');

  section('4. Device B receives it');
  await engineB.sync();
  final onB = await engineB.store.byId('note-1');
  print('   B now has: ${onB!.data['title']}');

  section('5. Conflict: both devices edit the same note');
  // A edits first, B edits "later" so last-write-wins prefers B.
  await engineA.write(_note('note-1', 'Edited on A', at: DateTime.utc(2026, 1, 2)));
  await engineB.write(_note('note-1', 'Edited on B', at: DateTime.utc(2026, 1, 3)));

  await engineB.sync(); // B wins the race to the server
  await engineA.sync(); // A discovers it lost

  final afterConflict = await engineA.store.byId('note-1');
  print('   A resolved to: ${afterConflict!.data['title']}');

  section('6. Field-level merge instead of all-or-nothing');
  final merging = LocalFirstSync(
    store: InMemoryLocalStore(),
    remote: backend,
    config: SyncConfig(
      conflictResolver: (local, remote) => SyncDocument(
        id: local.id,
        data: {
          ...remote.data,
          // Keep this device's title, take everything else from the server.
          'title': local.data['title'],
        },
        updatedAt: local.updatedAt,
      ),
    ),
  );
  await merging.store.upsert(_note('note-1', 'Merged title', at: DateTime.utc(2026, 1, 4)));
  await merging.sync();
  final merged = await merging.store.byId('note-1');
  print('   merged result: ${merged!.data['title']}');

  section('7. Delete on A — does it resurrect on B?');
  await engineA.delete('note-1', at: DateTime.utc(2026, 2, 1));
  await engineA.sync();
  print('   tombstone on the server: ${backend.peek('note-1')!.isDeleted}');

  // B still has the note and might push its stale copy.
  await engineB.write(_note('note-1', 'Stale copy on B', at: DateTime.utc(2026, 1, 10)));
  await engineB.sync();
  await engineA.sync();

  print('   server still deleted:  ${backend.peek('note-1')!.isDeleted}');
  print('   A still deleted:       ${(await engineA.store.byId('note-1'))!.isDeleted}');

  section('8. Attachments follow their record');
  final transport = _PrintingTransport();
  final attachments = AttachmentQueue(transport: transport, concurrency: 1);
  attachments.progress.listen((p) {
    print('   upload ${p.attachmentId}: ${(p.fraction * 100).round()}%');
  });

  final withFiles = LocalFirstSync(
    store: InMemoryLocalStore(),
    remote: backend,
    attachments: attachments,
  );
  attachments.add(Attachment(
    id: 'photo-1',
    recordId: 'note-1',
    localPath: '/data/photos/holiday.jpg',
    mimeType: 'image/jpeg',
  ));
  await attachments.drain();
  print('   uploaded to: ${attachments['photo-1']!.remoteUrl}');

  await withFiles.delete('note-1');
  final attachmentGone = attachments['photo-1'] == null;
  print('   after deleting the record, attachment removed: $attachmentGone');
  print('   remote delete called: ${transport.deleted}');

  section('9. Failing backend: backoff and recovery');
  final flaky = InMemoryRemoteStore(failuresBeforeSuccess: 2);
  final recovering = LocalFirstSync(
    store: InMemoryLocalStore(),
    remote: flaky,
    config: const SyncConfig(
      retryPolicy: RetryPolicy(
        maxAttempts: 4,
        initialDelay: Duration(milliseconds: 10),
        jitter: 0,
      ),
    ),
  );
  await recovering.write(_note('flaky-1', 'Survives outages'));

  // Fault injection counts remote calls, and each cycle makes several, so keep
  // syncing until the backend stops refusing. This is exactly what the engine's
  // own retry timer does in a real app.
  var attempts = 0;
  while (flaky.peek('flaky-1') == null && attempts < 8) {
    attempts++;
    final outcome = await recovering.sync();
    print('   attempt $attempts -> ${outcome.skippedBecauseOffline ? 'offline' : outcome}');
    print('      state: ${recovering.state.value.label}');
  }
  print('   recovered after $attempts attempt(s)');

  section('10. Tear down');
  await engineA.dispose();
  await engineB.dispose();
  await offlineEngine.dispose();
  await merging.dispose();
  await withFiles.dispose();
  await recovering.dispose();
  await attachments.dispose();
  await offline.dispose();
  print('   done.');
}

SyncDocument _note(String id, String title, {DateTime? at}) => SyncDocument(
      id: id,
      data: {'title': title, 'body': '...'},
      updatedAt: at ?? DateTime.now().toUtc(),
    );

void section(String title) {
  print('\n$title');
  print('-' * title.length);
}

/// Pretends to upload and delete files, printing what it does.
class _PrintingTransport implements AttachmentTransport {
  final List<String> deleted = [];

  @override
  Future<String> upload(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  }) async {
    for (var i = 1; i <= 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      onProgress?.call(i / 4);
    }
    return 'https://cdn.example.com/${attachment.id}';
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
}
