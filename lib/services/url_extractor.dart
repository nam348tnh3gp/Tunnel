/// Pulls the public URL out of a single cloudflared log line.
class UrlExtractor {
  UrlExtractor._();

  static final RegExp _quick = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com');

  // Matches both  "hostname":"x"  and the escaped form  \"hostname\":\"x\"
  static final RegExp _hostname = RegExp(r'\\?"hostname\\?":\s*\\?"([^"\\]+)');

  static String? extract(String line) {
    final q = _quick.firstMatch(line);
    if (q != null) return q.group(0);

    for (final m in _hostname.allMatches(line)) {
      final host = m.group(1) ?? '';
      if (host.isNotEmpty && !host.startsWith('*')) return 'https://$host';
    }
    return null;
  }
}
