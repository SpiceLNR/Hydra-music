import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings_en.dart';
import 'strings_uk.dart';

/// Языки интерфейса. Русский - язык исходного текста: строки в коде пишутся по-русски,
/// английский и украинский берутся из таблиц `strings_en.dart` / `strings_uk.dart`.
enum AppLang { ru, en, uk }

/// Выбор языка: «как в системе» или один из трёх. Хранится в настройках приложения.
class L10n extends ChangeNotifier {
  L10n._();

  static final L10n instance = L10n._();

  static const _prefKey = 'app_lang';

  /// `system`, `ru`, `en` или `uk`.
  String choice = 'system';

  AppLang lang = _fromCode(PlatformDispatcher.instance.locale.languageCode);

  /// Язык системы, если он один из трёх; иначе английский.
  static AppLang _fromCode(String code) => switch (code) {
        'ru' => AppLang.ru,
        'uk' => AppLang.uk,
        'en' => AppLang.en,
        _ => AppLang.en,
      };

  /// Код языка для ядра и системных частей (`ru`, `en`, `uk`).
  String get code => lang.name;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      choice = p.getString(_prefKey) ?? 'system';
    } catch (_) {
      choice = 'system';
    }
    _resolve();
  }

  void _resolve() {
    final code = choice == 'system' ? PlatformDispatcher.instance.locale.languageCode : choice;
    lang = _fromCode(code);
  }

  Future<void> setChoice(String value) async {
    if (value == choice) return;
    choice = value;
    _resolve();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefKey, value);
    } catch (_) {
      // не сохранилось: язык сменится до перезапуска
    }
  }

  /// Язык системы сменился, а выбрано «как в системе».
  void systemLocaleChanged() {
    if (choice != 'system') return;
    final before = lang;
    _resolve();
    if (lang != before) notifyListeners();
  }
}

/// Перевод строки интерфейса. [ru] - текст на русском, он же ключ в таблицах переводов;
/// `{имя}` в тексте заменяется значением из [args]. Нет перевода - показывается русский.
String tr(String ru, [Map<String, Object?> args = const {}]) {
  final lang = L10n.instance.lang;
  var s = switch (lang) {
    AppLang.ru => ru,
    AppLang.en => kStringsEn[ru] ?? ru,
    AppLang.uk => kStringsUk[ru] ?? ru,
  };
  if (args.isNotEmpty) {
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  }
  return s;
}

/// Число со словом в нужной форме. Формы задаются для русского (одна, несколько, много)
/// и берутся из таблиц для английского и украинского по ключу [many] (русская форма «много»).
/// Например: `plural(5, 'трек', 'трека', 'треков')` -> «5 треков» / «5 tracks» / «5 треків».
String plural(int n, String one, String few, String many) {
  final lang = L10n.instance.lang;
  if (lang == AppLang.en) {
    final forms = kPluralsEn[many];
    if (forms != null) return '$n ${n == 1 ? forms.$1 : forms.$2}';
  } else if (lang == AppLang.uk) {
    final forms = kPluralsUk[many];
    if (forms != null) return '$n ${_slavic(n, forms.$1, forms.$2, forms.$3)}';
  }
  return '$n ${_slavic(n, one, few, many)}';
}

/// Правило русского и украинского: 1, 21 - одна; 2-4, 22-24 - несколько; иначе - много.
String _slavic(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}
