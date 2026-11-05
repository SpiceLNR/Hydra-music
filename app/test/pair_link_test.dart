import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/net_service.dart';

void main() {
  final key = 'a1' * 32;
  final secret = '0f' * 32;
  final endpoint = '7c' * 32;

  PairLink link({int port = PairLink.defaultPort, String ep = ''}) => PairLink(
        deviceId: 'd1',
        name: 'ПК',
        publicKey: key,
        secret: secret,
        port: port,
        addrs: ['192.168.1.10', '10.0.0.5'],
        endpoint: ep,
      );

  test('короткая ссылка читается обратно без потерь', () {
    final uri = link(ep: endpoint).toUri();
    final back = PairLink.parse(uri)!;
    expect(back.publicKey, key);
    expect(back.secret, secret);
    expect(back.endpoint, endpoint);
    expect(back.port, PairLink.defaultPort);
    expect(back.addrs, ['192.168.1.10', '10.0.0.5']);
    expect(uri.contains('p='), isFalse, reason: 'стандартный порт не пишется');
  });

  test('нестандартный порт сохраняется', () {
    expect(PairLink.parse(link(port: 50000).toUri())!.port, 50000);
  });

  test('ссылка заметно короче прежней (hex и порт)', () {
    final old = Uri(scheme: 'hydra', host: 'pair', queryParameters: {
      'k': key,
      's': secret,
      'p': '47475',
      'a': '192.168.1.10,10.0.0.5',
      'e': endpoint,
    }).toString();
    final now = link(ep: endpoint).toUri();
    expect(old.length - now.length, greaterThanOrEqualTo(60));
  });

  test('старая ссылка в hex по-прежнему понимается', () {
    final old = 'hydra://pair?k=$key&s=$secret&p=47475&a=192.168.1.10&e=$endpoint';
    final back = PairLink.parse(old)!;
    expect(back.publicKey, key);
    expect(back.secret, secret);
    expect(back.endpoint, endpoint);
    expect(back.port, 47475);
  });

  test('повреждённый ключ отвергается', () {
    expect(PairLink.parse('hydra://pair?k=abc&s=$secret&a=1.2.3.4'), isNull);
    expect(PairLink.parse('hydra://pair?k=${PairLink.compact(key)}&a=1.2.3.4'), isNull);
    expect(PairLink.parse('https://pair?k=$key&s=$secret&a=1.2.3.4'), isNull);
    expect(PairLink.expand('!' * 43), isNull);
  });

  test('compact и expand взаимно обратны', () {
    for (final h in [key, secret, endpoint, 'ff' * 32, '00' * 32]) {
      final c = PairLink.compact(h);
      expect(c.length, 43);
      expect(PairLink.expand(c), h);
    }
  });
}
