import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  group('Attachment', () {
    test('needsUpload is true only for a local-only file', () {
      final localOnly = Attachment(id: 'a', recordId: 'r', localPath: '/x');
      expect(localOnly.needsUpload, isTrue);
      expect(localOnly.isSynced, isFalse);

      final remoteOnly = Attachment(id: 'a', recordId: 'r', remoteUrl: 'https://x');
      expect(remoteOnly.needsUpload, isFalse);
      expect(remoteOnly.isSynced, isTrue);

      final both =
          Attachment(id: 'a', recordId: 'r', localPath: '/x', remoteUrl: 'https://x');
      expect(both.needsUpload, isFalse);
      expect(both.isSynced, isTrue);
    });

    test('copyWith replaces selected fields', () {
      final original = Attachment(id: 'a', recordId: 'r', localPath: '/x');
      final updated = original.copyWith(
        remoteUrl: 'https://y',
        state: AttachmentState.uploaded,
        attempts: 2,
      );
      expect(updated.remoteUrl, 'https://y');
      expect(updated.state, AttachmentState.uploaded);
      expect(updated.attempts, 2);
      expect(updated.localPath, '/x');
      expect(updated.id, 'a');
    });

    test('copyWith can clear a previous error', () {
      final failed = Attachment(
        id: 'a',
        recordId: 'r',
        localPath: '/x',
        lastError: StateError('boom'),
      );
      expect(failed.copyWith(clearError: true).lastError, isNull);
      expect(failed.copyWith().lastError, isA<StateError>());
    });
  });

  group('AttachmentQueue', () {
    late _FakeTransport transport;
    late AttachmentQueue queue;

    setUp(() {
      transport = _FakeTransport();
      queue = AttachmentQueue(
        transport: transport,
        concurrency: 2,
        maxAttempts: 3,
        baseRetryDelay: Duration.zero,
      );
    });

    tearDown(() async {
      await queue.dispose();
      await transport.dispose();
    });

    test('drains pending uploads', () async {
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      queue.add(Attachment(id: 'a2', recordId: 'r1', localPath: '/b'));

      await queue.drain();

      expect(transport.uploaded, containsAll(['a1', 'a2']));
      expect(queue['a1']!.state, AttachmentState.uploaded);
      expect(queue['a1']!.remoteUrl, isNotNull);
      expect(queue.pendingUploads, isEmpty);
    });

    test('already-uploaded attachments are skipped', () async {
      queue.add(Attachment(
        id: 'a1',
        recordId: 'r1',
        localPath: '/a',
        remoteUrl: 'https://done',
      ));

      await queue.drain();

      expect(transport.uploaded, isEmpty);
    });

    test('emits progress for each transfer', () async {
      final progress = <AttachmentProgress>[];
      final subscription = queue.progress.listen(progress.add);
      addTearDown(subscription.cancel);

      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      await queue.drain();
      await Future<void>.delayed(Duration.zero);

      expect(progress, isNotEmpty);
      expect(progress.last.fraction, 1);
      expect(progress.last.attachmentId, 'a1');
      expect(progress.last.recordId, 'r1');
    });

    test('emits completed for successful uploads', () async {
      final completed = <Attachment>[];
      final subscription = queue.completed.listen(completed.add);
      addTearDown(subscription.cancel);

      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      await queue.drain();
      await Future<void>.delayed(Duration.zero);

      expect(completed.single.id, 'a1');
    });

    test('retries a failing upload and then succeeds', () async {
      transport.failuresBeforeSuccess = 2;
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));

      await queue.drain();

      expect(transport.uploaded, ['a1']);
      expect(queue['a1']!.state, AttachmentState.uploaded);
      expect(queue['a1']!.attempts, 3);
    });

    test('parks an attachment as failed after exhausting attempts', () async {
      transport.failuresBeforeSuccess = 99;
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));

      await queue.drain();

      expect(queue['a1']!.state, AttachmentState.failed);
      expect(queue['a1']!.lastError, isNotNull);
      expect(queue.failed, hasLength(1));
    });

    test('one bad attachment does not abort the others', () async {
      transport.failOnly.add('a2');
      transport.failuresBeforeSuccess = 99;
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      queue.add(Attachment(id: 'a2', recordId: 'r1', localPath: '/b'));

      await queue.drain();

      expect(queue['a1']!.state, AttachmentState.uploaded);
      expect(queue['a2']!.state, AttachmentState.failed);
    });

    test('retryFailed makes failed attachments eligible again', () async {
      transport.failuresBeforeSuccess = 99;
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      await queue.drain();
      expect(queue.failed, hasLength(1));

      transport.failuresBeforeSuccess = 0;
      queue.retryFailed();
      await queue.drain();

      expect(queue['a1']!.state, AttachmentState.uploaded);
      expect(queue.failed, isEmpty);
    });

    test('remove deletes an uploaded attachment remotely', () async {
      queue.add(Attachment(
        id: 'a1',
        recordId: 'r1',
        localPath: '/a',
        remoteUrl: 'https://done',
      ));

      await queue.remove('a1');

      expect(queue['a1'], isNull);
      expect(transport.deleted, ['a1']);
    });

    test('remove of a never-uploaded attachment does not call the transport',
        () async {
      queue.add(Attachment(id: 'a1', recordId: 'r1', localPath: '/a'));
      await queue.remove('a1');
      expect(transport.deleted, isEmpty);
    });

    test('removeForRecord deletes every attachment for a record', () async {
      queue.add(Attachment(
        id: 'a1',
        recordId: 'r1',
        localPath: '/a',
        remoteUrl: 'https://x/1',
      ));
      queue.add(Attachment(
        id: 'a2',
        recordId: 'r1',
        localPath: '/b',
        remoteUrl: 'https://x/2',
      ));
      queue.add(Attachment(
        id: 'a3',
        recordId: 'other',
        localPath: '/c',
        remoteUrl: 'https://x/3',
      ));

      await queue.removeForRecord('r1');

      expect(queue['a1'], isNull);
      expect(queue['a2'], isNull);
      expect(queue['a3'], isNotNull);
      expect(transport.deleted, containsAll(['a1', 'a2']));
      expect(transport.deleted, isNot(contains('a3')));
    });

    test('addAll queues several attachments', () {
      queue.addAll([
        Attachment(id: 'a1', recordId: 'r', localPath: '/a'),
        Attachment(id: 'a2', recordId: 'r', localPath: '/b'),
      ]);
      expect(queue.all, hasLength(2));
      expect(queue.pendingUploads, hasLength(2));
    });

    test('concurrency of one still drains everything', () async {
      final serial = AttachmentQueue(
        transport: transport,
        concurrency: 1,
        baseRetryDelay: Duration.zero,
      );
      addTearDown(serial.dispose);
      for (var i = 0; i < 4; i++) {
        serial.add(Attachment(id: 'a$i', recordId: 'r', localPath: '/$i'));
      }
      await serial.drain();
      expect(serial.pendingUploads, isEmpty);
      expect(transport.uploaded, hasLength(4));
    });

    test('a zero concurrency queue is rejected', () {
      expect(
        () => AttachmentQueue(transport: transport, concurrency: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

class _FakeTransport implements AttachmentTransport {
  final List<String> uploaded = [];
  final List<String> deleted = [];
  final Set<String> failOnly = {};
  int failuresBeforeSuccess = 0;

  /// Nothing to release: this fake holds no subscriptions. A single
  /// subscription StreamController would be a trap here, because closing one
  /// nothing ever listens to never completes its future.
  Future<void> dispose() async {}

  @override
  Future<String> upload(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.5);
    final shouldFail = failOnly.contains(attachment.id) ||
        (failOnly.isEmpty && failuresBeforeSuccess > 0);
    if (shouldFail) {
      if (failuresBeforeSuccess > 0) failuresBeforeSuccess--;
      throw StateError('upload failed for ${attachment.id}');
    }
    onProgress?.call(1);
    uploaded.add(attachment.id);
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
}
