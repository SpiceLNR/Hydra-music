import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hydra_music/l10n/l10n.dart';
import 'package:hydra_music/l10n/strings_en.dart';
import 'package:hydra_music/l10n/strings_uk.dart';

/// Текст литерала Dart (как в исходнике) -> строка во время выполнения.
String _unescape(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == r'\' && i + 1 < s.length) {
      final c = s[++i];
      b.write(switch (c) { 'n' => '\n', 't' => '\t', _ => c });
    } else {
      b.write(s[i]);
    }
  }
  return b.toString();
}

Set<String> _holes(String s) =>
    RegExp(r'\{[A-Za-z0-9_]+\}').allMatches(s).map((m) => m.group(0)!).toSet();

void main() {
  // все строки tr('...') из кода
  final keys = <String, String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.contains('l10n')) continue;
    final src = f.readAsStringSync();
    for (final m in RegExp(r"\btr\(\s*'((?:[^'\\]|\\.)*)'").allMatches(src)) {
      keys[_unescape(m.group(1)!)] = f.path;
    }
  }

  test('в коде есть переводимые строки', () {
    expect(keys.length, greaterThan(200));
  });

  test('у каждой строки есть английский и украинский перевод', () {
    final noEn = keys.keys.where((k) => !kStringsEn.containsKey(k)).toList();
    final noUk = keys.keys.where((k) => !kStringsUk.containsKey(k)).toList();
    expect(noEn, isEmpty, reason: 'нет английского перевода');
    expect(noUk, isEmpty, reason: 'нет украинского перевода');
  });

  test('подстановки {..} в переводах совпадают с русским', () {
    for (final k in keys.keys) {
      expect(_holes(kStringsEn[k] ?? k), _holes(k), reason: 'en: $k');
      expect(_holes(kStringsUk[k] ?? k), _holes(k), reason: 'uk: $k');
    }
  });

  test('склонение чисел', () {
    L10n.instance.lang = AppLang.ru;
    expect(plural(1, 'трек', 'трека', 'треков'), '1 трек');
    expect(plural(3, 'трек', 'трека', 'треков'), '3 трека');
    expect(plural(11, 'трек', 'трека', 'треков'), '11 треков');
    expect(plural(21, 'трек', 'трека', 'треков'), '21 трек');
    L10n.instance.lang = AppLang.en;
    expect(plural(1, 'трек', 'трека', 'треков'), '1 track');
    expect(plural(5, 'трек', 'трека', 'треков'), '5 tracks');
    expect(tr('Скачать'), 'Download');
    expect(tr('Версия {version} готова', {'version': '1.0'}), 'Version 1.0 is ready');
    L10n.instance.lang = AppLang.uk;
    expect(plural(2, 'трек', 'трека', 'треков'), '2 треки');
    expect(plural(5, 'трек', 'трека', 'треков'), '5 треків');
    expect(tr('Скачать'), 'Завантажити');
    L10n.instance.lang = AppLang.ru;
    expect(tr('Скачать'), 'Скачать');
  });
}
