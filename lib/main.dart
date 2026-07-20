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
  final TextEditingController _customCommandController = TextEditingController();

  bool _useTryMode = false;
  bool _isRunning = false;
  bool _permissionsGranted = false;
  bool _bootstrapDone = false;

  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  String _log = '';
  String _cloudflaredPath = '';
  String _prootPath = '';
  String _prootLoaderPath = '';
  String _runInRootfsPath = '';
  String _nativeDir = '';
  bool _binaryReady = false;

  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;

  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _requestPermissions().then((_) {
      _initBinary();
      _bootstrapTermux();
      _startSystemMonitor();
    });
  }

  @override
  void dispose() {
    _stopTunnel();
    _systemTimer?.cancel();
    _logScrollController.dispose();
    _customCommandController.dispose();
    super.dispose();
  }

  // ==================== PERMISSIONS ====================
  Future<void> _requestPermissions() async {
    _appendLog('🔑 Requesting all permissions...');

    List<Permission> permissions = [
      Permission.storage,
      Permission.phone,
      Permission.notification,
      Permission.manageExternalStorage,
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

    _permissionsGranted = true;
    _appendLog('✅ All critical permissions granted');
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
        }

        final String prPath = '$nativeDir/libproot.so';
        if (File(prPath).existsSync()) {
          await Process.run('chmod', ['755', prPath]);
          _prootPath = prPath;
          _appendLog('✅ Proot ready');
        }

        final String loaderPath = '$nativeDir/libproot_loader.so';
        if (File(loaderPath).existsSync()) {
          await Process.run('chmod', ['755', loaderPath]);
          _prootLoaderPath = loaderPath;
          _appendLog('✅ Proot loader ready');
        }

        final libs = ['libtalloc.so', 'libandroid-shmem.so'];
        for (var lib in libs) {
          final libPath = '$nativeDir/$lib';
          if (File(libPath).existsSync()) {
            await Process.run('chmod', ['755', libPath]);
            _appendLog('✅ $lib ready');
          }
        }

        if (_cloudflaredPath.isNotEmpty) {
          setState(() => _binaryReady = true);
        }
      }
    } catch (e) {
      _appendLog('❌ Init binary error: $e');
    }
  }

  // ==================== BOOTSTRAP TERMUX ROOTFS ====================
  Future<void> _bootstrapTermux() async {
    try {
      _appendLog('📦 Running Termux-style bootstrap...');

      final appDir = await getApplicationDocumentsDirectory();

      // Kiểm tra rootfs đã tồn tại chưa
      final rootfsDir = Directory('${appDir.path}/rootfs');
      final runScript = File('${appDir.path}/run-in-rootfs.sh');

      if (await rootfsDir.exists() && await runScript.exists()) {
        _runInRootfsPath = runScript.path;
        _bootstrapDone = true;
        _appendLog('✅ Rootfs already exists, skipping bootstrap');
        return;
      }

      // Giải nén bootstrap script từ assets
      final bootstrapData = await rootBundle.loadString('assets/bootstrap.sh');
      final bootstrapFile = File('${appDir.path}/bootstrap.sh');
      await bootstrapFile.writeAsString(bootstrapData);
      await Process.run('chmod', ['755', bootstrapFile.path]);

      // Copy binary và thư viện vào thư mục files để script dùng
      final files = {
        'proot': _prootPath,
        'proot_loader': _prootLoaderPath,
        'libtalloc.so': '$_nativeDir/libtalloc.so',
        'libandroid-shmem.so': '$_nativeDir/libandroid-shmem.so',
      };

      for (var entry in files.entries) {
        final src = entry.value;
        final dest = '${appDir.path}/${entry.key}';
        if (File(src).existsSync()) {
          await File(src).copy(dest);
          await Process.run('chmod', ['755', dest]);
          _appendLog('✅ Copied ${entry.key}');
        } else {
          _appendLog('⚠️ ${entry.key} not found at $src');
        }
      }

      // Copy cloudflared vào thư mục files
      if (File(_cloudflaredPath).existsSync()) {
        await File(_cloudflaredPath).copy('${appDir.path}/cloudflared');
        await Process.run('chmod', ['755', '${appDir.path}/cloudflared']);
        _appendLog('✅ Copied cloudflared');
      }

      // Chạy bootstrap script
      final result = await Process.run(
        '/system/bin/sh',
        [bootstrapFile.path],
        runInShell: false,
      );

      if (result.stdout.toString().isNotEmpty) {
        _appendLog('[BOOTSTRAP] ${result.stdout}');
      }
      if (result.stderr.toString().isNotEmpty) {
        _appendLog('[BOOTSTRAP ERR] ${result.stderr}');
      }

      // Kiểm tra script run-in-rootfs đã được tạo
      if (await runScript.exists()) {
        _runInRootfsPath = runScript.path;
        await Process.run('chmod', ['755', _runInRootfsPath]);
        _bootstrapDone = true;
        _appendLog('✅ Bootstrap completed successfully!');
      } else {
        _appendLog('❌ Bootstrap failed: run-in-rootfs.sh not found');
      }
    } catch (e) {
      _appendLog('❌ Bootstrap error: $e');
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

  // ==================== EXECUTE COMMAND IN ROOTFS ====================
  Future<void> _executeInRootfs(String command) async {
    if (!_bootstrapDone || _runInRootfsPath.isEmpty) {
      _appendLog('⏳ Rootfs not ready');
      return;
    }

    try {
      // Escape command để truyền qua shell
      final escapedCommand = command.replaceAll('"', '\\"');
      final cmd = '$_runInRootfsPath "$escapedCommand"';

      _appendLog('▶️ Executing in rootfs: $command');

      final result = await Process.run(
        '/system/bin/sh',
        ['-c', cmd],
        runInShell: false,
      );

      if (result.stdout.toString().isNotEmpty) {
        _appendLog('[OUT] ${result.stdout}');
      }
      if (result.stderr.toString().isNotEmpty) {
        _appendLog('[ERR] ${result.stderr}');
      }
      _appendLog('✅ Command finished with exit code: ${result.exitCode}');
    } catch (e) {
      _appendLog('❌ Error executing command: $e');
    }
  }

  // ==================== START TUNNEL ====================
  void _startTunnel() async {
    if (!_binaryReady || !_bootstrapDone) {
      _appendLog('⏳ Binary or rootfs not ready');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel already running');
      return;
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    String args;

    if (_useTryMode) {
      args = 'tunnel --url http://localhost:$port';
      _appendLog('🚀 Starting Try Cloudflared on port $port');
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        _appendLog('❌ Please enter Token');
        return;
      }
      args = 'tunnel --token $token';
      _appendLog('🔑 Starting tunnel with token');
    }

    try {
      // Chạy cloudflared bên trong rootfs
      final command = 'cd $_nativeDir && ./cloudflared $args';
      final escapedCommand = command.replaceAll('"', '\\"');
      final cmd = '$_runInRootfsPath "$escapedCommand"';

      _appendLog('🛡️ Running tunnel inside Termux rootfs');

      _process = await Process.start(
        '/system/bin/sh',
        ['-c', cmd],
        runInShell: false,
        environment: {
          'PATH': '/usr/bin:/bin:/system/bin:/system/xbin:/vendor/bin',
          'ANDROID_ROOT': '/system',
          'TMPDIR': '/data/local/tmp',
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
        _appendLog('🛑 Stopped');
      });
    }
  }

  // ==================== CUSTOM COMMAND ====================
  Future<void> _executeCustomCommand() async {
    String command = _customCommandController.text.trim();
    if (command.isEmpty) {
      _appendLog('⚠️ Please enter a command');
      return;
    }
    await _executeInRootfs(command);
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

            // Token
            if (!_useTryMode)
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'Tunnel Token',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),

            // Port + Start/Stop
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
            const SizedBox(height: 12),

            // Custom Command
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '💻 Custom Command (in rootfs)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _customCommandController,
                          decoration: const InputDecoration(
                            hintText: 'e.g. ls -la, apk add curl',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          ),
                          style: const TextStyle(fontSize: 13),
                          onSubmitted: (_) => _executeCustomCommand(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _executeCustomCommand,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Run'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueGrey,
                          minimumSize: const Size(60, 40),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

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
