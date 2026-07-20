import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

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
  String _cloudflaredPath = '';
  String _prootPath = '';
  String _prootLoaderPath = '';
  String _nativeDir = '';
  bool _binaryReady = false;

  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;

  final ScrollController _logScrollController = ScrollController();

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
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.storage.request();
    _appendLog('✅ Permissions requested');
  }

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

        // Cloudflared
        final String cfPath = '$nativeDir/libcloudflared.so';
        if (File(cfPath).existsSync()) {
          await Process.run('chmod', ['755', cfPath]);
          _cloudflaredPath = cfPath;
          _appendLog('✅ Cloudflared ready from native libs');
        }

        // Proot (đã được sửa SONAME, giờ tìm libtalloc.so)
        final String prPath = '$nativeDir/libproot.so';
        if (File(prPath).existsSync()) {
          await Process.run('chmod', ['755', prPath]);
          _prootPath = prPath;
          _appendLog('✅ Proot ready from native libs (SONAME fixed)');
        }

        // Proot loader
        final String loaderPath = '$nativeDir/libproot_loader.so';
        if (File(loaderPath).existsSync()) {
          await Process.run('chmod', ['755', loaderPath]);
          _prootLoaderPath = loaderPath;
          _appendLog('✅ Proot loader ready from native libs');
        }

        // libtalloc.so (tên chuẩn, không có .2)
        final String tallocPath = '$nativeDir/libtalloc.so';
        if (File(tallocPath).existsSync()) {
          await Process.run('chmod', ['755', tallocPath]);
          _appendLog('✅ libtalloc.so ready from native libs');
        } else {
          _appendLog('⚠️ libtalloc.so not found in native libs');
        }

        if (_cloudflaredPath.isNotEmpty) {
          setState(() => _binaryReady = true);
          return;
        }
      }

      await _fallbackInitBinary();
    } catch (e) {
      _appendLog('❌ Error: $e');
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

      final String prPath = '${dir.path}/proot';
      if (!File(prPath).existsSync()) {
        final data = await rootBundle.load('assets/proot');
        await File(prPath).writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', prPath]);
      }
      _prootPath = prPath;

      final String loaderPath = '${dir.path}/proot_loader';
      if (!File(loaderPath).existsSync()) {
        final data = await rootBundle.load('assets/proot_loader');
        await File(loaderPath).writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', loaderPath]);
      }
      _prootLoaderPath = loaderPath;

      final String tallocPath = '${dir.path}/libtalloc.so';
      if (!File(tallocPath).existsSync()) {
        final data = await rootBundle.load('assets/libtalloc.so');
        await File(tallocPath).writeAsBytes(data.buffer.asUint8List(), flush: true);
        await Process.run('chmod', ['755', tallocPath]);
      }

      setState(() => _binaryReady = true);
      _appendLog('✅ Cloudflared ready (fallback)');
      _appendLog('✅ Proot ready (fallback)');
      _appendLog('✅ Proot loader ready (fallback)');
      _appendLog('✅ libtalloc.so ready (fallback)');
    } catch (e) {
      _appendLog('❌ Fallback failed: $e');
    }
  }

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
              _cpuInfo = 'CPU: N/A (not supported)';
              _tempInfo = '🌡️ Temp: N/A (not supported)';
            });
          }
        }
      }
    });
  }

  void _appendLog(String msg) {
    setState(() {
      _log += '\n$msg';
    });
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

  void _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary not ready');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel already running');
      return;
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    List<String> args;

    if (_useTryMode) {
      args = ['tunnel', '--url', 'http://localhost:$port'];
      _appendLog('🚀 Starting Try Cloudflared on port $port');
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        _appendLog('❌ Please enter Token');
        return;
      }
      args = ['tunnel', '--token', token];
      _appendLog('🔑 Starting tunnel with token');
    }

    try {
      // Tạo resolv.conf giả
      final tempDir = await getTemporaryDirectory();
      final resolvFile = File('${tempDir.path}/resolv.conf');
      await resolvFile.writeAsString('nameserver 1.1.1.1\nnameserver 8.8.8.8\n');

      String cmd;
      final bool hasProot = _prootPath.isNotEmpty && File(_prootPath).existsSync();
      final bool hasLoader = _prootLoaderPath.isNotEmpty && File(_prootLoaderPath).existsSync();

      if (hasProot && hasLoader) {
        cmd = '$_prootPath -b ${resolvFile.path}:/etc/resolv.conf $_cloudflaredPath ${args.join(' ')}';
        _appendLog('🛡️ Using Termux proot with loader (SONAME fixed)');
      } else if (hasProot) {
        cmd = '$_prootPath -b ${resolvFile.path}:/etc/resolv.conf $_cloudflaredPath ${args.join(' ')}';
        _appendLog('⚠️ Proot without loader (may fail)');
      } else {
        cmd = '$_cloudflaredPath ${args.join(' ')}';
        _appendLog('⚠️ Proot not available, running directly');
      }

      final String ldLibraryPath = _nativeDir.isNotEmpty
          ? '$_nativeDir:/system/lib64:/vendor/lib64'
          : '/system/lib64:/vendor/lib64';

      final Map<String, String> env = {
        'PATH': '/system/bin:/system/xbin:/vendor/bin:/data/local/tmp',
        'ANDROID_ROOT': '/system',
        'LD_LIBRARY_PATH': ldLibraryPath,
        'PROOT_TMP_DIR': '/data/local/tmp',
        'PROOT_NO_SECCOMP': '1',
        if (hasLoader) 'PROOT_UNBUNDLE_LOADER': _prootLoaderPath,
      };

      _appendLog('📁 LD_LIBRARY_PATH: $ldLibraryPath');

      _process = await Process.start(
        '/system/bin/sh',
        ['-c', cmd],
        runInShell: false,
        environment: env,
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
        _appendLog('🛑 Stopped');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare Tunnel'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy Log',
            onPressed: _copyLog,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear Log',
            onPressed: () {
              setState(() => _log = '');
            },
          ),
        ],
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
            Expanded(
              child: Container(
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
            ),
          ],
        ),
      ),
    );
  }
}
