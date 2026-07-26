import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_ce/device_info_ce.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'tunnel_task_handler.dart';

const MethodChannel _nativeChannel = MethodChannel('com.TGNF.tunnel_controller/native');

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
      channelDescription: 'Keep tunnel running in background',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: false,
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
  bool _useOverwriteDns = false;
  String _region = '';
  String _edgeIpVersion = 'auto';
  String _edgeBindAddress = '';
  String _label = '';
  String _customHostname = '';

  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  String _log = '';
  String _cloudflaredPath = '';
  String _nativeDir = '';
  String _displayNativeDir = '';
  bool _binaryReady = false;
  String _tunnelUrl = '';
  int? _tunnelPid;

  String _cpuInfo = '';
  String _tempInfo = '';
  Timer? _systemTimer;

  final ScrollController _logScrollController = ScrollController();
  late SharedPreferences _prefs;
  final _secureStorage = const FlutterSecureStorage();

  // Debounce timer cho _saveState
  Timer? _saveTimer;

  // Danh sách arguments
  final List<Map<String, String>> _allArguments = [
    {'flag': '--output', 'desc': 'Output format for logs (default, json)'},
    {'flag': '--proxy-dns', 'desc': 'Enable DNS proxy'},
    {'flag': '--proxy-dns-port', 'desc': 'DNS proxy port'},
    {'flag': '--proxy-dns-address', 'desc': 'DNS proxy address'},
    {'flag': '--proxy-dns-upstream', 'desc': 'DNS upstream (multiple allowed)'},
    {'flag': '--proxy-dns-max-upstream-conns', 'desc': 'Max upstream connections'},
    {'flag': '--proxy-dns-bootstrap', 'desc': 'DNS bootstrap (multiple allowed)'},
    {'flag': '--credentials-file', 'desc': 'Path to tunnel credentials file'},
    {'flag': '--region', 'desc': 'Cloudflare Edge region (hkg, sin, lax, etc.)'},
    {'flag': '--edge-ip-version', 'desc': 'Edge IP version {4, 6, auto}'},
    {'flag': '--edge-bind-address', 'desc': 'Bind to IP for outgoing connections'},
    {'flag': '--label', 'desc': 'Custom label for connector'},
    {'flag': '--post-quantum', 'desc': 'Enable post-quantum secure tunnel'},
    {'flag': '--management-diagnostics', 'desc': 'Enable diagnostic routes'},
    {'flag': '--overwrite-dns', 'desc': 'Overwrite existing DNS records'},
    {'flag': '--hostname', 'desc': 'Custom tunnel hostname'},
    {'flag': '--protocol', 'desc': 'Protocol {quic, http2}'},
    {'flag': '--no-tls-verify', 'desc': 'Disable TLS verification (insecure)'},
  ];

  @override
  void initState() {
    super.initState();
    _initPrefs().then((_) {
      _initBinary();
      _startSystemMonitor();
      _restoreRunningState();
    });
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
  }

  void _saveState() {
    // Debounce: nếu gọi liên tục thì chỉ lưu sau 2 giây kể từ lần cuối
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _prefs.setString('tunnel_log', _log);
      _prefs.setString('tunnel_url', _tunnelUrl);
      _prefs.setInt('tunnel_pid', _tunnelPid ?? -1);
      _prefs.setBool('tunnel_is_running', _isRunning);
    });
  }

  void _clearState() {
    _saveTimer?.cancel();
    _prefs.remove('tunnel_log');
    _prefs.remove('tunnel_url');
    _prefs.remove('tunnel_pid');
    _prefs.setBool('tunnel_is_running', false);
  }

  String _getDisplayNativeDir(String fullPath) {
    final package = 'com.TGNF.tunnel_controller';
    final idx = fullPath.indexOf(package);
    if (idx != -1) {
      final rest = fullPath.substring(idx + package.length);
      final libIdx = rest.indexOf('/lib');
      if (libIdx != -1) {
        return '/data/app/$package${rest.substring(libIdx)}';
      }
      return '/data/app/$package';
    }
    return fullPath;
  }

  Future<void> _restoreRunningState() async {
    final isRunning = _prefs.getBool('tunnel_is_running') ?? false;
    final pid = _prefs.getInt('tunnel_pid') ?? -1;
    final savedLog = _prefs.getString('tunnel_log') ?? '';
    final savedUrl = _prefs.getString('tunnel_url') ?? '';

    final serviceRunning = await FlutterForegroundTask.isRunningService;

    if (isRunning && serviceRunning) {
      setState(() {
        _isRunning = true;
        _tunnelPid = pid > 0 ? pid : null;
        _log = savedLog.isNotEmpty ? savedLog : '🔄 Tunnel running (recovered)';
        _tunnelUrl = savedUrl;
      });
      if (_tunnelUrl.isNotEmpty) {
        FlutterForegroundTask.updateService(
          notificationTitle: 'Tunnel is running',
          notificationText: _tunnelUrl,
        );
      }
      _appendLog('✅ Recovered tunnel (PID: $pid)');
      return;
    }

    if (savedLog.isNotEmpty) {
      setState(() {
        _log = savedLog + (isRunning ? '\n⚠️ Tunnel was running but service stopped. Reset.' : '');
        _tunnelUrl = savedUrl;
      });
    }
    _clearState();
    setState(() {
      _isRunning = false;
      _tunnelPid = null;
    });
  }

  @override
  void dispose() {
    _stopTunnel();
    _systemTimer?.cancel();
    _saveTimer?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  // ----- KHÔNG CÒN FALLBACK, CHỈ LẤY BINARY TỪ NATIVE DIR -----
  Future<void> _initBinary() async {
    try {
      final String? nativeDir = await _nativeChannel.invokeMethod('getNativeLibraryDir');
      if (nativeDir == null || nativeDir.isEmpty) {
        _appendLog('❌ Cannot get native library directory');
        return;
      }
      _nativeDir = nativeDir;
      _displayNativeDir = _getDisplayNativeDir(nativeDir);
      _appendLog('📁 Native dir: $_displayNativeDir');

      final String cfPath = '$nativeDir/libcloudflared.so';
      if (!File(cfPath).existsSync()) {
        _appendLog('❌ libcloudflared.so not found in native dir');
        return;
      }
      await Process.run('chmod', ['755', cfPath]);
      _cloudflaredPath = cfPath;
      _appendLog('✅ Cloudflared ready');
      setState(() => _binaryReady = true);
    } catch (e) {
      _appendLog('❌ Init binary error: $e');
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
    _saveState(); // gọi debounce
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

  // ---- Menu Functions ----
  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('📱 About Tunnel Controller'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Version: 1.0.1', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Cloudflare Tunnel Controller for Android'),
            const SizedBox(height: 8),
            const Text('• Support Token & Try Mode'),
            const Text('• Foreground Service with WakeLock'),
            const Text('• Real-time system monitoring'),
            const Text('• Full architecture support (ARM64, ARMv7, x86_64, x86)'),
            const SizedBox(height: 12),
            Text('📁 Native dir: $_displayNativeDir'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showArgumentsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚙️ Available Arguments'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: _allArguments.length,
            itemBuilder: (context, index) {
              final arg = _allArguments[index];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.code, size: 16),
                title: Text(arg['flag']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(arg['desc']!, style: const TextStyle(fontSize: 12)),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showDisclaimerDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ Disclaimer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'This application is an unofficial client for Cloudflare Tunnel.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            Text('• Use at your own risk.'),
            Text('• The developer is not responsible for any damages or data loss.'),
            Text('• Cloudflare Tunnel is a service provided by Cloudflare Inc.'),
            Text('• This app does not collect or share any personal data.'),
            SizedBox(height: 12),
            Text(
              'By using this application, you agree to the Cloudflare Terms of Service and Privacy Policy.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I Understand'),
          ),
        ],
      ),
    );
  }

  // ---- Start/Stop Tunnel ----
  void _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary not ready');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel already running');
      return;
    }

    _log = '';
    _tunnelUrl = '';
    _tunnelPid = null;
    _saveState();
    setState(() {});

    // Khởi động foreground service trước
    try {
      final started = await FlutterForegroundTask.startService(
        notificationTitle: 'Tunnel is running',
        notificationText: 'Connecting...',
        callback: startTunnelService,
      );
      if (!started) {
        _appendLog('⚠️ Foreground service not started, but continuing...');
      }
    } catch (e) {
      _appendLog('⚠️ Foreground service error: $e');
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    List<String> args = [];

    String? token;
    if (_useTryMode) {
      args.addAll(['tunnel', '--url', 'http://localhost:$port']);
      _appendLog('🚀 Starting Try Cloudflared on port $port');
    } else {
      // Lấy token từ secure storage hoặc từ text field
      token = await _secureStorage.read(key: 'tunnel_token');
      if (token == null || token.isEmpty) {
        token = _tokenController.text.trim();
        if (token.isEmpty) {
          _appendLog('❌ Please enter Token');
          // Dừng service nếu đã start
          await FlutterForegroundTask.stopService();
          return;
        }
        // Lưu token đã mã hóa
        await _secureStorage.write(key: 'tunnel_token', value: token);
      }
      args.addAll(['tunnel', 'run', '--token', token!]);
      _appendLog('🔑 Starting tunnel with token');
    }

    // Custom args
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

    if (_useOverwriteDns) {
      args.add('--overwrite-dns');
      _appendLog('📝 Overwrite DNS enabled');
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

    if (_edgeBindAddress.isNotEmpty) {
      args.add('--edge-bind-address');
      args.add(_edgeBindAddress);
      _appendLog('🔗 Edge bind address: $_edgeBindAddress');
    }

    if (_label.isNotEmpty) {
      args.add('--label');
      args.add(_label);
      _appendLog('🏷️ Label: $_label');
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

      _tunnelPid = _process!.pid;
      _isRunning = true;
      _saveState();
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
          _saveState();
          FlutterForegroundTask.updateService(
            notificationTitle: 'Tunnel is running',
            notificationText: _tunnelUrl,
          );
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
            _saveState();
            FlutterForegroundTask.updateService(
              notificationTitle: 'Tunnel is running',
              notificationText: _tunnelUrl,
            );
          }
        }
      });

      // Lắng nghe exit code và reset process
      _process!.exitCode.then((code) {
        if (mounted) {
          if (code == -13) {
            _appendLog('⏹️ Stopped by user');
          } else {
            _appendLog('⏹️ Tunnel stopped with code: $code');
          }
          setState(() {
            _isRunning = false;
            _tunnelPid = null;
            _process = null; // reset process
          });
          FlutterForegroundTask.stopService();
          _clearState();
        }
      });
    } catch (e) {
      _appendLog('❌ Error starting: $e');
      // Dừng foreground service và reset state
      await FlutterForegroundTask.stopService();
      _clearState();
      setState(() {
        _isRunning = false;
        _tunnelPid = null;
        _process = null;
      });
    }
  }

  void _stopTunnel() async {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      setState(() {
        _isRunning = false;
        _tunnelPid = null;
        _process = null;
        _tunnelUrl = '';
        _log = '📁 Native dir: $_displayNativeDir\n✅ Cloudflared ready\n✅ Log cleared';
      });
      _saveState();
      FlutterForegroundTask.stopService();
      _clearState();
    } else if (_tunnelPid != null && _tunnelPid! > 0) {
      try {
        await Process.run('kill', ['-15', _tunnelPid.toString()]);
        setState(() {
          _isRunning = false;
          _tunnelPid = null;
          _tunnelUrl = '';
          _log = '📁 Native dir: $_displayNativeDir\n✅ Cloudflared ready\n✅ Log cleared';
        });
        _saveState();
        FlutterForegroundTask.stopService();
        _clearState();
      } catch (e) {
        _appendLog('❌ Failed to kill PID ${_tunnelPid}: $e');
      }
    } else {
      _appendLog('⚠️ No process to stop');
    }
  }

  // ---- Build UI ----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'about':
                _showAboutDialog();
                break;
              case 'arguments':
                _showArgumentsDialog();
                break;
              case 'disclaimer':
                _showDisclaimerDialog();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'about',
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 20),
                  SizedBox(width: 12),
                  Text('About App'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'arguments',
              child: Row(
                children: [
                  Icon(Icons.code, size: 20),
                  SizedBox(width: 12),
                  Text('List Arguments'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'disclaimer',
              child: Row(
                children: [
                  Icon(Icons.warning_amber_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Disclaimer'),
                ],
              ),
            ),
          ],
        ),
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
                                  hintText: 'Paste token from Cloudflare Dashboard',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                maxLines: 2,
                              ),
                            ] else ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _portController,
                                decoration: InputDecoration(
                                  labelText: 'Local Port',
                                  hintText: 'Port your service is running on',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                keyboardType: TextInputType.number,
                              ),
                            ],
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
                            Row(
                              children: [
                                Expanded(
                                  child: CheckboxListTile(
                                    title: const Text('Enable Metrics'),
                                    value: _useMetrics,
                                    onChanged: (val) => setState(() => _useMetrics = val!),
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                Expanded(
                                  child: CheckboxListTile(
                                    title: const Text('Overwrite DNS'),
                                    value: _useOverwriteDns,
                                    onChanged: (val) => setState(() => _useOverwriteDns = val!),
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    decoration: InputDecoration(
                                      labelText: 'Region',
                                      hintText: 'e.g. hkg, sin, lax',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onChanged: (val) => setState(() => _region = val),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: _edgeIpVersion,
                                    items: const [
                                      DropdownMenuItem(value: 'auto', child: Text('Auto')),
                                      DropdownMenuItem(value: '4', child: Text('IPv4')),
                                      DropdownMenuItem(value: '6', child: Text('IPv6')),
                                    ],
                                    onChanged: (val) => setState(() => _edgeIpVersion = val!),
                                    decoration: InputDecoration(
                                      labelText: 'Edge IP Ver',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    decoration: InputDecoration(
                                      labelText: 'Edge Bind Address',
                                      hintText: 'IP address',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onChanged: (val) => setState(() => _edgeBindAddress = val),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    decoration: InputDecoration(
                                      labelText: 'Label',
                                      hintText: 'Connector label',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onChanged: (val) => setState(() => _label = val),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              decoration: InputDecoration(
                                labelText: 'Custom Hostname',
                                hintText: 'Custom tunnel hostname',
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
                                labelText: 'Additional arguments',
                                hintText: 'e.g. --no-tls-verify --proxy-dns',
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
                                    onPressed: _isRunning ? () => _stopTunnel() : null,
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