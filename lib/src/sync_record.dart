/// The contract every synced record must satisfy.
///
/// A record is identified by [id], carries the moment it last changed locally
/// in [updatedAt], and signals deletion with a non-null [deletedAt] — a
/// *tombstone*. Tombstones matter: if you simply removed rows, a device that
/// was offline during the deletion would happily resurrect them on its next
/// push.
///
/// Implement this directly for full control, or use [SyncDocument] to sync
/// plain maps without writing a class.
abstract interface class SyncRecord {
  /// Stable identity. Must be unique and must survive reinstall, so generate
  /// it once on the device that creates the record rather than letting the
  /// server assign it.
  String get id;

  /// When this record was last modified locally. Drives conflict resolution,
  /// so it should be a wall-clock time in UTC.
  DateTime get updatedAt;

  /// Non-null when the record has been deleted locally. The record must stay
  /// in the store until the deletion has reached the backend.
  DateTime? get deletedAt;

  /// The record's payload, excluding sync bookkeeping. Round-tripped through
  /// the backend, so it must be JSON-encodable.
  Map<String, Object?> toJson();

  /// Whether this record is a tombstone. Implementations backed by a field
  /// should return `deletedAt != null`.
  bool get isDeleted;
}

/// A `Map`-backed [SyncRecord] for when you don't want to write a class.
///
/// Pair it with [SyncCodec] to move between your domain model and the wire
/// format, or use it on its own for config-like records and prototypes.
///
/// ```dart
/// final doc = SyncDocument(
///   id: 'note-1',
///   data: {'title': 'Shopping list'},
///   updatedAt: DateTime.now().toUtc(),
/// );
///
/// final renamed = doc.merge({'title': 'Groceries'}, at: DateTime.now().toUtc());
/// final deleted = doc.tombstone(DateTime.now().toUtc());
/// ```
class SyncDocument implements SyncRecord {
  /// Creates a document.
  SyncDocument({
    required this.id,
    Map<String, Object?> data = const {},
    required this.updatedAt,
    this.deletedAt,
    this.revision = 0,
    this.syncedAt,
  }) : data = Map.unmodifiable(data);

  /// Creates a document from a JSON payload, expecting `id`, `updatedAt`,
  /// `deletedAt`, `revision` and `data` keys (with [toEnvelope] as the
  /// inverse).
  factory SyncDocument.fromJson(Map<String, Object?> json) {
    final rawData = json['data'];
    return SyncDocument(
      id: json['id']! as String,
      data: rawData is Map
          ? rawData.map((key, value) => MapEntry(key.toString(), value))
          : const {},
      updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt']! as String).toUtc(),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      syncedAt: json['syncedAt'] == null
          ? null
          : DateTime.parse(json['syncedAt']! as String).toUtc(),
    );
  }

  @override
  final String id;

  /// The record's payload.
  final Map<String, Object?> data;

  @override
  final DateTime updatedAt;

  @override
  final DateTime? deletedAt;

  @override
  bool get isDeleted => deletedAt != null;

  /// Monotonically increasing counter bumped on every local write. Useful for
  /// diagnostics and for policies that prefer the record with more edits.
  final int revision;

  /// When this version was last acknowledged by the backend, or null while it
  /// still has unsynced local changes.
  final DateTime? syncedAt;

  /// Whether this document still has changes the backend has not accepted.
  bool get hasPendingChanges => syncedAt == null || updatedAt.isAfter(syncedAt!);

  @override
  Map<String, Object?> toJson() => Map<String, Object?>.from(data);

  /// Returns a copy with [data] merged on top of the existing payload, a fresh
  /// [at] timestamp and an incremented [revision].
  ///
  /// Pass `deleted: false` to resurrect a tombstone.
  SyncDocument merge(
    Map<String, Object?> data, {
    required DateTime at,
    bool? deleted,
  }) {
    return SyncDocument(
      id: id,
      data: {...this.data, ...data},
      updatedAt: at,
      deletedAt: switch (deleted) {
        true => deletedAt ?? at,
        false => null,
        null => deletedAt,
      },
      revision: revision + 1,
      syncedAt: null,
    );
  }

  /// Returns a tombstone for this document.
  ///
  /// The payload is preserved so a policy that prefers "local wins" can still
  /// resurrect the record with its original contents if the deletion loses.
  SyncDocument tombstone(DateTime at) => SyncDocument(
        id: id,
        data: data,
        updatedAt: at,
        deletedAt: at,
        revision: revision + 1,
        syncedAt: null,
      );

  /// Returns a copy marked as acknowledged by the backend.
  SyncDocument markSynced(DateTime at) => SyncDocument(
        id: id,
        data: data,
        updatedAt: updatedAt,
        deletedAt: deletedAt,
        revision: revision,
        syncedAt: at,
      );

  /// The full wire representation, including sync bookkeeping.
  Map<String, Object?> toEnvelope() => {
        'id': id,
        'data': data,
        'updatedAt': updatedAt.toIso8601String(),
        'deletedAt': deletedAt?.toIso8601String(),
        'revision': revision,
        'syncedAt': syncedAt?.toIso8601String(),
      };

  @override
  String toString() =>
      'SyncDocument($id, rev: $revision, updated: ${updatedAt.toIso8601String()}'
      '${isDeleted ? ', DELETED' : ''})';
}

/// Converts between your domain model and [SyncDocument].
///
/// Keeping this separate from [SyncRecord] means your model does not have to
/// know anything about syncing.
abstract class SyncCodec<T> {
  /// Creates a codec.
  const SyncCodec();

  /// Converts a domain object into a sync document.
  SyncDocument encode(T value);

  /// Converts a sync document back into a domain object.
  T decode(SyncDocument document);
}
