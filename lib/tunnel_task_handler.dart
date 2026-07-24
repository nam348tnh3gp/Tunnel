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
  SendPort? _sendPort;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    _sendPort = sendPort;
    // Lấy dữ liệu từ params
    final params = await FlutterForegroundTask.getData('start_params') as Map<String, dynamic>?;
    if (params == null) {
      sendLog('❌ No params provided');
      await FlutterForegroundTask.stopService();
      return;
    }

    _binaryPath = params['binaryPath'] as String?;
    if (_binaryPath == null || _binaryPath!.isEmpty) {
      sendLog('❌ Binary path not provided');
      await FlutterForegroundTask.stopService();
      return;
    }

    // Acquire WakeLock
    await WakelockPlus.enable();

    final token = params['token'] as String? ?? '';
    final port = params['port'] as int? ?? 8080;
    final useTryMode = params['useTryMode'] as bool? ?? false;
    final customArgs = (params['customArgs'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final useQuic = params['useQuic'] as bool? ?? true;
    final usePostQuantum = params['usePostQuantum'] as bool? ?? false;
    final useMetrics = params['useMetrics'] as bool? ?? true;
    final region = params['region'] as String? ?? '';
    final edgeIpVersion = params['edgeIpVersion'] as String? ?? 'auto';
    final customHostname = params['customHostname'] as String? ?? '';

    // Build command
    List<String> args = [];
    if (useTryMode) {
      args.addAll(['tunnel', '--url', 'http://localhost:$port']);
    } else {
      if (token.isEmpty) {
        sendLog('❌ Token is required');
        await FlutterForegroundTask.stopService();
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

    try {
      final env = {
        'PATH': '/system/bin:/system/xbin:/vendor/bin',
        'ANDROID_ROOT': '/system',
        'LD_LIBRARY_PATH': '/system/lib64:/vendor/lib64',
      };

      _process = await Process.start(_binaryPath!, args, runInShell: false, environment: env);
      _isRunning = true;
      sendLog('✅ Tunnel started (PID: ${_process!.pid})');
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Tunnel is running',
        notificationText: 'Connecting...',
      );

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
        FlutterForegroundTask.updateService(
          notificationTitle: 'Tunnel stopped',
          notificationText: 'Tap to start again',
        );
      });
    } catch (e) {
      sendLog('❌ Error starting: $e');
      await FlutterForegroundTask.stopService();
    }
  }

  void _extractUrl(String data) {
    final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
    if (match != null) {
      final url = match.group(0)!;
      sendUrl(url);
      FlutterForegroundTask.updateService(
        notificationTitle: 'Tunnel is running',
        notificationText: 'URL: $url',
      );
    }
  }

  void sendLog(String log) {
    _sendPort?.send({'type': 'log', 'data': log});
  }

  void sendUrl(String url) {
    _sendPort?.send({'type': 'url', 'data': url});
  }

  @override
  Future<void> onStop(DateTime timestamp) async {
    _process?.kill(ProcessSignal.sigterm);
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _isRunning = false;
    await WakelockPlus.disable();
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Tunnel stopped',
      notificationText: 'Tap to start again',
    );
    sendLog('🛑 Service stopped');
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Không cần xử lý
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    _process?.kill();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await WakelockPlus.disable();
  }
}
