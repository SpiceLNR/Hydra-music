import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/updater.dart';

void main() {
  test('сравнение версий', () {
    expect(compareVersions('0.26.0', '0.25.4'), greaterThan(0));
    expect(compareVersions('0.25.10', '0.25.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '0.99.99'), greaterThan(0));
    expect(compareVersions('0.26.0', '0.26.0+3'), 0);
    expect(compareVersions('0.25.4', '0.26.0'), lessThan(0));
  });

  test('описание сборки: полное принимается, подозрительное отклоняется', () {
    final ok = {
      'version': '0.26.1',
      'build': 'abc',
      'file': 'hydra-music-windows.zip',
      'size': 100,
      'sha256': 'A' * 64,
    };
    final i = UpdateInfo.parse(ok);
    expect(i, isNotNull);
    expect(i!.sha256, 'a' * 64);
    expect(UpdateInfo.parse({...ok, 'file': '../evil.zip'}), isNull);
    expect(UpdateInfo.parse({...ok, 'file': r'sub\x.zip'}), isNull);
    expect(UpdateInfo.parse({...ok, 'sha256': 'xyz'}), isNull);
    expect(UpdateInfo.parse({...ok, 'size': '100'}), isNull);
    expect(UpdateInfo.parse([1, 2]), isNull);
  });
}
