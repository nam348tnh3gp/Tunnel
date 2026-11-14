import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/arguments.dart';
import '../models/tunnel_config.dart';
import '../services/log_buffer.dart';
import '../services/settings_store.dart';
import '../services/system_monitor.dart';
import '../services/tunnel_runner.dart';

class TunnelPage extends StatefulWidget {
  const TunnelPage({
    super.key,
    required this.runner,
    required this.log,
    required this.store,
    required this.initialConfig,
    required this.initialToken,
  });

  final TunnelRunner runner;
  final LogBuffer log;
  final SettingsStore store;
  final TunnelConfig initialConfig;
  final String initialToken;

  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> with WidgetsBindingObserver {
  late TunnelConfig _config;
  final _token = TextEditingController();
  final _port = TextEditingController();
  final _region = TextEditingController();
  final _bind = TextEditingController();
  final _label = TextEditingController();
  final _custom = TextEditingController();
  final _logScroll = ScrollController();
  final _monitor = SystemMonitor();

  Timer? _saveTimer;
  bool _showToken = false;
  bool _stick = true;
  String _version = '';

  static final RegExp _errRe = RegExp(r'\b(ERR|ERROR|FTL)\b');
  static final RegExp _warnRe = RegExp(r'\bWRN\b');

  TunnelRunner get runner => widget.runner;
  LogBuffer get log => widget.log;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = widget.initialConfig;
    _token.text = widget.initialToken;
    _port.text = _config.port.toString();
    _region.text = _config.region;
    _bind.text = _config.edgeBindAddress;
    _label.text = _config.label;
    _custom.text = _config.customArgs;
    for (final c in [_port, _region, _bind, _label, _custom]) {
      c.addListener(_onTextChanged);
    }
    _logScroll.addListener(_onLogScroll);
    _monitor.start();
    unawaited(runner.init());
    unawaited(_loadVersion());
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _monitor.start();
    } else if (state == AppLifecycleState.paused) {
      _monitor.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _monitor.dispose();
    _logScroll.dispose();
    for (final c in [_token, _port, _region, _bind, _label, _custom]) {
      c.dispose();
    }
    // NOTE: the tunnel is intentionally NOT stopped here.
    super.dispose();
  }

  // ------------------------------------------------------------- helpers

  void _onTextChanged() {
    _apply(_config.copyWith(
      port: int.tryParse(_port.text.trim()) ?? 0,
      region: _region.text.trim(),
      edgeBindAddress: _bind.text.trim(),
      label: _label.text.trim(),
      customArgs: _custom.text.trim(),
    ));
  }

