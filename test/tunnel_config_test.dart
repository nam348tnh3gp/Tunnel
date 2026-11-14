import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_controller/models/tunnel_config.dart';

void main() {
  group('buildArgs', () {
    test('token mode default', () {
      expect(const TunnelConfig().buildArgs(), ['tunnel', 'run']);
    });

    test('quick mode uses --url with port', () {
      expect(
        const TunnelConfig(quickMode: true, port: 3000).buildArgs(),
        ['tunnel', '--url', 'http://localhost:3000'],
      );
    });

    test('optional flags keep a stable order', () {
      const c = TunnelConfig(protocol: 'http2', region: 'us', label: 'phone');
      expect(c.buildArgs(), [
        'tunnel', 'run', '--protocol', 'http2', '--region', 'us', '--label', 'phone',
      ]);
    });

    test('the token never appears in argv', () {
      final args = const TunnelConfig().buildArgs();
      expect(args.contains('--token'), isFalse);
    });
  });

  group('splitArgs', () {
    test('handles quotes', () {
      expect(splitArgs('--a "b c" \'d\' e=f'), ['--a', 'b c', 'd', 'e=f']);
    });

    test('empty input', () {
      expect(splitArgs('   '), isEmpty);
    });

    test('unterminated quote throws', () {
      expect(() => splitArgs('--a "b'), throwsFormatException);
    });
  });

  group('validate', () {
    test('defaults are valid', () {
      expect(const TunnelConfig().validate(), isEmpty);
    });

    test('rejects --token in custom args', () {
      expect(const TunnelConfig(customArgs: '--token abc').validate(), isNotEmpty);
      expect(const TunnelConfig(customArgs: '--token=abc').validate(), isNotEmpty);
    });

    test('port is only checked in quick mode', () {
      expect(const TunnelConfig(port: 0).validate(), isEmpty);
      expect(const TunnelConfig(quickMode: true, port: 0).validate(), isNotEmpty);
      expect(const TunnelConfig(quickMode: true, port: 70000).validate(), isNotEmpty);
    });

    test('rejects invalid bind address', () {
      expect(const TunnelConfig(edgeBindAddress: 'nope').validate(), isNotEmpty);
      expect(const TunnelConfig(edgeBindAddress: '10.0.0.2').validate(), isEmpty);
    });
  });

  group('json', () {
    test('round trip', () {
      const c = TunnelConfig(
        quickMode: true,
        port: 9000,
        protocol: 'quic',
        postQuantum: true,
        region: 'us',
        customArgs: '--loglevel debug',
        autoRestart: false,
      );
      expect(TunnelConfig.fromJson(c.toJson()).toJson(), c.toJson());
    });

    test('bad values fall back to defaults', () {
      final c = TunnelConfig.fromJson({'protocol': 'carrier-pigeon', 'port': 'x'});
      expect(c.protocol, 'auto');
      expect(c.port, 8000);
    });
  });

  group('token helpers', () {
    const token = 'eyJhIjoiMTIzNDU2Nzg5MGFiY2RlZiJ9';

    test('normalizeToken extracts from a pasted command', () {
      expect(normalizeToken('sudo cloudflared service install $token'), token);
      expect(normalizeToken('  $token \n'), token);
    });

    test('redactToken masks tokens', () {
      expect(redactToken('run --token $token ok'), 'run --token eyJ*** ok');
      expect(redactToken('secret-value here', token: 'secret-value'), '*** here');
    });
  });
}
