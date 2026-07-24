import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class TunnelTaskHandler extends TaskHandler {
  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  bool _isRunning = false;
  String? _binaryPath;

  @override
  Future<void> onStart(DateTime timestamp, Map<String, dynamic>? params) async {
    // 1. Acquire WakeLock
    await WakelockPlus.enable();

    // 2. Lấy tham số từ UI
    _binaryPath = params?['binaryPath'] as String?;
    if (_binaryPath == null || _binaryPath!.isEmpty) {
      sendLog('❌ Binary path not provided');
      await stopService();
      return;
    }

    final token = params?['token'] as String? ?? '';
    final port = params?['port'] as int? ?? 8080;
    final useTryMode = params?['useTryMode'] as bool? ?? false;
    final customArgs = params?['customArgs'] as List<String>? ?? [];
    final useQuic = params?['useQuic'] as bool? ?? true;
    final usePostQuantum = params?['usePostQuantum'] as bool? ?? false;
    final useMetrics = params?['useMetrics'] as bool? ?? true;
    final region = params?['region'] as String? ?? '';
    final edgeIpVersion = params?['edgeIpVersion'] as String? ?? 'auto';
    final customHostname = params?['customHostname'] as String? ?? '';

    // 3. Xây dựng command
    List<String> args = [];
    if (useTryMode) {
      args.addAll(['tunnel', '--url', 'http://localhost:$port']);
    } else {
      if (token.isEmpty) {
        sendLog('❌ Token is required');
        await stopService();
        return;
      }
      args.addAll(['tunnel', 'run', '--token', token]);
    }

    if (customArgs.isNotEmpty) args.addAll(customArgs);
    if (!useQuic) args.addAll(['--protocol', 'http2']);
    if (usePostQuantum) args.add('--post-quantum');
    if (!useMetrics) args.add('--management-diagnostics=false');
    if (region.isNotEmpty) args.addAll(['--region', region]);
    if (edgeIpVersion != 'auto') args.addAll(['--edge-ip-version', edgeIpVersion]);
    if (customHostname.isNotEmpty) args.addAll(['--hostname', customHostname]);

    sendLog('📋 Command: $_binaryPath ${args.join(' ')}');

    // 4. Khởi chạy process
    try {
      final env = {
        'PATH': '/system/bin:/system/xbin:/vendor/bin',
        'ANDROID_ROOT': '/system',
        'LD_LIBRARY_PATH': '/system/lib64:/vendor/lib64',
      };

      _process = await Process.start(_binaryPath!, args, runInShell: false, environment: env);
      _isRunning = true;
      sendLog('✅ Tunnel started (PID: ${_process!.pid})');
      updateNotification('Tunnel is running', 'Connecting...');

      _stdoutSub = _process!.stdout.transform(utf8.decoder).listen((data) {
        sendLog('[OUT] $data');
        _extractUrl(data);
      });

      _stderrSub = _process!.stderr.transform(utf8.decoder).listen((data) {
        sendLog('[ERR] $data');
        _extractUrl(data);
      });

      _process!.exitCode.then((code) {
        sendLog('⏹️ Tunnel stopped with code: $code');
        _isRunning = false;
        updateNotification('Tunnel stopped', 'Tap to start again');
        // Không tự động dừng service – để người dùng quyết định
      });
    } catch (e) {
      sendLog('❌ Error starting: $e');
      await stopService();
    }
  }

  void _extractUrl(String data) {
    final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
    if (match != null) {
      final url = match.group(0)!;
      sendUrl(url);
      updateNotification('Tunnel is running', 'URL: $url');
    }
  }

  void sendLog(String log) =>
      FlutterForegroundTask.sendDataToPort({'type': 'log', 'data': log});

  void sendUrl(String url) =>
      FlutterForegroundTask.sendDataToPort({'type': 'url', 'data': url});

  void updateNotification(String title, String text) {
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  @override
  Future<void> onStop(DateTime timestamp) async {
    _process?.kill(ProcessSignal.sigterm);
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _isRunning = false;
    await WakelockPlus.disable();
    updateNotification('Tunnel stopped', 'Tap to start again');
    sendLog('🛑 Service stopped');
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['action'] == 'stop') {
      stopService();
    }
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  void onDestroy(DateTime timestamp) {
    _process?.kill();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    WakelockPlus.disable();
  }
}