  void _apply(TunnelConfig c) {
    _config = c;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      widget.store.saveConfig(_config);
    });
  }

  void _onLogScroll() {
    if (!_logScroll.hasClients) return;
    final p = _logScroll.position;
    _stick = p.pixels >= p.maxScrollExtent - 48;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Color _lineColor(String l) {
    if (l.contains('❌') || _errRe.hasMatch(l)) return Colors.redAccent;
    if (l.contains('⚠️') || _warnRe.hasMatch(l)) return Colors.orangeAccent;
    if (l.contains('✅')) return Colors.greenAccent;
    return Colors.white70;
  }

  // ------------------------------------------------------------- actions

  Future<void> _ensureNotificationPermission() async {
    try {
      if (!await Permission.notification.isGranted) {
        await Permission.notification.request();
      }
    } catch (_) {}
  }

  Future<void> _onStart() async {
    FocusScope.of(context).unfocus();
    final errors = _config.validate();
    if (errors.isNotEmpty) {
      _snack(errors.first);
      return;
    }
    var token = '';
    if (!_config.quickMode) {
      token = normalizeToken(_token.text);
      if (token.isEmpty) {
        _snack('Please enter a tunnel token');
        return;
      }
      if (token != _token.text) _token.text = token;
      await widget.store.writeToken(token);
    }
    await _ensureNotificationPermission();
    await runner.start(_config, token);
  }

  Future<void> _copyLog() async {
    if (log.length == 0) {
      _snack('Log is empty');
      return;
    }
    await Clipboard.setData(ClipboardData(text: log.text));
    _snack('Log copied to clipboard');
  }

  Future<void> _copyUrl() async {
    if (runner.url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: runner.url));
    _snack('Copied: ${runner.url}');
  }

  Future<void> _openUrl() async {
    final u = Uri.tryParse(runner.url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (e) {
      _snack('Cannot open URL: $e');
    }
  }

  Future<void> _forgetToken() async {
    await widget.store.deleteToken();
    _token.clear();
    _snack('Saved token removed');
  }

  Future<void> _requestBatteryExemption() async {
    try {
      final st = await Permission.ignoreBatteryOptimizations.request();
      _snack(st.isGranted
          ? 'Battery optimization is disabled for this app'
          : 'Battery optimization is still enabled');
    } catch (e) {
      _snack('Cannot request exemption: $e');
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _menu(),
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
            onPressed: runner.clearLog,
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _statusCard(),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: runner,
              builder: (context, _) {
                final locked = runner.status != TunnelStatus.idle;
                return AbsorbPointer(
                  absorbing: locked,
                  child: Opacity(
                    opacity: locked ? 0.55 : 1,
                    child: Column(
                      children: [
                        _modeCard(),
                        const SizedBox(height: 16),
                        _advancedCard(),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            _logCard(),
          ],
        ),
      ),
    );
  }

  Widget _menu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'about':
            _showAbout();
          case 'arguments':
            _showArguments();
          case 'battery':
            _requestBatteryExemption();
          case 'disclaimer':
            _showDisclaimer();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'about',
          child: Row(children: [
            Icon(Icons.info_outline, size: 20),
            SizedBox(width: 12),
            Text('About App'),
          ]),
        ),
        PopupMenuItem(
          value: 'arguments',
          child: Row(children: [
            Icon(Icons.code, size: 20),
            SizedBox(width: 12),
            Text('List Arguments'),
          ]),
        ),
        PopupMenuItem(
          value: 'battery',
          child: Row(children: [
            Icon(Icons.battery_saver, size: 20),
            SizedBox(width: 12),
            Text('Disable battery optimization'),
          ]),
        ),
        PopupMenuItem(
          value: 'disclaimer',
          child: Row(children: [
            Icon(Icons.warning_amber_outlined, size: 20),
            SizedBox(width: 12),
            Text('Disclaimer'),
          ]),
        ),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required Color color,
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (trailing != null) trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------- status card

  Widget _statusCard() {
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) {
        final s = runner.status;
        final active = s != TunnelStatus.idle;
        final canStart = !active && runner.binaryReady;
        final canStop = active && s != TunnelStatus.stopping;

        late final String label;
        late final Color color;
        switch (s) {
          case TunnelStatus.running:
            label = 'Running';
            color = Colors.green;
          case TunnelStatus.starting:
            label = 'Starting…';
            color = Colors.amber;
          case TunnelStatus.restarting:
            label = 'Reconnecting (${runner.restartCount})…';
            color = Colors.amber;
          case TunnelStatus.stopping:
            label = 'Stopping…';
            color = Colors.orange;
          case TunnelStatus.idle:
            if (runner.binaryReady) {
              label = 'Ready';
              color = Colors.grey;
            } else {
              label = runner.initialized ? 'Binary not found' : 'Initializing…';
              color = Colors.red;
            }
        }

        return _section(
          icon: Icons.cloud_outlined,
          color: Colors.blueAccent,
          title: 'Status',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, color: color, size: 12),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: canStart ? _onStart : null,
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
                    onPressed: canStop ? runner.stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ]),
              if (runner.url.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade900.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade300),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Text('🔗 ${runner.url}',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: _openUrl,
                      tooltip: 'Open in browser',
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: _copyUrl,
                      tooltip: 'Copy URL',
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 20, children: [
                if (runner.pid != null)
                  Text('PID ${runner.pid}',
                      style: const TextStyle(fontSize: 12)),
                ValueListenableBuilder<String>(
                  valueListenable: _monitor.cpu,
                  builder: (_, v, __) =>
                      Text(v, style: const TextStyle(fontSize: 12)),
                ),
                ValueListenableBuilder<String>(
                  valueListenable: _monitor.temp,
                  builder: (_, v, __) =>
                      Text(v, style: const TextStyle(fontSize: 12)),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  // ----------------------------------------------------------- mode card

  Widget _modeCard() {
    return _section(
      icon: Icons.settings,
      color: Colors.blueAccent,
      title: 'Tunnel Mode',
      child: Column(children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                  value: false,
                  label: Text('Token'),
                  icon: Icon(Icons.vpn_key)),
              ButtonSegment(
                  value: true,
                  label: Text('Quick (try)'),
                  icon: Icon(Icons.bolt)),
            ],
            selected: {_config.quickMode},
            onSelectionChanged: (sel) =>
                setState(() => _apply(_config.copyWith(quickMode: sel.first))),
          ),
        ),
        const SizedBox(height: 12),
        if (!_config.quickMode)
          TextField(
            controller: _token,
            obscureText: !_showToken,
            maxLines: _showToken ? 3 : 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Tunnel Token',
              hintText: 'Paste token (or the whole install command)',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                        _showToken ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showToken = !_showToken),
                    tooltip: _showToken ? 'Hide token' : 'Show token',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _forgetToken,
                    tooltip: 'Forget saved token',
                  ),
                ],
              ),
            ),
          )
        else
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Local Port',
              hintText: 'Port your service is running on',
            ),
          ),
      ]),
    );
  }

  // ------------------------------------------------------- advanced card

  Widget _advancedCard() {
    String protoLabel(String p) => switch (p) {
          'quic' => 'QUIC',
          'http2' => 'HTTP/2',
          _ => 'Auto (default)',
        };
    String edgeLabel(String v) => switch (v) {
          '4' => 'IPv4',
          '6' => 'IPv6',
          _ => 'Auto',
        };

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.tune, color: Colors.purpleAccent),
        title: const Text('Advanced Options',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          DropdownButtonFormField<String>(
            value: _config.protocol,
            items: [
              for (final p in kProtocols)
                DropdownMenuItem(value: p, child: Text(protoLabel(p))),
            ],
            onChanged: (v) => setState(
                () => _apply(_config.copyWith(protocol: v ?? 'auto'))),
            decoration: const InputDecoration(labelText: 'Protocol'),
          ),
          SwitchListTile(
            title: const Text('Auto-restart on failure'),
            subtitle: const Text('Exponential backoff, max 8 attempts'),
            value: _config.autoRestart,
            onChanged: (v) =>
                setState(() => _apply(_config.copyWith(autoRestart: v))),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('Post-Quantum'),
            value: _config.postQuantum,
            onChanged: (v) =>
                setState(() => _apply(_config.copyWith(postQuantum: v))),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('Management diagnostics'),
            value: _config.diagnostics,
            onChanged: (v) =>
                setState(() => _apply(_config.copyWith(diagnostics: v))),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: const Text('Overwrite DNS'),
            value: _config.overwriteDns,
            onChanged: (v) =>
                setState(() => _apply(_config.copyWith(overwriteDns: v))),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _region,
                decoration: const InputDecoration(
                    labelText: 'Region', hintText: 'e.g. us'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _config.edgeIpVersion,
                items: [
                  for (final v in kEdgeIpVersions)
                    DropdownMenuItem(value: v, child: Text(edgeLabel(v))),
                ],
                onChanged: (v) => setState(
                    () => _apply(_config.copyWith(edgeIpVersion: v ?? 'auto'))),
                decoration: const InputDecoration(labelText: 'Edge IP Ver'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _bind,
                decoration: const InputDecoration(
                    labelText: 'Edge Bind Address', hintText: 'IP address'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _label,
                decoration: const InputDecoration(
                    labelText: 'Label', hintText: 'Connector label'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _custom,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Additional arguments',
              hintText: 'e.g. --no-tls-verify --loglevel debug',
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ log card

  Widget _logCard() {
    return _section(
      icon: Icons.terminal,
      color: Colors.greenAccent,
      title: 'Log Output',
      trailing: TextButton.icon(
        onPressed: _copyLog,
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy'),
      ),
      child: Container(
        height: 300,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListenableBuilder(
          listenable: log,
          builder: (context, _) {
            if (log.length == 0) {
              return const Text('Waiting for output...',
                  style: TextStyle(fontSize: 12, color: Colors.white54));
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_stick && _logScroll.hasClients) {
                _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
              }
            });
            final lines = log.lines;
            return ListView.builder(
              controller: _logScroll,
              itemCount: lines.length,
              itemBuilder: (context, i) => SelectableText(
                lines[i],
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: _lineColor(lines[i]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------- dialogs

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('📱 About Tunnel Controller'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version: ${_version.isEmpty ? '…' : _version}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Cloudflare Tunnel Controller for Android'),
            const SizedBox(height: 8),
            const Text('• Token & Quick (try) modes'),
            const Text('• Foreground service with WakeLock'),
            const Text('• Auto-restart with backoff'),
            const Text('• Settings and token persisted securely'),
            const Text('• ARM64, ARMv7, x86_64, x86'),
            const SizedBox(height: 12),
            Text('📁 Native dir: ${runner.displayNativeDir}'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showArguments() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚙️ Available Arguments'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: kCloudflaredArguments.length,
            itemBuilder: (context, i) {
              final a = kCloudflaredArguments[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.code, size: 16),
                title: Text(a.flag,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(a.desc, style: const TextStyle(fontSize: 12)),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showDisclaimer() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ Disclaimer'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This application is an unofficial client for Cloudflare Tunnel.',
                style: TextStyle(fontWeight: FontWeight.bold)),
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
              child: const Text('I Understand')),
        ],
      ),
    );
  }
}
