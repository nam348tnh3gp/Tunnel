import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/tunnel_config.dart';
import '../tunnel_task_handler.dart';
import 'log_buffer.dart';
import 'settings_store.dart';
import 'url_extractor.dart';

enum TunnelStatus { idle, starting, running, restarting, stopping }

/// Owns the cloudflared process. Lives for the whole app lifetime, so closing
/// or rebuilding the page never kills the tunnel.
class TunnelRunner extends ChangeNotifier {
  TunnelRunner({required this.store, required this.log}) {
    log.addListener(_scheduleLogSave);
  }

  static const MethodChannel _channel =
      MethodChannel('com.TGNF.tunnel_controller/native');
  static const String _package = 'com.TGNF.tunnel_controller';
  static const int maxRestarts = 8;

  final SettingsStore store;
  final LogBuffer log;

  TunnelStatus _status = TunnelStatus.idle;
  TunnelStatus get status => _status;

  bool _binaryReady = false;
  bool get binaryReady => _binaryReady;
  bool initialized = false;
  String displayNativeDir = '';

  String _url = '';
  String get url => _url;
  int? _pid;
  int? get pid => _pid;
  int _restartCount = 0;
  int get restartCount => _restartCount;

  String _nativeDir = '';
  String? _cloudflaredPath;
  Process? _process;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  Timer? _restartTimer;
  Timer? _watchTimer;
  Timer? _logSaveTimer;
  bool _stopRequested = false;
  DateTime? _startedAt;
  TunnelConfig? _config;
  String _token = '';

  // ------------------------------------------------------------------ init

  Future<void> init() async {
    if (initialized) return;
    await _recover();
    try {
      final dir = await _channel.invokeMethod<String>('getNativeLibraryDir');
      if (dir == null || dir.isEmpty) {
        log.add('❌ Cannot get native library directory');
        return;
      }
      _nativeDir = dir;
      displayNativeDir = _displayDir(dir);
      log.add('📁 Native dir: $displayNativeDir');

      final path = '$dir/libcloudflared.so';
      if (!File(path).existsSync()) {
        log.add('❌ libcloudflared.so not found in native dir');
        return;
      }
      await Process.run('chmod', ['755', path]);
      _cloudflaredPath = path;
      _binaryReady = true;
      log.add('✅ Cloudflared ready');
    } catch (e) {
      log.add('❌ Init binary error: $e');
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  String _displayDir(String fullPath) {
    final idx = fullPath.indexOf(_package);
    if (idx == -1) return fullPath;
    final rest = fullPath.substring(idx + _package.length);
    final libIdx = rest.indexOf('/lib');
    return libIdx != -1
        ? '/data/app/$_package${rest.substring(libIdx)}'
        : '/data/app/$_package';
  }

  /// If the app was killed/restarted while cloudflared survived, pick the
  /// state back up (live output cannot be re-attached, but Stop still works).
  Future<void> _recover() async {
    final saved = store.loadRunState();
    final savedLog = store.loadLog();
    if (savedLog.isNotEmpty) log.addAll(savedLog);

    var serviceRunning = false;
    try {
      serviceRunning = await FlutterForegroundTask.isRunningService;
    } catch (_) {}

    if (saved.running &&
        saved.pid > 0 &&
        serviceRunning &&
        _isCloudflared(saved.pid)) {
      _pid = saved.pid;
      _url = saved.url;
      _status = TunnelStatus.running;
      log.add('🔄 Re-attached to running tunnel (PID ${saved.pid}). '
          'Live output is unavailable until the next start.');
      _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final p = _pid;
        if (p != null && !_isCloudflared(p)) {
          log.add('⏹️ Tunnel process is gone');
          unawaited(_finish());
        }
      });
      notifyListeners();
      _updateNotification();
      return;
    }
    if (saved.running) {
      log.add('⚠️ Tunnel was running but the service stopped. State reset.');
    }
    await store.clearRunState();
  }

  /// Guards against PID reuse: only trust the PID if it is still cloudflared.
  bool _isCloudflared(int pid) {
    try {
      final f = File('/proc/$pid/cmdline');
      if (!f.existsSync()) return false;
      return String.fromCharCodes(f.readAsBytesSync()).contains('cloudflared');
    } catch (_) {
      return false;
    }
  }

  // ----------------------------------------------------------------- start

  Future<void> start(TunnelConfig config, String token) async {
    if (_status != TunnelStatus.idle) {
      log.add('⚠️ Tunnel already running');
      return;
    }
    if (!_binaryReady) {
      log.add('⏳ Binary not ready');
      return;
    }
    _config = config;
    _token = token;
    _stopRequested = false;
    _restartCount = 0;
    _url = '';
    log.add(config.quickMode
        ? '🚀 Starting quick tunnel on port ${config.port}'
        : '🔑 Starting tunnel with token');
    await _launch();
  }

