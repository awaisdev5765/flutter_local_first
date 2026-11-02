import 'dart:async';

/// Where an attachment is in its lifecycle.
enum AttachmentState {
  /// Recorded locally, not yet uploaded.
  pending,

  /// Upload is in flight.
  uploading,

  /// Uploaded; [Attachment.remoteUrl] is populated.
  uploaded,

  /// Download is in flight.
  downloading,

  /// Available locally.
  cached,

  /// The last attempt failed; see [Attachment.lastError].
  failed,
}

/// A binary asset that travels alongside its record.
///
/// Attachments are synced separately from records because they are large and
/// fail differently: a 4 KB record push is all-or-nothing, whereas a 40 MB
/// photo benefits from independent progress, resumption and retry.
class Attachment {
  /// Creates an attachment.
  Attachment({
    required this.id,
    required this.recordId,
    this.localPath,
    this.remoteUrl,
    this.mimeType,
    this.sizeInBytes = 0,
    this.state = AttachmentState.pending,
    this.attempts = 0,
    this.lastError,
    this.checksum,
  });

  /// Stable identity. Must be unique across devices.
  final String id;

  /// The record id this attachment belongs to. When the record is deleted, its
  /// attachments are deleted too.
  final String recordId;

  /// Path on this device, or null when the file exists only remotely.
  final String? localPath;

  /// URL or backend key once uploaded, or null while local-only.
  final String? remoteUrl;

  /// MIME type, forwarded to the backend so Content-Type is correct.
  final String? mimeType;

  /// Size in bytes, for progress reporting and storage budgeting.
  final int sizeInBytes;

  /// Current lifecycle state.
  AttachmentState state;

  /// How many upload or download attempts have been made.
  int attempts;

  /// The error from the last failed attempt, if any.
  Object? lastError;

  /// Optional content hash, used to skip re-uploading identical bytes.
  final String? checksum;

  /// Whether the attachment still needs uploading.
  bool get needsUpload => localPath != null && remoteUrl == null;

  /// Whether the attachment is fully synced.
  bool get isSynced => remoteUrl != null;

  /// A copy with selected fields replaced.
  Attachment copyWith({
    String? localPath,
    String? remoteUrl,
    AttachmentState? state,
    int? attempts,
    Object? lastError,
    String? checksum,
    bool clearError = false,
  }) {
    return Attachment(
      id: id,
      recordId: recordId,
      localPath: localPath ?? this.localPath,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      mimeType: mimeType,
      sizeInBytes: sizeInBytes,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      lastError: clearError ? null : (lastError ?? this.lastError),
      checksum: checksum ?? this.checksum,
    );
  }

  @override
  String toString() => 'Attachment($id for $recordId, ${state.name})';
}

/// The transfer primitives an [AttachmentQueue] needs from your backend.
abstract interface class AttachmentTransport {
  /// Uploads [attachment] and resolves with the remote URL or key.
  Future<String> upload(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  });

  /// Downloads [attachment] and resolves with the local file path.
  Future<String> download(
    Attachment attachment, {
    void Function(double progress)? onProgress,
  });

  /// Removes the remote copy. Called when a record is deleted.
  Future<void> delete(Attachment attachment);
}

/// Progress for a single attachment transfer.
class AttachmentProgress {
  /// Creates a progress event.
  const AttachmentProgress({
    required this.attachmentId,
    required this.recordId,
    required this.fraction,
    required this.state,
  });

  /// The attachment being transferred.
  final String attachmentId;

  /// Its owning record.
  final String recordId;

  /// Transfer progress in 0..1.
  final double fraction;

  /// Current state.
  final AttachmentState state;

  @override
  String toString() => 'AttachmentProgress($attachmentId, '
      '${(fraction * 100).round()}%, ${state.name})';
}

/// Queues attachment uploads and downloads with retry and progress.
class AttachmentQueue {
  /// Creates an attachment queue.
  AttachmentQueue({
    required this.transport,
    this.concurrency = 2,
    this.maxAttempts = 4,
    this.baseRetryDelay = const Duration(seconds: 3),
  }) : assert(concurrency > 0, 'concurrency must be at least 1');

  /// Performs the actual transfers.
  final AttachmentTransport transport;

  /// How many transfers may run at once.
  final int concurrency;

  /// Attempts per attachment before it is parked in [AttachmentState.failed].
  final int maxAttempts;

  /// Base delay for exponential retry backoff.
  final Duration baseRetryDelay;

  final Map<String, Attachment> _attachments = {};

  /// Last fraction reported per attachment, so completion is not duplicated.
  final Map<String, double> _lastFraction = {};

  final StreamController<AttachmentProgress> _progress =
      StreamController<AttachmentProgress>.broadcast();
  final StreamController<Attachment> _completed =
      StreamController<Attachment>.broadcast();

