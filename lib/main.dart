import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:system_info_plus/system_info_plus.dart';

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
  // UI controllers
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '8080');
  bool _useTryMode = false; // true: try mode, false: token mode
  bool _isRunning = false;

  // Tunnel process
  Process? _process;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  String _log = '';
  String _binaryPath = '';
  bool _binaryReady = false;

  // System info
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

  // -------------------- Permissions --------------------
  Future<void> _requestPermissions() async {
    // Trên Android 11+, cần quyền MANAGE_EXTERNAL_STORAGE? Không bắt buộc cho tunnel
    await Permission.storage.request();
  }

  // -------------------- Binary setup --------------------
  Future<void> _initBinary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final binaryPath = '${dir.path}/cloudflared';
      final file = File(binaryPath);

      if (!await file.exists()) {
        // Copy từ assets vào bộ nhớ ứng dụng
        final data = await rootBundle.load('assets/cloudflared');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        // Cấp quyền thực thi (chmod +x)
        await Process.run('chmod', ['+x', binaryPath]);
      }
      setState(() {
        _binaryPath = binaryPath;
        _binaryReady = true;
      });
      _appendLog('✅ Binary cloudflared đã sẵn sàng');
    } catch (e) {
      _appendLog('❌ Lỗi khởi tạo binary: $e');
    }
  }

  // -------------------- System monitor --------------------
  void _startSystemMonitor() {
    _systemTimer = Timer.periodic(Duration(seconds: 2), (timer) {
      if (mounted) {
        setState(() {
          _cpuInfo = 'CPU: ${SystemInfo.cpuUsage.toStringAsFixed(1)}%';
          final temp = SystemInfo.batteryTemperature;
          _tempInfo = '🌡️ Temp: ${temp != null ? temp.toStringAsFixed(1) : 'N/A'} °C';
        });
      }
    });
  }

  // -------------------- Log helper --------------------
  void _appendLog(String msg) {
    setState(() => _log += '\n$msg');
    // Tự động scroll xuống cuối (dùng SingleChildScrollView với controller)
  }

  // -------------------- Tunnel control --------------------
  void _startTunnel() async {
    if (!_binaryReady) {
      _appendLog('⏳ Binary chưa sẵn sàng, vui lòng đợi...');
      return;
    }
    if (_isRunning) {
      _appendLog('⚠️ Tunnel đang chạy');
      return;
    }

    final port = int.tryParse(_portController.text.trim()) ?? 8080;
    List<String> args;

    if (_useTryMode) {
      args = ['tunnel', '--url', 'http://localhost:$port'];
      _appendLog('🚀 Khởi chạy Try Cloudflared trên cổng $port');
    } else {
      final token = _tokenController.text.trim();
      if (token.isEmpty) {
        _appendLog('❌ Vui lòng nhập Token hoặc chọn chế độ Try');
        return;
      }
      args = ['tunnel', '--token', token];
      _appendLog('🔑 Khởi chạy tunnel với token');
    }

    try {
      _process = await Process.start(_binaryPath, args);
      _isRunning = true;
      setState(() {});
      _appendLog('✅ Tunnel đã bắt đầu (PID: ${_process!.pid})');

      // Xử lý stdout
      _stdoutSub = _process!.stdout.transform(utf8.decoder).listen((data) {
        _appendLog('[OUT] $data');
        // Nếu là try mode, tìm URL công khai
        if (_useTryMode) {
          final match = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(data);
          if (match != null) {
            _appendLog('🔗 URL công khai: ${match.group(0)}');
          }
        }
      });

      // Xử lý stderr
      _stderrSub = _process!.stderr.transform(utf8.decoder).listen((data) {
        _appendLog('[ERR] $data');
      });

      // Đợi process kết thúc
      _process!.exitCode.then((code) {
        if (mounted) {
          setState(() {
            _isRunning = false;
            _appendLog('⏹️ Tunnel dừng với mã: $code');
          });
        }
      });
    } catch (e) {
      _appendLog('❌ Lỗi khởi chạy: $e');
    }
  }

  void _stopTunnel() {
    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      _stdoutSub?.cancel();
      _stderrSub?.cancel();
      setState(() {
        _isRunning = false;
        _appendLog('🛑 Đã gửi tín hiệu dừng tunnel');
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
            // Chọn chế độ
            DropdownButtonFormField<bool>(
              value: _useTryMode,
              items: const [
                DropdownMenuItem(value: false, child: Text('🔑 Token')),
                DropdownMenuItem(value: true, child: Text('🌀 Try Cloudflared')),
              ],
              onChanged: (val) => setState(() => _useTryMode = val!),
              decoration: const InputDecoration(
                labelText: 'Chế độ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            // Token field (chỉ hiện nếu không ở try mode)
            if (!_useTryMode)
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'Token Tunnel',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),

            // Port + nút bật/tắt
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Cổng (port)',
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
                  child: const Text('Bật'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isRunning ? _stopTunnel : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    minimumSize: const Size(80, 50),
                  ),
                  child: const Text('Tắt'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Thông tin CPU & nhiệt độ
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

            // Log area
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
                  reverse: true, // tự động scroll xuống cuối
                  child: Text(
                    _log.isEmpty ? 'Đợi hành động...' : _log,
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
