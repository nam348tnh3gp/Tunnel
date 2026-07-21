import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

const MethodChannel _nativeChannel = MethodChannel('com.TGFN.tunnel_controller/native');

void main() {
  // 👇 Khởi tạo communication port (quan trọng!)
  FlutterForegroundTask.initCommunicationPort();
  
  // Khởi tạo Foreground Service
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'tunnel_channel',
      channelName: 'Tunnel Service',
      channelDescription: 'Keep tunnel running in background',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      icon: null,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(2000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: false,
      allowWifiLock: false,
    ),
  );
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tunnel Controller',
        theme: ThemeData.dark(),
        home: TunnelControlPage(),
      );
}

class TunnelControlPage extends StatefulWidget {
  @override
  _TunnelControlPageState createState() => _TunnelControlPageState();
}

class _TunnelControlPageState extends State<TunnelControlPage> {
  // Basic tunnel controls
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  final TextEditingController _customArgsController = TextEditingController();
  bool _useTryMode = false;
  bool _isRunning = false;
  bool _permissionsGranted = false;

  // Advanced options
  bool _useQuic = true;
  bool _usePostQuantum = false;
  bool _useMetrics = true;
  String _region = '';
  String _edgeIpVersion = 'auto';
  String _customHostname = '';

  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  String _log = '';
  String _cloudflaredPath = '';
  String _nativeDir = '';
  bool _binaryReady = false;
  String _tunnelUrl = '';

  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;

  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    
    // 👇 Add callback để nhận dữ liệu từ TaskHandler
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    
    _requestPermissions().then((_) {
      _initBinary();
      _startSystemMonitor();
      _initForegroundService();
    });
  }

  @override
  void dispose() {
    _stopTunnel();
    _stopForegroundService();
    _systemTimer?.cancel();
    _logScrollController.dispose();
    
    // 👇 Remove callback khi dispose
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }

  // ==================== RECEIVE DATA FROM TASK HANDLER ====================
  void _onReceiveTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      final dynamic cpu = data["cpu"];
      final dynamic temp = data["temp"];
      if (cpu != null && temp != null) {
        setState(() {
          _cpuInfo = 'CPU: ${cpu.toStringAsFixed(1)}%';
          _tempInfo = '🌡️ Temp: ${temp.toStringAsFixed(1)} °C';
        });
      }
    }
  }

  // ==================== PERMISSIONS ====================
  Future<void> _requestPermissions() async {
    _appendLog('🔑 Requesting permissions...');

    // Check notification permission (Android 13+)
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    List<Permission> permissions = [
      Permission.storage,
    ];

    for (var perm in permissions) {
      final status = await perm.request();
      if (status.isGranted) {
        _appendLog('✅ ${perm.toString().split('.').last} granted');
      } else if (status.isDenied) {
        _appendLog('⚠️ ${perm.toString().split('.').last} denied');
      } else if (status.isPermanentlyDenied) {
        _appendLog('❌ ${perm.toString().split('.').last} permanently denied');
        if (await perm.shouldShowRequestRationale == false) {
          await openAppSettings();
        }
      }
    }

    // Android 12+, request ignore battery optimization
    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }

    _permissionsGranted = true;
    _appendLog('✅ Permissions requested');
  }

  // ==================== INIT BINARY ====================
  Future<void> _initBinary() async {
    try {
      String? nativeDir;
      try {
        nativeDir = await _nativeChannel.invokeMethod('getNativeLibraryDir');
      } catch (e) {
        _appendLog('⚠️ Cannot get native dir, fallback...');
      }

      if (nativeDir != null && nativeDir.isNotEmpty) {
        _nativeDir = nativeDir;
        _appendLog('📁 Native dir: $_nativeDir');

        final String cfPath = '$nativeDir/libcloudflared.so';
        if (File(cfPath).existsSync()) {
          await Process.run('chmod', ['755', cfPath]);
          _cloudflaredPath = cfPath;
          _appendLog('✅ Cloudflared ready');
          setState(() => _binaryReady = true);
          return;
        }
      }

      await _fallbackInitBinary();
    } catch (e) {
      _appendLog('❌ Init binary error: $e');
      await _fallbackInitBinary();
    }
  }

  Future<void> _fallbackInitBinary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final String cfPath = '${dir.path}/cloudflared';
      if (!File(cfPath).existsSync()) {
        final data = await rootBundle.load('assets/cloudflared');
        await File(cfPath).writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', cfPath]);
      }
      _cloudflaredPath = cfPath;
      setState(() => _binaryReady = true);
      _appendLog('✅ Cloudflared ready (fallback)');
    } catch (e) {
      _appendLog('❌ Fallback failed: $e');
    }
  }

  // ==================== FOREGROUND SERVICE ====================
  Future<void> _initForegroundService() async {
    try {
      // 👇 Đăng ký callback start
      if (!await FlutterForegroundTask.isRunningService) {
        final result = await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: 'Tunnel Controller',
          notificationText: 'Idle...',
          notificationButtons: [
            const NotificationButton(id: 'stop_tunnel', text: 'Stop Tunnel'),
          ],
          notificationInitialRoute: '/',
          callback: startCallback,
        );
        _appendLog('✅ Foreground service started: ${result.success}');
      } else {
        _appendLog('ℹ️ Foreground service already running');
      }

      // 👇 Kiểm tra xem service đang chạy không
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        _appendLog('✅ Service is running');
      }
    } catch (e) {
      _appendLog('⚠️ Foreground service init: $e');
    }
  }

  Future<void> _updateForegroundNotification(String text, [String? url]) async {
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Tunnel Controller',
        notificationText: text,
        notificationButtons: [
          const NotificationButton(id: 'stop_tunnel', text: 'Stop Tunnel'),
        ],
      );
    } catch (e) {
      // Bỏ qua lỗi
    }
  }

  Future<void> _stopForegroundService() async {
    try {
      await FlutterForegroundTask.stopService();
      _appendLog('ℹ️ Foreground service stopped');
    } catch (e) {
      // Bỏ qua
    }
  }

  // ==================== SYSTEM MONITOR ====================
  void _startSystemMonitor() {
    _systemTimer = Timer.periodic(Duration(seconds: 2), (timer) async {
      if (mounted) {
        try {
          PerformanceInfo perf = await DeviceInfoCe.performanceInfo();
          double cpu = (perf.cpuUsage ?? 0) * 100;
          double temp = perf.temperature ?? 0;
          setState(() {
            _cpuInfo = 'CPU: ${cpu.toStringAsFixed(1)}%';
            _tempInfo = '🌡️ Temp: ${temp.toStringAsFixed(1)} °C';
          });
          // Cập nhật notification với CPU/Temp
          if (_isRunning) {
            final status = _tunnelUrl.isNotEmpty
                ? 'Running: ${_tunnelUrl.length > 30 ? _tunnelUrl.substring(0, 30) + '...' : _tunnelUrl}'
                : 'Connecting...';
            await _updateForegroundNotification(
              '🔄 $status | CPU: ${cpu.toStringAsFixed(1)}%',
            );
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _cpuInfo = 'CPU: N/A';
              _tempInfo = '🌡️ Temp: N/A';
            });
          }
        }
      }
    });
  }

  // ==================== LOG HELPER ====================
  void _appendLog(String msg) {
    setState(() => _log += '\n$msg');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _copyLog() async {
    if (_log.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('📋 Log is empty')),
      );
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: _log));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Log copied to clipboard!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to copy: $e')),
      );
    }
  }

  Future<void> _copyTunnelUrl() async {
    if (_tunnelUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tunnel URL available yet')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: _tunnelUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ Copied: $_tunnelUrl')),
    );
  }

  // ==================== START TUNNEL ====================
  void _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary not ready');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel already running');
      return;
    }

    _tunnelUrl = '';
    setState(() {});

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    List<String> args = [];

    if (_useTryMode) {
      args.addAll(['tunnel', '--url', 'http://localhost:$port']);
      _appendLog('🚀 Starting Try Cloudflared on port $port');
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        _appendLog('❌ Please enter Token');
        return;
      }
      args.addAll(['tunnel', '--token', token]);
      _appendLog('🔑 Starting tunnel with token');
    }

    if (_customArgsController.text.trim().isNotEmpty) {
      final customArgs = _customArgsController.text.trim().split(' ');
      args.addAll(customArgs);
      _appendLog('📝 Custom args: ${customArgs.join(' ')}');
    }

    if (!_useQuic) {
      args.add('--protocol');
      args.add('http2');
      _appendLog('📡 Using HTTP/2 protocol');
    }
    if (_usePostQuantum) {
      args.add('--post-quantum');
      _appendLog('🔐 Post-Quantum enabled');
    }
    if (!_useMetrics) {
      args.add('--management-diagnostics=false');
      _appendLog('📊 Metrics disabled');
    }
    if (_region.isNotEmpty) {
      args.add('--region');
      args.add(_region);
      _appendLog('🌍 Region: $_region');
    }
    if (_edgeIpVersion != 'auto') {
      args.add('--edge-ip-version');
      args.add(_edgeIpVersion);
      _appendLog('🌐 Edge IP version: $_edgeIpVersion');
    }
    if (_customHostname.isNotEmpty) {
      args.add('--hostname');
      args.add(_customHostname);
      _appendLog('🏷️ Hostname: $_customHostname');
    }

    try {
      final Map<String, String> env = {
        'PATH': '/system/bin:/system/xbin:/vendor/bin',
        'ANDROID_ROOT': '/system',
        'LD_LIBRARY_PATH': '$_nativeDir:/system/lib64:/vendor/lib64',
      };

      _appendLog('📋 Command: ${_cloudflaredPath} ${args.join(' ')}');

      _process = await Process.start(
        _cloudflaredPath,
        args,
        runInShell: false,
        environment: env,
      );

      _isRunning = true;
      setState(() {});
      _appendLog('✅ Tunnel started (PID: ${_process!.pid})');

      await _updateForegroundNotification('Connecting...');

      _stdoutSub = _process!.stdout.transform(utf8.decoder).listen((data) {
        _appendLog('[OUT] $data');
        final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
        if (match != null) {
          setState(() {
            _tunnelUrl = match.group(0)!;
          });
          _appendLog('🔗 Public URL: $_tunnelUrl');
          _updateForegroundNotification('Running: $_tunnelUrl');
        }
      });

      _stderrSub = _process!.stderr.transform(utf8.decoder).listen((data) {
        _appendLog('[ERR] $data');
        if (_tunnelUrl.isEmpty) {
          final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
          if (match != null) {
            setState(() {
              _tunnelUrl = match.group(0)!;
            });
            _appendLog('🔗 Public URL: $_tunnelUrl');
            _updateForegroundNotification('Running: $_tunnelUrl');
          }
        }
      });

      _process!.exitCode.then((code) {
        if (mounted) {
          setState(() {
            _isRunning = false;
            _tunnelUrl = '';
            _appendLog('⏹️ Tunnel stopped with code: $code');
          });
          _updateForegroundNotification('Stopped');
        }
      });
    } catch (e) {
      _appendLog('❌ Error starting: $e');
      _updateForegroundNotification('Error: $e');
    }
  }

  // ==================== STOP TUNNEL ====================
  void _stopTunnel() {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      _stdoutSub?.cancel();
      _stderrSub?.cancel();
      setState(() {
        _isRunning = false;
        _tunnelUrl = '';
        _appendLog('🛑 Stopped');
      });
      _updateForegroundNotification('Stopped');
    }
  }

  // ==================== UI ====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare Tunnel'),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copyLog),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(() => _log = ''),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Mode
              DropdownButtonFormField<bool>(
                value: _useTryMode,
                items: const [
                  DropdownMenuItem(value: false, child: Text('🔑 Token')),
                  DropdownMenuItem(value: true, child: Text('🌀 Try Cloudflared')),
                ],
                onChanged: (val) => setState(() => _useTryMode = val!),
                decoration: const InputDecoration(
                  labelText: 'Mode',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // Token field
              if (!_useTryMode)
                TextField(
                  controller: _tokenController,
                  decoration: const InputDecoration(
                    labelText: 'Tunnel Token',
                    border: OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 12),

              // Port
              TextField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),

              // Custom arguments
              TextField(
                controller: _customArgsController,
                decoration: const InputDecoration(
                  labelText: 'Custom arguments',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // Advanced options
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '⚙️ Advanced Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: CheckboxListTile(
                            title: const Text('QUIC'),
                            value: _useQuic,
                            onChanged: (val) => setState(() => _useQuic = val!),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        Expanded(
                          child: CheckboxListTile(
                            title: const Text('Post-Quantum'),
                            value: _usePostQuantum,
                            onChanged: (val) => setState(() => _usePostQuantum = val!),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      title: const Text('Metrics'),
                      value: _useMetrics,
                      onChanged: (val) => setState(() => _useMetrics = val!),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Region (e.g. hkg, sin, lax)',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) => setState(() => _region = val),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: _edgeIpVersion,
                      items: const [
                        DropdownMenuItem(value: 'auto', child: Text('Auto')),
                        DropdownMenuItem(value: '4', child: Text('IPv4')),
                        DropdownMenuItem(value: '6', child: Text('IPv6')),
                      ],
                      onChanged: (val) => setState(() => _edgeIpVersion = val!),
                      decoration: const InputDecoration(
                        labelText: 'Edge IP Version',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Custom Hostname',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) => setState(() => _customHostname = val),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Start/Stop buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isRunning ? null : _startTunnel,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        minimumSize: const Size(80, 50),
                      ),
                      child: const Text('Start'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isRunning ? _stopTunnel : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        minimumSize: const Size(80, 50),
                      ),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Copy URL button
              if (_tunnelUrl.isNotEmpty)
                Container(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _copyTunnelUrl,
                    icon: const Icon(Icons.copy),
                    label: Text('📋 Copy: $_tunnelUrl'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 12),

              // Foreground service status
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                decoration: BoxDecoration(
                  color: _isRunning ? Colors.green.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isRunning ? Icons.play_circle : Icons.stop_circle,
                      color: _isRunning ? Colors.green : Colors.red,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isRunning ? 'Foreground: Running' : 'Foreground: Idle',
                      style: TextStyle(
                        color: _isRunning ? Colors.green : Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'CPU: ${_cpuInfo.replaceAll('CPU: ', '')}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // CPU & Temp
              Row(
                children: [
                  Icon(Icons.memory, size: 18),
                  const SizedBox(width: 4),
                  Text(_cpuInfo),
                  const SizedBox(width: 24),
                  Icon(Icons.thermostat, size: 18),
                  const SizedBox(width: 4),
                  Text(_tempInfo),
                ],
              ),
              const SizedBox(height: 8),

              // Log
              Row(
                children: [
                  const Text('📋 Log:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _copyLog,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                height: 180,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  controller: _logScrollController,
                  reverse: false,
                  child: Text(
                    _log.isEmpty ? 'Waiting...' : _log,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== TASK HANDLER ====================
// 👇 TOP-LEVEL FUNCTION - Bắt buộc phải là top-level hoặc static
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Called when the task is started
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Called based on the eventAction set in ForegroundTaskOptions
    // Send data to main isolate (CPU/Temp)
    // Lưu ý: Không gọi hàm async trong onRepeatEvent
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Called when the task is destroyed
  }

  @override
  void onReceiveData(Object data) {
    // Called when data is sent from main isolate
    // Không dùng trong app này
  }

  @override
  void onNotificationButtonPressed(String id) {
    // Called when the notification button is pressed
    if (id == 'stop_tunnel') {
      // Stop tunnel from notification
      // Có thể gửi dữ liệu về main isolate để xử lý
    }
  }

  @override
  void onNotificationPressed() {
    // Called when the notification itself is pressed
    // Open app
  }

  @override
  void onNotificationDismissed() {
    // Called when the notification is dismissed
  }
}
