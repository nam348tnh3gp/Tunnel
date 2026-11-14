import 'dart:io';

const List<String> kProtocols = ['auto', 'quic', 'http2'];
const List<String> kEdgeIpVersions = ['auto', '4', '6'];

/// Matches a Cloudflare tunnel token (base64 JSON, always starts with "eyJ").
final RegExp kTokenPattern = RegExp(r'eyJ[A-Za-z0-9_\-+/=]{20,}');

/// Accepts a raw token, or a pasted command such as
/// `cloudflared tunnel run --token eyJ...`, and returns just the token.
String normalizeToken(String input) {
  final trimmed = input.trim();
  return kTokenPattern.firstMatch(trimmed)?.group(0) ?? trimmed;
}

/// Masks anything that looks like a tunnel token (and the exact [token]).
String redactToken(String text, {String token = ''}) {
  var out = text;
  if (token.isNotEmpty) out = out.replaceAll(token, '***');
  return out.replaceAll(kTokenPattern, 'eyJ***');
}

/// Shell-like splitting that understands "double" and 'single' quotes.
List<String> splitArgs(String input) {
  final args = <String>[];
  final buf = StringBuffer();
  String? quote;
  var inArg = false;
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buf.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      inArg = true;
    } else if (ch.trim().isEmpty) {
      if (inArg) {
        args.add(buf.toString());
        buf.clear();
        inArg = false;
      }
    } else {
      buf.write(ch);
      inArg = true;
    }
  }
  if (quote != null) {
    throw const FormatException('Unterminated quote in custom arguments.');
  }
  if (inArg) args.add(buf.toString());
  return args;
}

T _get<T>(Map<String, dynamic> j, String key, T fallback) {
  final v = j[key];
  return v is T ? v : fallback;
}

/// Everything the user can configure. The token is stored separately
/// (secure storage) and never serialised here.
class TunnelConfig {
  const TunnelConfig({
    this.quickMode = false,
    this.port = 8000,
    this.protocol = 'auto',
    this.postQuantum = false,
    this.diagnostics = true,
    this.overwriteDns = false,
    this.region = '',
    this.edgeIpVersion = 'auto',
    this.edgeBindAddress = '',
    this.label = '',
    this.customArgs = '',
    this.autoRestart = true,
  });

  final bool quickMode;
  final int port;
  final String protocol;
  final bool postQuantum;
  final bool diagnostics;
  final bool overwriteDns;
  final String region;
  final String edgeIpVersion;
  final String edgeBindAddress;
  final String label;
  final String customArgs;
  final bool autoRestart;

  TunnelConfig copyWith({
    bool? quickMode,
    int? port,
    String? protocol,
    bool? postQuantum,
    bool? diagnostics,
    bool? overwriteDns,
    String? region,
    String? edgeIpVersion,
    String? edgeBindAddress,
    String? label,
    String? customArgs,
    bool? autoRestart,
  }) {
    return TunnelConfig(
      quickMode: quickMode ?? this.quickMode,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      postQuantum: postQuantum ?? this.postQuantum,
      diagnostics: diagnostics ?? this.diagnostics,
      overwriteDns: overwriteDns ?? this.overwriteDns,
      region: region ?? this.region,
      edgeIpVersion: edgeIpVersion ?? this.edgeIpVersion,
      edgeBindAddress: edgeBindAddress ?? this.edgeBindAddress,
      label: label ?? this.label,
      customArgs: customArgs ?? this.customArgs,
      autoRestart: autoRestart ?? this.autoRestart,
    );
  }

  Map<String, dynamic> toJson() => {
        'quickMode': quickMode,
        'port': port,
        'protocol': protocol,
        'postQuantum': postQuantum,
        'diagnostics': diagnostics,
        'overwriteDns': overwriteDns,
        'region': region,
        'edgeIpVersion': edgeIpVersion,
        'edgeBindAddress': edgeBindAddress,
        'label': label,
        'customArgs': customArgs,
        'autoRestart': autoRestart,
      };

  factory TunnelConfig.fromJson(Map<String, dynamic> j) {
    const d = TunnelConfig();
    final protocol = _get(j, 'protocol', d.protocol);
    final edge = _get(j, 'edgeIpVersion', d.edgeIpVersion);
    return TunnelConfig(
      quickMode: _get(j, 'quickMode', d.quickMode),
      port: _get(j, 'port', d.port),
      protocol: kProtocols.contains(protocol) ? protocol : d.protocol,
      postQuantum: _get(j, 'postQuantum', d.postQuantum),
      diagnostics: _get(j, 'diagnostics', d.diagnostics),
      overwriteDns: _get(j, 'overwriteDns', d.overwriteDns),
      region: _get(j, 'region', d.region),
      edgeIpVersion: kEdgeIpVersions.contains(edge) ? edge : d.edgeIpVersion,
      edgeBindAddress: _get(j, 'edgeBindAddress', d.edgeBindAddress),
      label: _get(j, 'label', d.label),
      customArgs: _get(j, 'customArgs', d.customArgs),
      autoRestart: _get(j, 'autoRestart', d.autoRestart),
    );
  }

  /// Human-readable problems; empty list means the config is usable.
  List<String> validate() {
    final errors = <String>[];
    if (quickMode && (port < 1 || port > 65535)) {
      errors.add('Port must be between 1 and 65535.');
    }
    if (region.isNotEmpty && !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(region)) {
      errors.add('Region may only contain letters, digits and "-".');
    }
    if (edgeBindAddress.isNotEmpty &&
        InternetAddress.tryParse(edgeBindAddress) == null) {
      errors.add('Edge bind address is not a valid IP address.');
    }
    try {
      for (final a in splitArgs(customArgs)) {
        if (a == '--token' || a.startsWith('--token=')) {
          errors.add(
              'Do not put --token in custom arguments; use the Tunnel Token field.');
          break;
        }
      }
    } on FormatException catch (e) {
      errors.add(e.message);
    }
    return errors;
  }

  /// Arguments for cloudflared. In token mode the token itself is passed via
  /// the TUNNEL_TOKEN environment variable (not argv) so it never shows up in
  /// `ps` output or in the log.
  List<String> buildArgs() {
    final args = quickMode
        ? <String>['tunnel', '--url', 'http://localhost:$port']
        : <String>['tunnel', 'run'];
    if (protocol != 'auto') args.addAll(['--protocol', protocol]);
    if (postQuantum) args.add('--post-quantum');
    if (!diagnostics) args.add('--management-diagnostics=false');
    if (overwriteDns) args.add('--overwrite-dns');
    if (region.isNotEmpty) args.addAll(['--region', region]);
    if (edgeIpVersion != 'auto') args.addAll(['--edge-ip-version', edgeIpVersion]);
    if (edgeBindAddress.isNotEmpty) {
      args.addAll(['--edge-bind-address', edgeBindAddress]);
    }
    if (label.isNotEmpty) args.addAll(['--label', label]);
    args.addAll(splitArgs(customArgs));
    return args;
  }
}
