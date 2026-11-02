# 🔄 flutter_local_first

<p align="center">
  <b>Offline-first writes, eventual consistency, zero backend lock-in.</b><br/>
  A local-first sync engine for Flutter and Dart.
</p>

[![pub.dev](https://img.shields.io/badge/pub.dev-flutter__local__first-0175C2?logo=dart&logoColor=white)](https://pub.dev/packages/flutter_local_first)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.5%2B-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![tests](https://img.shields.io/badge/tests-152%20passing-brightgreen)](test)

---

Every app with a server eventually writes the same code: a queue of unsynced
changes, a way to detect deletions, something to stop two devices clobbering
each other, and retry logic for the flaky parts. It is fiddly, it is easy to get
subtly wrong, and the bugs it produces — lost edits, resurrected rows,
duplicates — show up in users' data.

**flutter_local_first** is that layer, written once and tested hard. You keep
your database and your backend; it brings the reconciliation.

```dart
final engine = LocalFirstSync(
  store: MySqliteStore(db),     // your database
  remote: MyRestStore(api),     // your backend
);

await engine.start();

// Instant, offline-safe. The UI never waits for the network.
await engine.write(SyncDocument(
  id: 'note-1',
  data: {'title': 'Groceries'},
  updatedAt: DateTime.now().toUtc(),
));

// Deletes travel as tombstones, so they cannot be undone by a stale device.
await engine.delete('note-1');
```

## The problem it solves

| Naive approach | What goes wrong |
|---|---|
| Upload immediately, mark synced | The request dies mid-flight and the edit is lost forever |
| Hard-delete rows | A device that was offline resurrects the row on its next push |
| "Send my latest version" | Two devices overwrite each other; the newer edit silently loses |
| Use the device clock as a cursor | A device with a skewed clock never sees other devices' writes |
| One request per record | A first sync with 5,000 rows melts the connection |

The engine addresses each of these directly, and its test suite asserts them.

## ✨ Features

- **Durable outbox** — a record stays pending until the backend accepts it, so a
  failed request never means a lost edit.
- **Tombstones** — deletions propagate as records with a `deletedAt` stamp, and
  are only purged after a configurable TTL.
- **Pluggable conflict resolution** — `lastWriteWins` (default), `remoteWins`,
  `localWins`, `manual`, or your own field-level merge function.
- **Server-clock cursors** — pulls always advance using the backend's time.
- **Batching and paging** — configurable push batch size and pull page size with
  a safety cap on pages per cycle.
- **Exponential backoff with jitter** — configurable attempts, delay growth,
  ceiling, and retry-by-error-type.
- **Attachment syncing** — a separate queue with concurrency limits, per-file
  retry, progress events, and cascading deletes when a record is removed.
- **Zero lock-in** — no database, network, or cloud dependency. Prism ships
  in-memory implementations of both sides so you can develop and test before the
  backend exists.
- **Observability** — a `ValueListenable<SyncState>` for your UI and a stream of
  typed events for logging.

## 📦 Install

```yaml
dependencies:
  flutter_local_first: ^0.1.0
```

## 🚀 Quick start

### 1. Provide the two adapters

A `LocalStore` over whatever you already use:

```dart
class MySqliteStore implements LocalStore {
  MySqliteStore(this.db);
  final Database db;

  @override
  Future<List<SyncDocument>> pendingChanges({int limit = 100}) async {
    final rows = await db.query(
      'notes',
      where: 'synced_at IS NULL OR updated_at > synced_at',
      orderBy: 'updated_at',
      limit: limit,
    );
    return rows.map(SyncDocument.fromJson).toList();
  }

  @override
  Future<void> markSynced(Iterable<String> ids, DateTime syncedAt) async {
    // Only clear the flag when the row has not changed since the push began.
    await db.update(
      'notes',
      {'synced_at': syncedAt.toIso8601String()},
      where: 'id IN (?) AND updated_at <= ?',
      whereArgs: [ids.toList(), syncedAt.toIso8601String()],
    );
  }

  // changedSince, byId, upsert, upsertAll, purgeTombstones, count, changes…
}
```

And a `RemoteStore` over your backend:

```dart
class MyRestStore implements RemoteStore {
  MyRestStore(this.api);
  final Api api;

  @override
  Future<PushResult> push(List<SyncDocument> documents) async {
    final response = await api.post('/sync/push', {
      'records': [for (final d in documents) d.toEnvelope()],
    });
    return PushResult(
      accepted: [...],
      rejected: {...},
      // The SERVER's clock, not the device's.
      serverTime: DateTime.parse(response['serverTime'] as String).toUtc(),
    );
  }

  @override
  Future<PullResult> pull({DateTime? since, int limit = 200, String? cursor}) async {
    /* … */
  }
}
```

### 2. Start the engine

```dart
final engine = LocalFirstSync(
  store: MySqliteStore(db),
  remote: MyRestStore(api),
  config: const SyncConfig(
    syncInterval: Duration(minutes: 2),
    conflictPolicy: ConflictPolicy.lastWriteWins,
  ),
);

await engine.start();   // syncs now, then on a timer, on reconnect, and on write
```

### 3. Write locally, never wait

```dart
await engine.write(document);          // durable immediately
await engine.writeAll(documents);      // batch
await engine.delete('note-1');         // becomes a tombstone
```

## 🔀 Conflict resolution

When a record changed on both sides, the policy decides. The default is
last-write-wins because it never discards the most recent user action:

```dart
SyncConfig(conflictPolicy: ConflictPolicy.lastWriteWins)  // default
SyncConfig(conflictPolicy: ConflictPolicy.remoteWins)     // server is authoritative
SyncConfig(conflictPolicy: ConflictPolicy.localWins)      // device owns the data
SyncConfig(conflictPolicy: ConflictPolicy.manual)         // report, don't resolve
```

For field-level merging, pass a resolver. It always takes precedence over the
policy:

```dart
SyncConfig(
  conflictResolver: (local, remote) => SyncDocument(
    id: local.id,
    data: {
      'title': remote.data['title'],   // server wins for this field
      'body': local.data['body'],      // device wins for this one
      'tags': {
        ...(remote.data['tags'] as Map),
        ...(local.data['tags'] as Map),
      },
    },
    updatedAt: local.updatedAt,
  ),
)
```

Every conflict is reported so you can log it or show a resolution UI:

```dart
engine.events.listen((event) {
  if (event is ConflictResolved) {
    debugPrint('${event.conflict.id}: ${event.conflict.resolution}');
  }
});
```

## 📎 Attachments

Files are large and fail differently from records, so they get their own queue
with independent retry and progress:

```dart
final queue = AttachmentQueue(
  transport: S3Transport(bucket: 'my-bucket'),
  concurrency: 2,                       // keep it low on mobile
  maxAttempts: 4,
);

queue.progress.listen((p) {
  print('${p.attachmentId}: ${(p.fraction * 100).round()}%');
});

queue.add(Attachment(
  id: 'att-1',
  recordId: 'note-42',
  localPath: '/data/photos/img.jpg',
  mimeType: 'image/jpeg',
));

await queue.drain();
```

Pass the queue to the engine and orphaned files are cleaned up automatically
when their record is deleted — locally and remotely:

```dart
LocalFirstSync(store: store, remote: remote, attachments: queue)
```

## 🌐 Connectivity

The engine does not assume you are online because you have Wi-Fi. Supply the
signal you actually care about:

```dart
// Trust a plugin
StreamConnectivityMonitor(
  () => Connectivity().onConnectivityChanged.map(
    (results) => results.any((r) => r != ConnectivityResult.none),
  ),
);

// Trust your server
ProbeConnectivityMonitor(probe: api.ping);

// Or drive it yourself (tests, or a "work offline" switch)
ManualConnectivityMonitor(initiallyOnline: false)..goOnline();
```

## 📊 Showing sync status

```dart
ValueListenableBuilder(
  valueListenable: engine.state,
  builder: (context, state, _) => Row(
    children: [
      Icon(state.isOnline ? Icons.cloud_done : Icons.cloud_off),
      Text(state.label),                       // "Up to date", "Offline", …
      if (state is Syncing && state.progress != null)
        LinearProgressIndicator(value: state.progress),
      if (state is Offline)
        Text('${state.pendingChanges} changes waiting'),
    ],
  ),
)
```

## 🧪 Testing without a backend

Both sides ship in-memory implementations, so a full sync is testable with no
network and no server:

```dart
final store = InMemoryLocalStore();
final remote = InMemoryRemoteStore(
  failuresBeforeSuccess: 2,                  // simulate a flaky connection
  latency: const Duration(milliseconds: 50),
);
final engine = LocalFirstSync(store: store, remote: remote);

await engine.write(document);
final outcome = await engine.sync();

expect(outcome.pushed, 1);
expect(remote.peek('note-1')!.data['title'], 'Groceries');
```

You can also assert exactly what a device uploaded, because
`InMemoryRemoteStore.received` records every push in order.

## 🔌 Optional: batch conflict checks

By default the engine detects conflicts by paging recent server changes. If your
backend can fetch records by id in one request, implement `BatchRemoteStore` and
every push costs one extra round trip instead of many:

```dart
class FirestoreRemote implements BatchRemoteStore {
  @override
  Future<Map<String, SyncDocument>> getMany(List<String> ids) async {
    final snaps = await _col.where(FieldPath.documentId, whereIn: ids).get();
    return {for (final s in snaps.docs) s.id: SyncDocument.fromJson(s.data())};
  }
  // …push, pull, purgeTombstones…
}
```

## 📖 API overview

| Type | Purpose |
|---|---|
| `LocalFirstSync` | The engine: `start`, `stop`, `sync`, `write`, `writeAll`, `delete`, `purgeTombstones`, `state`, `events`, `stats` |
| `SyncRecord` / `SyncDocument` | The record contract, plus a map-backed implementation |
| `SyncCodec` | Converts between your domain model and a `SyncDocument` |
| `LocalStore` / `InMemoryLocalStore` | Local persistence contract and a reference implementation |
| `RemoteStore` / `InMemoryRemoteStore` | Backend contract and a testable backend with fault injection |
| `BatchRemoteStore` | Optional batch-get for cheaper conflict detection |
| `SyncConfig` | Batching, policy, resolver, retry, timers, tombstone TTL |
| `ConflictPolicy` / `ConflictResolver` / `Conflict` | Conflict handling |
| `RetryPolicy` | Attempts, exponential backoff, jitter, retry-by-type |
| `ConnectivityMonitor` (+ 4 implementations) | Online/offline signal |
| `Attachment` / `AttachmentQueue` / `AttachmentTransport` | Binary asset sync |
| `SyncState` (`Idle`/`Syncing`/`Offline`/`Failed`/`Stopped`) | UI state |
| `SyncStats` | Counters |
| `SyncEvent` (9 types) | Observability stream |

## 🧭 How it works

A cycle runs three steps:

1. **Push** — pending local changes are fetched in batches, conflicts are settled
   against the server's current version, and the survivors are uploaded. Accepted
   ids are marked synced; rejected ones stay pending.
2. **Pull** — changes newer than the stored cursor are fetched page by page and
   written locally.
3. **Resolve** — anything that changed on both sides is settled by policy and
   reported as an event.

Push runs first on purpose. Once the server has acknowledged this device's
writes, the cursor can safely advance past them, so the device does not
immediately pull its own data back.

## ⚖️ Design notes and limits

- **Tombstones need a TTL longer than your worst offline window.** Purging too
  early lets a long-offline device resurrect deleted rows. The default is 90
  days.
- **Last-write-wins needs roughly correct clocks.** If devices can be wildly
  wrong, prefer `remoteWins` or a server-stamped `updatedAt`.
- **The engine is not a database.** It assumes your `LocalStore` is transactional
  enough that a batch write either lands or does not.
- **No built-in encryption.** Encrypt at the store or transport layer; see the
  `SyncCodec` hook for a natural place to do it.

## ☕ Support

If this package saves you a week of sync bugs, you can buy me a coffee:

<p align="center">
  <a href="https://buymeacoffee.com/awaisdev572">
    <img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=awaisdev572&button_colour=FFDD00&font_colour=000000&font_family=Lato&outline_colour=000000&coffee_colour=ffffff" alt="Buy Me A Coffee">
  </a>
</p>

## 📄 License

MIT — see [LICENSE](LICENSE).
