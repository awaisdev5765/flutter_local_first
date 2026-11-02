import 'sync_record.dart';

/// How the engine settles a record that changed both locally and remotely.
enum ConflictPolicy {
  /// The record with the newer [SyncRecord.updatedAt] wins. The default, and
  /// the right answer for most apps because it never loses the most recent
  /// user action.
  lastWriteWins,

  /// The backend version always wins. Choose when the server is authoritative
  /// (a shared document, a moderation flag).
  remoteWins,

  /// The local version always wins. Choose for device-owned data such as
  /// drafts or settings the user edited offline.
  localWins,

  /// Nothing is applied automatically. Every conflict is reported through
  /// [Conflict] and left for you to resolve.
  manual,
}

/// A conflict detected while pushing a local change that the backend had
/// already moved on from.
///
/// Emitted through the engine's event stream so you can log it, surface it, or
/// resolve it by hand when using [ConflictPolicy.manual].
class Conflict {
  /// Creates a conflict.
  const Conflict({
    required this.id,
    required this.local,
    required this.remote,
    required this.resolution,
  });

  /// The record id both sides disagree about.
  final String id;

  /// The version that was about to be pushed.
  final SyncDocument local;

  /// The version the backend already held.
  final SyncDocument remote;

  /// How the engine settled it.
  final ConflictResolution resolution;

  @override
  String toString() => 'Conflict($id, ${resolution.name})';
}

/// The outcome of settling a [Conflict].
enum ConflictResolution {
  /// The local version replaced the remote one.
  localWon,

  /// The remote version replaced the local one.
  remoteWon,

  /// Both versions were combined by a custom resolver.
  merged,

  /// The two versions were identical, so nothing happened.
  identical,

  /// Left untouched for the caller to resolve later.
  deferred;

  /// Whether the local store needs to be updated with the remote version.
  bool get requiresLocalUpdate =>
      this == ConflictResolution.remoteWon || this == ConflictResolution.merged;
}

/// Settles a conflict by returning the winning document.
///
/// Pass a custom resolver to `SyncConfig.conflictResolver` to implement
/// field-level merging such as "keep the remote title but the local body".
typedef ConflictResolver = SyncDocument Function(
  SyncDocument local,
  SyncDocument remote,
);

/// Applies a [ConflictPolicy] to a local/remote pair and reports the outcome.
///
/// Used internally by the engine, but public because it is genuinely useful on
/// its own: you can unit-test your merge rules without spinning up a store or a
/// transport.
ConflictResolution resolveConflict(
  ConflictPolicy policy, {
  required SyncDocument local,
  required SyncDocument remote,
}) {
  if (sameContent(local, remote)) return ConflictResolution.identical;

  switch (policy) {
    case ConflictPolicy.localWins:
      return ConflictResolution.localWon;
    case ConflictPolicy.remoteWins:
      return ConflictResolution.remoteWon;
    case ConflictPolicy.lastWriteWins:
      final localWins = !local.updatedAt.isBefore(remote.updatedAt);
      return localWins
          ? ConflictResolution.localWon
          : ConflictResolution.remoteWon;
    case ConflictPolicy.manual:
      return ConflictResolution.deferred;
  }
}

/// Returns the winning document for [policy].
///
/// For [ConflictPolicy.manual] this returns [local] unchanged so the caller can
/// decide what to do; the engine reports the conflict separately.
SyncDocument winnerFor(
  ConflictPolicy policy, {
  required SyncDocument local,
  required SyncDocument remote,
}) {
  switch (policy) {
    case ConflictPolicy.localWins:
      return local;
    case ConflictPolicy.remoteWins:
      return remote;
    case ConflictPolicy.lastWriteWins:
      return local.updatedAt.isBefore(remote.updatedAt) ? remote : local;
    case ConflictPolicy.manual:
      return local;
  }
}

/// Whether two documents carry the same payload and deletion state, ignoring
/// timestamps and revisions.
///
/// Used to avoid pointless writes and to stop a conflict being reported when
/// both sides already agree.
bool sameContent(SyncDocument a, SyncDocument b) {
  if (a.isDeleted != b.isDeleted) return false;
  if (a.data.length != b.data.length) return false;
  for (final entry in a.data.entries) {
    if (!b.data.containsKey(entry.key)) return false;
    if (b.data[entry.key] != entry.value) return false;
  }
  return true;
}
