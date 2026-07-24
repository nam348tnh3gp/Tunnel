import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class TunnelTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    // Không làm gì, chỉ giữ service sống
    await WakelockPlus.enable();
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Không cần xử lý
  }

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