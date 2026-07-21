import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

const MethodChannel _nativeChannel = MethodChannel('com.TGNF.tunnel_controller/native');

void main() => runApp(MyApp());

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
  // Basic controls
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  final TextEditingController _customArgsController = TextEditingController();
  bool _useTryMode = false;
  bool _isRunning = false;

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

  void _startSystemMonitor() {
    _systemTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
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

      _stdoutSub = _process!.stdout.transform(utf8.decoder).listen((data) {
        _appendLog('[OUT] $data');
        final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
        if (match != null) {
          setState(() {
            _tunnelUrl = match.group(0)!;
          });
          _appendLog('🔗 Public URL: $_tunnelUrl');
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
          }
        }
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
        _tunnelUrl = '';
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
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyLog,
            tooltip: 'Copy log',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(() => _log = ''),
            tooltip: 'Clear log',
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
                    // Mode Selection Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.settings, color: Colors.blueAccent),
                                const SizedBox(width: 8),
                                const Text('Tunnel Mode',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                              ],
                            ),
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
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            if (!_useTryMode) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _tokenController,
                                decoration: InputDecoration(
                                  labelText: 'Tunnel Token',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                              controller: _portController,
                              decoration: InputDecoration(
                                labelText: 'Local Port',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Advanced Options Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.tune, color: Colors.purpleAccent),
                                const SizedBox(width: 8),
                                const Text('Advanced Options',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 12),
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
                              title: const Text('Enable Metrics'),
                              value: _useMetrics,
                              onChanged: (val) => setState(() => _useMetrics = val!),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              decoration: InputDecoration(
                                labelText: 'Region (e.g. hkg, sin, lax)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
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
                              decoration: InputDecoration(
                                labelText: 'Edge IP Version',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              decoration: InputDecoration(
                                labelText: 'Custom Hostname',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onChanged: (val) => setState(() => _customHostname = val),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _customArgsController,
                              decoration: InputDecoration(
                                labelText: 'Custom arguments (e.g. --no-tls-verify)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Control Buttons & Status
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Row(
                              children: [
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
                              ],
                            ),
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
                            Row(
                              children: [
                                Icon(Icons.memory, size: 18, color: Colors.cyan),
                                const SizedBox(width: 4),
                                Text(_cpuInfo),
                                const SizedBox(width: 24),
                                Icon(Icons.thermostat, size: 18, color: Colors.orange),
                                const SizedBox(width: 4),
                                Text(_tempInfo),
                                const Spacer(),
                                if (_isRunning)
                                  const Icon(Icons.circle, color: Colors.green, size: 12),
                                if (!_isRunning && _binaryReady)
                                  const Icon(Icons.circle, color: Colors.grey, size: 12),
                                if (!_binaryReady)
                                  const Icon(Icons.circle, color: Colors.red, size: 12),
                                const SizedBox(width: 4),
                                Text(
                                  _isRunning ? 'Running' : _binaryReady ? 'Ready' : 'Init...',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Log Card
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.terminal, color: Colors.greenAccent),
                                const SizedBox(width: 8),
                                const Text('Log Output',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                const Spacer(),
                                TextButton.icon(
                                  onPressed: _copyLog,
                                  icon: const Icon(Icons.copy, size: 16),
                                  label: const Text('Copy'),
                                ),
                              ],
                            ),
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
                                reverse: false,
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
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
