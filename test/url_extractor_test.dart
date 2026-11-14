import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_controller/services/url_extractor.dart';

void main() {
  test('quick tunnel URL', () {
    const line =
        '2026-11-15T10:00:00Z INF |  https://random-words-here.trycloudflare.com  |';
    expect(UrlExtractor.extract(line), 'https://random-words-here.trycloudflare.com');
  });

  test('named tunnel hostname from escaped JSON', () {
    const line =
        r'INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"app.example.com\",\"service\":\"http://localhost:8000\"},{\"service\":\"http_status:404\"}]}"';
    expect(UrlExtractor.extract(line), 'https://app.example.com');
  });

  test('named tunnel hostname from plain JSON', () {
    const line = r'{"ingress":[{"hostname": "plain.example.com"}]}';
    expect(UrlExtractor.extract(line), 'https://plain.example.com');
  });

  test('wildcard hostnames are ignored', () {
    expect(UrlExtractor.extract(r'{"hostname":"*.example.com"}'), isNull);
  });

  test('unrelated lines', () {
    expect(UrlExtractor.extract('INF Registered tunnel connection'), isNull);
  });
}
