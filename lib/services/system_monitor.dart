import 'dart:async';

import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter/foundation.dart';

/// CPU / temperature readout. Exposed as ValueNotifiers so only the tiny
/// widgets that show them rebuild, and it can be paused in the background.
class SystemMonitor {
  final ValueNotifier<String> cpu = ValueNotifier('CPU: …');
  final ValueNotifier<String> temp = ValueNotifier('Temp: …');

  Timer? _timer;
  bool _busy = false;

  void start() {
    if (_timer != null) return;
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final PerformanceInfo perf = await DeviceInfoCe.performanceInfo();
      final double c = (perf.cpuUsage ?? 0) * 100;
      final double t = perf.temperature ?? 0;
      cpu.value = 'CPU: ${c.toStringAsFixed(1)}%';
      temp.value = 'Temp: ${t.toStringAsFixed(1)} °C';
    } catch (_) {
      cpu.value = 'CPU: N/A';
      temp.value = 'Temp: N/A';
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    stop();
    cpu.dispose();
    temp.dispose();
  }
}
