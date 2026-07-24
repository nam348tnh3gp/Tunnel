import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'tunnel_task_handler.dart';

@pragma('vm:entry-point')
void startTunnelService() {
  FlutterForegroundTask.setTaskHandler(TunnelTaskHandler());
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'tunnel_channel',
      channelName: 'Tunnel Service',
      channelDescription: 'Keeps the Cloudflare Tunnel running in background.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,   // sửa thành ic (không dùng mipmap)
        name: 'launcher',               // tên icon (không có prefix ic_)
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: false,
      // bỏ updateNotification vì không có trong phiên bản này
    ),
  );

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tunnel Controller',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blueGrey,
        scaffoldBackgroundColor: const Color(0xFF1E1E2E),
        cardColor: const Color(0xFF2D2D44),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70),
          bodySmall: TextStyle(color: Colors.white54),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF3A3A5A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      home: const TunnelControlPage(),
    );
  }
}

class TunnelControlPage extends StatefulWidget {
  const TunnelControlPage({super.key});

  @override
  _TunnelControlPageState createState() => _TunnelControlPageState();
}

class _TunnelControlPageState extends State<TunnelControlPage> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  final TextEditingController _customArgsController = TextEditingController();
  bool _useTryMode = false;
  bool _isRunning = false;

  bool _useQuic = true;
  bool _usePostQuantum = false;
  bool _useMetrics = true;
  String _region = '';
  String _edgeIpVersion = 'auto';
  String _customHostname = '';

  String _log = '';
  String _tunnelUrl = '';
  String _binaryPath = '';
  bool _binaryReady = false;
  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initBinary();
    _startSystemMonitor();
    _listenToService();
  }

  @override
  void dispose() {
    _systemTimer?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _initBinary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cfPath = '${dir.path}/cloudflared';
      final file = File(cfPath);
      if (!file.existsSync()) {
        final data = await rootBundle.load('assets/cloudflared');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', cfPath]);
      }
      _binaryPath = cfPath;
      setState(() => _binaryReady = true);
      _appendLog('✅ Cloudflared ready: $cfPath');
    } catch (e) {
      _appendLog('❌ Init binary error: $e');
    }
  }

  void _startSystemMonitor() {
    _systemTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) return;
      try {
        final perf = await DeviceInfoCe.performanceInfo();
        final cpu = (perf.cpuUsage ?? 0) * 100;
        final temp = perf.temperature ?? 0;
        setState(() {
          _cpuInfo = 'CPU: ${cpu.toStringAsFixed(1)}%';
          _tempInfo = '🌡️ Temp: ${temp.toStringAsFixed(1)} °C';
        });
      } catch (_) {
        setState(() {
          _cpuInfo = 'CPU: N/A';
          _tempInfo = '🌡️ Temp: N/A';
        });
      }
    });
  }

  void _listenToService() {
    FlutterForegroundTask.receivePort?.listen((data) {
      if (data is Map) {
        final type = data['type'];
        final content = data['data'] ?? '';
        if (type == 'log') {
          _appendLog(content);
        } else if (type == 'url') {
          setState(() => _tunnelUrl = content);
        } else if (type == 'status') {
          setState(() => _isRunning = content == 'running');
        }
      }
    });
  }

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

  Future<void> _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary not ready');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel already running');
      return;
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    final token = _tokenController.text.trim();
    if (!_useTryMode && token.isEmpty) {
      _appendLog('❌ Token required');
      return;
    }

    final params = {
      'binaryPath': _binaryPath,
      'token': token,
      'port': port,
      'useTryMode': _useTryMode,
      'customArgs': _customArgsController.text.trim().split(' ').where((s) => s.isNotEmpty).toList(),
      'useQuic': _useQuic,
      'usePostQuantum': _usePostQuantum,
      'useMetrics': _useMetrics,
      'region': _region,
      'edgeIpVersion': _edgeIpVersion,
      'customHostname': _customHostname,
    };

    try {
      // Lưu params bằng saveData
      await FlutterForegroundTask.saveData(key: 'start_params', value: params);

      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Starting tunnel...',
        notificationText: 'Please wait',
        callback: startTunnelService,
        // Không truyền params ở đây
      );
      if (result) {
        setState(() => _isRunning = true);
        _appendLog('🚀 Service started');
      } else {
        _appendLog('❌ Failed to start service');
      }
    } catch (e) {
      _appendLog('❌ Error: $e');
    }
  }

  Future<void> _stopTunnel() async {
    try {
      await FlutterForegroundTask.stopService();
      setState(() {
        _isRunning = false;
        _tunnelUrl = '';
      });
      _appendLog('🛑 Service stopped');
    } catch (e) {
      _appendLog('❌ Failed to stop service: $e');
    }
  }

  Future<void> _copyLog() async {
    if (_log.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('📋 Log is empty')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: _log));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Log copied!')),
    );
  }

  Future<void> _copyTunnelUrl() async {
    if (_tunnelUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No URL yet')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: _tunnelUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ Copied: $_tunnelUrl')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare Tunnel'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(onPressed: _copyLog, icon: const Icon(Icons.copy)),
          IconButton(
            onPressed: () => setState(() => _log = ''),
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildModeCard(),
                    const SizedBox(height: 16),
                    _buildAdvancedCard(),
                    const SizedBox(height: 16),
                    _buildControlCard(),
                    const SizedBox(height: 16),
                    _buildLogCard(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeCard() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.settings, color: Colors.blueAccent),
            const SizedBox(width: 8),
            const Text('Tunnel Mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<bool>(
            value: _useTryMode,
            items: const [
              DropdownMenuItem(value: false, child: Text('🔑 Token')),
              DropdownMenuItem(value: true, child: Text('🌀 Try Cloudflared')),
            ],
            onChanged: (val) => setState(() => _useTryMode = val!),
            decoration: InputDecoration(
              labelText: 'Mode',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          if (!_useTryMode) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Tunnel Token',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            decoration: InputDecoration(
              labelText: 'Local Port',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    ),
  );

  Widget _buildAdvancedCard() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.tune, color: Colors.purpleAccent),
            const SizedBox(width: 8),
            const Text('Advanced Options', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: CheckboxListTile(
                title: const Text('QUIC'),
                value: _useQuic,
                onChanged: (v) => setState(() => _useQuic = v!),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            Expanded(
              child: CheckboxListTile(
                title: const Text('Post-Quantum'),
                value: _usePostQuantum,
                onChanged: (v) => setState(() => _usePostQuantum = v!),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ]),
          CheckboxListTile(
            title: const Text('Enable Metrics'),
            value: _useMetrics,
            onChanged: (v) => setState(() => _useMetrics = v!),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              labelText: 'Region (e.g. hkg, sin, lax)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (v) => setState(() => _region = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _edgeIpVersion,
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Auto')),
              DropdownMenuItem(value: '4', child: Text('IPv4')),
              DropdownMenuItem(value: '6', child: Text('IPv6')),
            ],
            onChanged: (v) => setState(() => _edgeIpVersion = v!),
            decoration: InputDecoration(
              labelText: 'Edge IP Version',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              labelText: 'Custom Hostname',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (v) => setState(() => _customHostname = v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _customArgsController,
            decoration: InputDecoration(
              labelText: 'Custom arguments (e.g. --no-tls-verify)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildControlCard() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isRunning ? null : _startTunnel,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isRunning ? _stopTunnel : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ]),
          if (_tunnelUrl.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade900.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade300),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '🔗 $_tunnelUrl',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    onPressed: _copyTunnelUrl,
                    tooltip: 'Copy URL',
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.memory, size: 18, color: Colors.cyan),
            const SizedBox(width: 4),
            Text(_cpuInfo),
            const SizedBox(width: 24),
            Icon(Icons.thermostat, size: 18, color: Colors.orange),
            const SizedBox(width: 4),
            Text(_tempInfo),
            const Spacer(),
            Icon(
              _isRunning ? Icons.circle : (_binaryReady ? Icons.circle : Icons.circle),
              color: _isRunning ? Colors.green : (_binaryReady ? Colors.grey : Colors.red),
              size: 12,
            ),
            const SizedBox(width: 4),
            Text(_isRunning ? 'Running' : (_binaryReady ? 'Ready' : 'Init...')),
          ]),
        ],
      ),
    ),
  );

  Widget _buildLogCard() => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.terminal, color: Colors.greenAccent),
            const SizedBox(width: 8),
            const Text('Log Output', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              onPressed: _copyLog,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
          ]),
          const SizedBox(height: 8),
          Container(
            height: 200,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              controller: _logScrollController,
              child: Text(
                _log.isEmpty ? 'Waiting for output...' : _log,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
