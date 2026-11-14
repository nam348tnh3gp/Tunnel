import 'dart:async';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Entry point of the foreground service isolate.
@pragma('vm:entry-point')
void startTunnelService() {
  FlutterForegroundTask.setTaskHandler(TunnelTaskHandler());
}

class TunnelTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    // Keep the CPU awake while the service is running.
    await WakelockPlus.enable();
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {}

  @override
  Future<void> onStop(DateTime timestamp) async {
    await WakelockPlus.disable();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await WakelockPlus.disable();
  }

  @override
  void onButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}
