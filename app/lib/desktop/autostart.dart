import 'dart:io';

import '../core_bridge.dart';

/// Запуск вместе с Windows: строка в реестре (`HKCU\...\Run`), её пишет ядро.
/// При автозапуске программа стартует свёрнутой (ключ `--autostart`).
class Autostart {
  static const flag = '--autostart';

  static String get command => '"${Platform.resolvedExecutable}" $flag';

  static Future<bool> isEnabled() async {
    final r = await Core.call('autostart_get') as Map<String, dynamic>;
    return r['command'] != null;
  }

  static Future<void> setEnabled(bool on) =>
      Core.call('autostart_set', {'command': on ? command : ''});

  /// Если автозапуск включён, но указывает на другой путь к программе
  /// (её перенесли), запись обновляется. Ошибки не мешают запуску.
  static Future<void> refresh() async {
    if (!Platform.isWindows) return;
    try {
      final r = await Core.call('autostart_get') as Map<String, dynamic>;
      final current = r['command'];
      if (current is String && current != command) {
        await Core.call('autostart_set', {'command': command});
      }
    } catch (_) {}
  }
}
