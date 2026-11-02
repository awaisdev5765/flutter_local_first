/// A local-first sync engine for Flutter and Dart.
///
/// **Local-first** means the local database is the source of truth for the UI.
/// Writes complete immediately — offline, on a plane, behind a captive portal —
/// and the engine reconciles with your backend in the background. Users get an
/// app that never blocks on the network; you get eventual consistency without
/// writing the hard parts yourself.
///
/// ## What you provide
///
/// - A [LocalStore] over the database you already use (SQLite, Drift, Isar,
///   Hive...). See [InMemoryLocalStore] for a reference implementation.
/// - A [RemoteStore] over your backend (Firestore, Supabase, REST, GraphQL...).
///   See [InMemoryRemoteStore] for a testing backend with fault injection.
///
/// ## What you get
///
/// - A durable **outbox**: no local edit is marked synced until the backend
///   accepts it, so nothing is lost when a request dies mid-flight.
/// - **Tombstones** so deletions propagate instead of being resurrected by a
///   device that was offline when the delete happened.
/// - **Pluggable conflict resolution** — last-write-wins by default, with
///   remote-wins, local-wins, manual, or a custom field-level merge.
/// - **Server-clock cursors** so a device with a skewed clock cannot skip
///   another device's writes.
/// - **Attachment syncing** with concurrency limits, retry and progress.
/// - **Observability** — a state listenable for your UI and an event stream for
///   logs and diagnostics.
///
/// ## Quick start
///
/// ```dart
/// final engine = LocalFirstSync(
///   store: MySqliteLocalStore(db),
///   remote: MyRestRemoteStore(api),
/// );
///
/// await engine.start();
///
/// // Instant, offline-safe write:
/// await engine.write(SyncDocument(
///   id: 'note-1',
///   data: {'title': 'Groceries'},
///   updatedAt: DateTime.now().toUtc(),
/// ));
///
/// // Delete safely — travels as a tombstone:
/// await engine.delete('note-1');
/// ```
///
/// ## A note on ordering
///
/// Push runs before pull inside a cycle. That ordering is what lets the engine
/// advance its cursor safely: by the time it asks "what changed since X?", its
/// own writes are already acknowledged, so it will not pull its own data back.
library;

export 'src/attachments.dart'
    show
        Attachment,
        AttachmentProgress,
        AttachmentQueue,
        AttachmentState,
        AttachmentTransport;
export 'src/backoff.dart' show RetryPolicy;
export 'src/conflict.dart'
    show
        Conflict,
        ConflictPolicy,
        ConflictResolution,
        ConflictResolver,
        resolveConflict,
        sameContent,
        winnerFor;
export 'src/connectivity.dart'
    show
        AlwaysOnlineMonitor,
        ConnectivityMonitor,
        ManualConnectivityMonitor,
        ProbeConnectivityMonitor,
        StreamConnectivityMonitor;
export 'src/engine.dart' show LocalFirstSync, SyncOutcome, ValueListenable;
export 'src/local_store.dart' show InMemoryLocalStore, LocalStore;
export 'src/remote_store.dart'
    show
        BatchRemoteStore,
        InMemoryRemoteStore,
        PullResult,
        PushResult,
        RemoteStore,
        RemoteUnavailable;
export 'src/sync_config.dart' show SyncConfig;
export 'src/sync_event.dart'
    show
        ConflictResolved,
        ConnectivityChanged,
        LocalChangeReason,
        LocalRecordChanged,
        RecordsPulled,
        RecordsPushed,
        SyncCompleted,
        SyncEvent,
        SyncFailed,
        SyncStarted,
        TombstonesPurged;
export 'src/sync_record.dart' show SyncCodec, SyncDocument, SyncRecord;
export 'src/sync_state.dart'
    show
        Failed,
        Idle,
        Offline,
        Stopped,
        SyncPhase,
        SyncState,
        SyncStats,
        Syncing;
