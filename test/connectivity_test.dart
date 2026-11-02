import 'dart:async';

import 'package:flutter_local_first/flutter_local_first.dart';
import 'package:test/test.dart';

void main() {
  group('ManualConnectivityMonitor', () {
    test('starts in the requested state', () {
      expect(ManualConnectivityMonitor().isOnline, isTrue);
      expect(ManualConnectivityMonitor(initiallyOnline: false).isOnline, isFalse);
    });

    test('emits only on change', () async {
      final monitor = ManualConnectivityMonitor();
      addTearDown(monitor.dispose);
      final events = <bool>[];
      final subscription = monitor.changes.listen(events.add);
      addTearDown(subscription.cancel);

      monitor.goOffline();
      monitor.goOffline(); // duplicate, ignored
      monitor.goOnline();
      await Future<void>.delayed(Duration.zero);

      expect(events, [false, true]);
      expect(monitor.isOnline, isTrue);
    });
  });

  group('StreamConnectivityMonitor', () {
    test('tracks the source stream', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final monitor = StreamConnectivityMonitor(() => controller.stream);
      addTearDown(monitor.dispose);

      final events = <bool>[];
      final subscription = monitor.changes.listen(events.add);
      addTearDown(subscription.cancel);

      controller.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(monitor.isOnline, isFalse);

      controller.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(monitor.isOnline, isTrue);
      expect(events, [false, true]);
    });

    test('honours assumeOnline before the first event', () {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final monitor = StreamConnectivityMonitor(
        () => controller.stream,
        assumeOnline: false,
      );
      addTearDown(monitor.dispose);
      expect(monitor.isOnline, isFalse);
    });

    test('suppresses duplicate events', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final monitor = StreamConnectivityMonitor(() => controller.stream);
      addTearDown(monitor.dispose);

      final events = <bool>[];
      final subscription = monitor.changes.listen(events.add);
      addTearDown(subscription.cancel);

      controller.add(false);
      controller.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(events, [false]);
    });

    test('a source error keeps the last known value', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final monitor = StreamConnectivityMonitor(() => controller.stream);
      addTearDown(monitor.dispose);

      controller.addError(StateError('network down'));
      await Future<void>.delayed(Duration.zero);
      expect(monitor.isOnline, isTrue, reason: 'an error is not proof of offline');
    });
  });

  group('ProbeConnectivityMonitor', () {
    test('refresh reflects a successful probe', () async {
      final monitor = ProbeConnectivityMonitor(
        probe: () async => true,
        interval: const Duration(hours: 1),
      );
      addTearDown(monitor.dispose);

      expect(await monitor.refresh(), isTrue);
      expect(monitor.isOnline, isTrue);
    });

    test('a throwing probe counts as offline', () async {
      final monitor = ProbeConnectivityMonitor(
        probe: () async => throw StateError('unreachable'),
        interval: const Duration(hours: 1),
      );
      addTearDown(monitor.dispose);

      expect(await monitor.refresh(), isFalse);
      expect(monitor.isOnline, isFalse);
    });

    test('emits when the probe result changes', () async {
      var result = true;
      final monitor = ProbeConnectivityMonitor(
        probe: () async => result,
        interval: const Duration(hours: 1),
      );
      addTearDown(monitor.dispose);

      final events = <bool>[];
      final subscription = monitor.changes.listen(events.add);
      addTearDown(subscription.cancel);

      result = false;
      await monitor.refresh();
      await Future<void>.delayed(Duration.zero);

      expect(events, [false]);
    });
  });

  group('AlwaysOnlineMonitor', () {
    test('is always online and never emits', () async {
      const monitor = AlwaysOnlineMonitor();
      expect(monitor.isOnline, isTrue);
      expect(await monitor.changes.isEmpty, isTrue);
      await monitor.dispose();
    });
  });
}
