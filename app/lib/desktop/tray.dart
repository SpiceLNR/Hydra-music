import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

import 'dock_controller.dart';
import '../l10n/l10n.dart';

/// Значок Hydra Music в области уведомлений Windows (трей).
///
/// Левый клик разворачивает шторку. Правый - меню «Показать» и «Выход».
/// Пока значок есть, крестик в шапке только сворачивает программу:
/// выйти из неё можно через меню значка.
class HydraTray with TrayListener {
  HydraTray._();

  static final HydraTray instance = HydraTray._();

  /// Значок поднялся. Если нет, крестик закрывает программу, как раньше.
  bool ready = false;

  Future<void> init() async {
    if (!Platform.isWindows || ready) return;
    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('Hydra Music');
      await _setMenu();
      trayManager.addListener(this);
      // язык сменился - пункты меню на новом языке
      L10n.instance.addListener(() => unawaited(_setMenu()));
      ready = true;
    } catch (_) {
      ready = false; // без значка всё работает, только крестик снова закрывает программу
    }
  }

  Future<void> _setMenu() => trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: tr('Показать')),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: tr('Выход')),
      ]));

  @override
  void onTrayIconMouseDown() {
    unawaited(DockController.instance.show());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(DockController.instance.show());
      case 'exit':
        unawaited(quit());
    }
  }

  /// «Выход»: убирает значок и закрывает программу.
  Future<void> quit() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    ready = false;
    // если окно почему-то не закрылось, процесс всё равно завершится
    Timer(const Duration(seconds: 3), () => exit(0));
    await DockController.instance.close();
  }
}