  Future<void> _launch() async {
    final cfg = _config;
    final path = _cloudflaredPath;
    if (cfg == null || path == null) {
      await _finish();
      return;
    }
    _setStatus(
        _restartCount == 0 ? TunnelStatus.starting : TunnelStatus.restarting);
    await _ensureForeground();
    if (_stopRequested) {
      await _finish();
      return;
    }

    final List<String> args;
    try {
      args = cfg.buildArgs();
    } on FormatException catch (e) {
      log.add('❌ ${e.message}');
      await _finish();
      return;
    }

    if (cfg.quickMode) _url = '';
    final env = <String, String>{
      'PATH': '/system/bin:/system/xbin:/vendor/bin',
      'ANDROID_ROOT': '/system',
      'LD_LIBRARY_PATH': '$_nativeDir:/system/lib64:/vendor/lib64',
    };
    // Token goes through the environment, not argv (invisible in `ps`/logs).
    if (!cfg.quickMode) env['TUNNEL_TOKEN'] = _token;

    log.add('📋 cloudflared ${args.join(' ')}');
    try {
      final p = await Process.start(path, args,
          runInShell: false, environment: env);
      _process = p;
      _pid = p.pid;
      _startedAt = DateTime.now();
      _setStatus(TunnelStatus.running);
      await store.saveRunState(running: true, pid: p.pid, url: _url);
      log.add('✅ Tunnel started (PID ${p.pid})');

      const decoder = Utf8Decoder(allowMalformed: true);
      _outSub = p.stdout
          .transform(decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      _errSub = p.stderr
          .transform(decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      unawaited(p.exitCode.then(_onExit));

      if (_stopRequested) p.kill(ProcessSignal.sigterm);
    } catch (e) {
      log.add('❌ Error starting: $e');
      await _finish();
    }
  }

  void _onLine(String raw) {
    final line = redactToken(raw, token: _token);
    if (line.trim().isEmpty) return;
    log.add(line);
    if (_url.isEmpty) {
      final found = UrlExtractor.extract(line);
      if (found != null) _setUrl(found);
    }
  }

  void _setUrl(String url) {
    _url = url;
    log.add('🔗 Public URL: $url');
    notifyListeners();
    _updateNotification();
    final p = _pid;
    if (p != null) {
      unawaited(store.saveRunState(running: true, pid: p, url: url));
    }
  }

  Future<void> _onExit(int code) async {
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    final ranFor = DateTime.now().difference(_startedAt ?? DateTime.now());
    _process = null;
    _pid = null;

    if (_stopRequested) {
      log.add('⏹️ Tunnel stopped');
      await _finish();
      return;
    }
    log.add('⏹️ Tunnel exited with code $code');

    final cfg = _config;
    if (cfg != null && cfg.autoRestart) {
      if (ranFor > const Duration(minutes: 2)) _restartCount = 0;
      if (_restartCount < maxRestarts) {
        final delay = Duration(seconds: math.min(60, 2 << _restartCount));
        _restartCount++;
        log.add('🔁 Restarting in ${delay.inSeconds}s '
            '(attempt $_restartCount/$maxRestarts)');
        _setStatus(TunnelStatus.restarting);
        _restartTimer = Timer(delay, () {
          if (!_stopRequested) unawaited(_launch());
        });
        return;
      }
      log.add('❌ Giving up after $maxRestarts restart attempts');
    }
    await _finish();
  }

  // ------------------------------------------------------------------ stop

  Future<void> stop() async {
    if (_status == TunnelStatus.idle) {
      log.add('⚠️ No process to stop');
      return;
    }
    _stopRequested = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    _setStatus(TunnelStatus.stopping);

    final p = _process;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        log.add('⚠️ Did not exit in 5s, sending SIGKILL');
        p.kill(ProcessSignal.sigkill);
      }
      return; // _onExit finishes the job
    }

    final pid = _pid;
    if (pid != null && pid > 0) {
      Process.killPid(pid, ProcessSignal.sigterm);
      log.add('⏹️ Sent SIGTERM to PID $pid');
    }
    await _finish();
  }

  Future<void> _finish() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    _process = null;
    _pid = null;
    _token = '';
    _url = _config?.quickMode == true ? '' : _url;
    _status = TunnelStatus.idle;
    notifyListeners();
    await _stopForeground();
    await store.saveLog(log.tail(300));
    await store.clearRunState();
  }

  void clearLog() {
    log.clear();
    unawaited(store.saveLog(const []));
  }

  // ------------------------------------------------------- foreground svc

  Future<void> _ensureForeground() async {
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      final ok = await FlutterForegroundTask.startService(
        notificationTitle: 'Tunnel is running',
        notificationText: 'Connecting…',
        callback: startTunnelService,
      );
      if (!ok) {
        log.add('⚠️ Foreground service did not start; Android may stop the '
            'tunnel while the app is in the background.');
      }
    } catch (e) {
      log.add('⚠️ Foreground service error: $e');
    }
  }

  Future<void> _stopForeground() => _guard(FlutterForegroundTask.stopService);

  void _updateNotification() {
    if (_status == TunnelStatus.idle || _status == TunnelStatus.stopping) return;
    final text = _status == TunnelStatus.restarting
        ? 'Reconnecting…'
        : (_url.isNotEmpty ? _url : 'Connecting…');
    unawaited(_guard(() => FlutterForegroundTask.updateService(
          notificationTitle: 'Tunnel is running',
          notificationText: text,
        )));
  }

  Future<void> _guard(Future<dynamic> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  void _setStatus(TunnelStatus s) {
    _status = s;
    notifyListeners();
    _updateNotification();
  }

  // ------------------------------------------------------------ log saving

  void _scheduleLogSave() {
    if (_logSaveTimer?.isActive ?? false) return;
    _logSaveTimer = Timer(const Duration(seconds: 3), () {
      unawaited(store.saveLog(log.tail(300)));
    });
  }

  @override
  void dispose() {
    log.removeListener(_scheduleLogSave);
    _restartTimer?.cancel();
    _watchTimer?.cancel();
    _logSaveTimer?.cancel();
    super.dispose();
  }
}