  /// Adds or replaces an attachment in the queue.
  void add(Attachment attachment) {
    _attachments[attachment.id] = attachment;
  }

  /// Adds several attachments at once.
  void addAll(Iterable<Attachment> attachments) {
    for (final attachment in attachments) {
      add(attachment);
    }
  }

  /// The current attachment, or null.
  Attachment? operator [](String id) => _attachments[id];

  /// Every queued attachment.
  List<Attachment> get all => _attachments.values.toList(growable: false);

  /// Attachments that still need uploading.
  List<Attachment> get pendingUploads => _attachments.values
      .where((a) => a.needsUpload && a.state != AttachmentState.failed)
      .toList(growable: false);

  /// Attachments that have failed permanently.
  List<Attachment> get failed => _attachments.values
      .where((a) => a.state == AttachmentState.failed)
      .toList(growable: false);

  /// Progress events for every transfer.
  Stream<AttachmentProgress> get progress => _progress.stream;

  /// Fires once per attachment that finishes uploading successfully.
  Stream<Attachment> get completed => _completed.stream;

  /// Uploads every pending attachment, respecting [concurrency].
  ///
  /// Attachments that exhaust [maxAttempts] are left in
  /// [AttachmentState.failed] rather than thrown, so one bad file cannot abort
  /// an entire sync.
  Future<void> drain() async {
    final queue = pendingUploads;
    if (queue.isEmpty) return;

    var cursor = 0;
    Attachment? next() => cursor < queue.length ? queue[cursor++] : null;

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency && i < queue.length; i++) {
      workers.add(_worker(next));
    }
    await Future.wait(workers);
  }

  Future<void> _worker(Attachment? Function() next) async {
    while (true) {
      final attachment = next();
      if (attachment == null) return;

      var attempt = 0;
      var succeeded = false;
      while (attempt < maxAttempts && !succeeded) {
        attempt++;
        try {
          _update(attachment, state: AttachmentState.uploading, attempts: attempt);
          final url = await transport.upload(
            attachment,
            onProgress: (fraction) => _emitProgress(attachment, fraction),
          );
          final uploaded = attachment.copyWith(
            remoteUrl: url,
            state: AttachmentState.uploaded,
            attempts: attempt,
            clearError: true,
          );
          _attachments[attachment.id] = uploaded;
          // Emit a final 1.0 only if the transport did not already report it,
          // so listeners never see 100% twice.
          if (_lastFraction[uploaded.id] != 1) _emitProgress(uploaded, 1);
          if (!_completed.isClosed) _completed.add(uploaded);
          succeeded = true;
        } on Object catch (error) {
          _update(
            attachment,
            state: attempt >= maxAttempts
                ? AttachmentState.failed
                : AttachmentState.pending,
            attempts: attempt,
            lastError: error,
          );
          if (attempt < maxAttempts) {
            await Future<void>.delayed(baseRetryDelay * attempt);
          }
        }
      }
    }
  }

  /// Deletes an attachment locally and, when uploaded, remotely.
  Future<void> remove(String id) async {
    _lastFraction.remove(id);
    final attachment = _attachments.remove(id);
    if (attachment == null) return;
    if (attachment.isSynced) {
      await transport.delete(attachment);
    }
  }

  /// Deletes every attachment belonging to [recordId], locally and remotely.
  Future<void> removeForRecord(String recordId) async {
    final ids = _attachments.values
        .where((a) => a.recordId == recordId)
        .map((a) => a.id)
        .toList();
    for (final id in ids) {
      await remove(id);
    }
  }

  /// Clears the failed flag so attachments are retried on the next drain.
  void retryFailed() {
    for (final entry in _attachments.entries.toList()) {
      if (entry.value.state != AttachmentState.failed) continue;
      _attachments[entry.key] = entry.value.copyWith(
        state: AttachmentState.pending,
        attempts: 0,
        clearError: true,
      );
    }
  }

  /// Releases the progress streams.
  Future<void> dispose() async {
    await _progress.close();
    await _completed.close();
  }

  void _update(
    Attachment attachment, {
    required AttachmentState state,
    int? attempts,
    Object? lastError,
  }) {
    _attachments[attachment.id] = attachment.copyWith(
      state: state,
      attempts: attempts,
      lastError: lastError,
    );
  }

  void _emitProgress(Attachment attachment, double fraction) {
    _lastFraction[attachment.id] = fraction;
    if (_progress.isClosed) return;
    _progress.add(AttachmentProgress(
      attachmentId: attachment.id,
      recordId: attachment.recordId,
      fraction: fraction.clamp(0.0, 1.0),
      state: attachment.state,
    ));
  }
}
