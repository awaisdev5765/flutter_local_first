# Changelog

## 0.1.0

Initial release.

### Added
- `LocalFirstSync` engine with a push/pull/resolve cycle, periodic syncing,
  reconnect syncing, debounced write-triggered syncing and shared in-flight
  cycles.
- `LocalStore` contract plus `InMemoryLocalStore`, including a guard that stops
  a concurrent local edit from being marked synced by a push already in flight.
- `RemoteStore` contract plus `InMemoryRemoteStore` with latency, fault
  injection and pagination.
- `BatchRemoteStore` for backends that can fetch records by id in one round
  trip, making conflict detection a single request.
- Tombstone support: deletions travel as records with `deletedAt`, with a
  configurable TTL before purge.
- Conflict resolution: `lastWriteWins`, `remoteWins`, `localWins`, `manual`, and
  custom field-level resolvers that take precedence over the policy.
- `RetryPolicy` with exponential backoff, jitter, a delay ceiling and
  retry-by-error-type.
- Attachment syncing: `AttachmentQueue` with concurrency limits, per-file retry,
  progress events and cascading deletes when a record is removed.
- Connectivity abstraction with `Stream`, `Manual`, `Probe` and `AlwaysOnline`
  implementations.
- Observability: a `ValueListenable<SyncState>` and a stream of nine typed
  `SyncEvent`s.
- 152 tests covering conflict policies, backoff, both in-memory adapters, the
  attachment queue and end-to-end engine behaviour including two-device
  convergence.
