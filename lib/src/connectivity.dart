import 'dart:async';

/// How the engine learns whether the device can reach the backend.
///
/// There is deliberately no built-in network dependency: the engine does not
/// know whether your server is on the internet, on the LAN, or in the same
/// process. Wire in whatever signal you already have.
///
/// ```dart
/// // With connectivity_plus
/// final monitor = StreamConnectivityMonitor(
///   () => Connectivity().onConnectivityChanged.map(
///     (results) => results.any((r) => r != ConnectivityResult.none),
///   ),
/// );
///
/// // Or trust your own transport
/// final monitor = ProbeConnectivityMonitor(probe: api.ping);
/// ```
abstract interface class ConnectivityMonitor {
  /// The current status. Should be cheap and safe to call often.
  bool get isOnline;

  /// Emits whenever connectivity changes. Emitting the current value on
  /// subscribe is allowed but not required.
  Stream<bool> get changes;

  /// Releases resources held by the monitor.
  Future<void> dispose();
}

/// A [ConnectivityMonitor] backed by any `Stream<bool>`.
class StreamConnectivityMonitor implements ConnectivityMonitor {
  /// Creates a stream-backed monitor.
  ///
  /// [source] is called once on construction, so it can safely reference
  /// objects that are expensive to build. [assumeOnline] sets the value
  /// reported before the first event arrives.
  StreamConnectivityMonitor(
    Stream<bool> Function() source, {
    bool assumeOnline = true,
  }) : _isOnline = assumeOnline {
    _subscription = source().listen(
      (online) {
        if (_isOnline == online) return;
        _isOnline = online;
        if (!_changes.isClosed) _changes.add(online);
      },
      onError: (Object _) {
        // A transport error is not proof of being offline; keep the last known
        // value rather than flapping the UI.
      },
    );
  }

  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  late final StreamSubscription<bool> _subscription;
  bool _isOnline;

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Forces a status value, for tests and for manual override switches.
  void set(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    if (!_changes.isClosed) _changes.add(online);
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    await _changes.close();
  }
}

/// A [ConnectivityMonitor] you drive by hand.
///
/// Ideal for tests, for a user-facing "work offline" switch, and for
/// server-reachability rather than device-reachability.
class ManualConnectivityMonitor implements ConnectivityMonitor {
  /// Creates a manual monitor.
  ManualConnectivityMonitor({bool initiallyOnline = true})
      : _isOnline = initiallyOnline;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  bool _isOnline;

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Flips the status and notifies listeners.
  void set(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    if (!_changes.isClosed) _changes.add(online);
  }

  /// Convenience for `set(false)`.
  void goOffline() => set(false);

  /// Convenience for `set(true)`.
  void goOnline() => set(true);

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}

/// A [ConnectivityMonitor] that treats a probe function as the source of truth.
///
/// Use this when "online" means "the server answered", which is usually what
/// you actually care about: a device can be on Wi-Fi and still not reach your
/// API.
class ProbeConnectivityMonitor implements ConnectivityMonitor {
  /// Creates a probe-backed monitor.
  ///
  /// [probe] should resolve to true when the backend is reachable and throw or
  /// resolve false when it is not. The result is re-checked every [interval].
  ProbeConnectivityMonitor({
    required Future<bool> Function() probe,
    Duration interval = const Duration(seconds: 30),
    bool assumeOnline = true,
  })  : _probe = probe,
        _isOnline = assumeOnline {
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  final Future<bool> Function() _probe;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  late final Timer _timer;
  bool _isOnline;

  @override
  bool get isOnline => _isOnline;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Runs the probe once and updates the status.
  Future<bool> refresh() async {
    bool result;
    try {
      result = await _probe();
    } on Object {
      result = false;
    }
    set(result);
    return result;
  }

  /// Forces a status value.
  void set(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    if (!_changes.isClosed) _changes.add(online);
  }

  @override
  Future<void> dispose() async {
    _timer.cancel();
    await _changes.close();
  }
}

/// A monitor that is always online. The default when you do not supply one.
class AlwaysOnlineMonitor implements ConnectivityMonitor {
  /// Creates an always-online monitor.
  const AlwaysOnlineMonitor();

  @override
  bool get isOnline => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();

  @override
  Future<void> dispose() async {}
}
