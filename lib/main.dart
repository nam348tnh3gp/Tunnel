import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_ce/device_info_ce.dart';

const MethodChannel _nativeChannel = MethodChannel('com.yourcompany.tunnel_controller/native');

void main() => runApp(MyApp());

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
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  bool _useTryMode = false;
  bool _isRunning = false;

  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  String _log = '';
  String _binaryPath = '';
  bool _binaryReady = false;

  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initBinary();
    _startSystemMonitor();
  }

  @override
  void dispose() {
    _stopTunnel();
    _systemTimer?.cancel();
    super.dispose();
  }

  // -------------------- Yêu cầu quyền chủ động --------------------
  Future<void> _requestPermissions() async {
    // Storage (để fallback copy binary)
    await Permission.storage.request();
    
    // Quyền mạng (dù đã khai báo, vẫn yêu cầu để đảm bảo)
    // Trên Android, INTERNET không cần xin động, nhưng vẫn kiểm tra
    // Thực tế, quyền INTERNET được cấp tự động khi cài app.
    // Tuy nhiên, một số thiết bị có thể hạn chế, ta yêu cầu thêm.
    if (await Permission.phone.isDenied) {
      await Permission.phone.request();
    }
    _appendLog('✅ Permissions requested');
  }

  // -------------------- Binary setup (ưu tiên native lib) --------------------
  Future<void> _initBinary() async {
    try {
      String? nativeDir;
      try {
        nativeDir = await _nativeChannel.invokeMethod('getNativeLibraryDir');
      } catch (e) {
        _appendLog('⚠️ Cannot get native dir via channel, fallback...');
      }

      if (nativeDir != null && nativeDir.isNotEmpty) {
        final String binaryPath = '$nativeDir/libcloudflared.so';
        final File binaryFile = File(binaryPath);
        if (await binaryFile.exists()) {
          await Process.run('chmod', ['755', binaryPath]);
          setState(() {
            _binaryPath = binaryPath;
            _binaryReady = true;
          });
          _appendLog('✅ Cloudflared binary ready from native libs');
          return;
        } else {
          _appendLog('⚠️ libcloudflared.so not found in native lib dir, fallback...');
        }
      }

      await _fallbackInitBinary();
    } catch (e) {
      _appendLog('❌ Error initializing binary: $e');
      await _fallbackInitBinary();
    }
  }

  Future<void> _fallbackInitBinary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final String binaryPath = '${dir.path}/cloudflared';
      final File file = File(binaryPath);

      if (!await file.exists()) {
        final data = await rootBundle.load('assets/cloudflared');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', binaryPath]);
      }
      setState(() {
        _binaryPath = binaryPath;
        _binaryReady = true;
      });
      _appendLog('✅ Cloudflared binary ready (fallback)');
    } catch (e) {
      _appendLog('❌ Fallback failed: $e');
    }
  }

  // -------------------- System monitor --------------------
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

  void _appendLog(String msg) {
    setState(() => _log += '\n$msg');
  }

  // -------------------- Tunnel control (sửa lỗi DNS) --------------------
  void _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary not ready, please wait...');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel is already running');
      return;
    }

    // Kiểm tra quyền mạng (dù không cần nhưng để an tâm)
    if (await Permission.phone.isDenied) {
      _appendLog('⚠️ Phone permission not granted, requesting...');
      await Permission.phone.request();
      if (await Permission.phone.isDenied) {
        _appendLog('❌ Permission denied, cannot start tunnel');
        return;
      }
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    List<String> args;

    if (_useTryMode) {
      args = [
        'tunnel',
        '--url',
        'http://localhost:$port',
        '--dns',
        '1.1.1.1', // DNS rõ ràng để tránh lỗi
      ];
      _appendLog('🚀 Starting Try Cloudflared on port $port');
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        _appendLog('❌ Please enter Token or select Try mode');
        return;
      }
      args = ['tunnel', '--token', token];
      _appendLog('🔑 Starting tunnel with token');
    }

    try {
      // Chạy qua shell với đầy đủ environment
      final String cmd = [_binaryPath, ...args].join(' ');
      _process = await Process.start(
        '/system/bin/sh',
        ['-c', cmd],
        runInShell: false,
        environment: {
          'PATH': '/system/bin:/system/xbin:/vendor/bin:/data/local/tmp',
          'ANDROID_ROOT': '/system',
          'LD_LIBRARY_PATH': '/system/lib64:/vendor/lib64',
          'DNS': '1.1.1.1',
        },
      );

      _isRunning = true;
      setState(() {});
      _appendLog('✅ Tunnel started (PID: ${_process!.pid})');

      _stdoutSub = _process!.stdout.transform(utf8.decoder).listen((data) {
        _appendLog('[OUT] $data');
        if (_useTryMode) {
          final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
          if (match != null) {
            _appendLog('🔗 Public URL: ${match.group(0)}');
          }
        }
      });

      _stderrSub = _process!.stderr.transform(utf8.decoder).listen((data) {
        _appendLog('[ERR] $data');
      });

      _process!.exitCode.then((code) {
        if (mounted) {
          setState(() {
            _isRunning = false;
            _appendLog('⏹️ Tunnel stopped with code: $code');
          });
        }
      });
    } catch (e) {
      _appendLog('❌ Error starting: $e');
    }
  }

  void _stopTunnel() {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      _stdoutSub?.cancel();
      _stderrSub?.cancel();
      setState(() {
        _isRunning = false;
        _appendLog('🛑 Sent stop signal to tunnel');
      });
    }
  }

  // -------------------- UI Build --------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cloudflare Tunnel'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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

            if (!_useTryMode)
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'Tunnel Token',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isRunning ? null : _startTunnel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    minimumSize: const Size(80, 50),
                  ),
                  child: const Text('Start'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isRunning ? _stopTunnel : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    minimumSize: const Size(80, 50),
                  ),
                  child: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 12),

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

            const Text(
              '📋 Log:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    _log.isEmpty ? 'Waiting for actions...' : _log,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
