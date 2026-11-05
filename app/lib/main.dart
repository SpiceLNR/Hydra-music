import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_messenger.dart';
import 'desktop/autostart.dart';
import 'desktop/collapsed_strip.dart';
import 'desktop/desktop_settings.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/dock_controller.dart';
import 'desktop/tray.dart';
import 'l10n/l10n.dart';
import 'library_controller.dart';
import 'player_service.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
import 'updater.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // язык интерфейса: как в системе или выбранный в настройках
  await L10n.instance.load();
  WidgetsBinding.instance.addObserver(_LocaleWatcher());
  // mpv нужен только на Windows; на Android играет ExoPlayer
  if (!Platform.isAndroid) MediaKit.ensureInitialized();
  if (Platform.isWindows) {
    // окно-шторка у края экрана; настройки (сторона, ширина, громкость) читаются здесь
    await DockController.instance.init();
    PlayerService.instance.volume = DesktopSettings.instance.volume;
  }
  // Фоновая служба музыки (Android). Не бросает ошибок: при сбое всё работает без неё.
  await PlayerService.instance.initBackground();
  hydraLibrary.init(); // не ждём: интерфейс открывается сразу, статус виден на главном экране
  runApp(const HydraApp());
  if (Platform.isWindows) {
    // при запуске вместе с Windows (--autostart) программа сразу свёрнута у края
    final startCollapsed = args.contains(Autostart.flag);
    // окно показывается только после первого кадра: без белой вспышки при запуске
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => DockController.instance.reveal(startCollapsed: startCollapsed));
    unawaited(HydraTray.instance.init());
    unawaited(Autostart.refresh());
  }
  // проверка новой версии: сейчас и раз в 6 часов (Windows и Android, только сборки из CI)
  UpdateService.instance.start();
}

/// Язык системы сменился: при выборе «как в системе» интерфейс переключается сам.
class _LocaleWatcher with WidgetsBindingObserver {
  @override
  void didChangeLocales(List<Locale>? locales) => L10n.instance.systemLocaleChanged();
}

class HydraApp extends StatelessWidget {
  const HydraApp({super.key});

  @override
  Widget build(BuildContext context) {
    // при смене языка дерево интерфейса строится заново (ключ), чтобы перевелись все экраны
    return ListenableBuilder(
      listenable: L10n.instance,
      builder: (context, _) => _app(),
    );
  }

  Widget _app() {
    return MaterialApp(
      key: ValueKey(L10n.instance.lang),
      title: 'Hydra Music',
      scaffoldMessengerKey: messengerKey,
      debugShowCheckedModeBanner: false,
      theme: Metro.theme(),
      // Windows: в свёрнутом виде поверх всего (в том числе поверх открытых экранов
      // «Устройства»/«Настройки») показывается только кнопка-стрелка; навигатор остаётся
      // под ней скрытым, поэтому после разворачивания экран на месте.
      builder: Platform.isWindows
          ? (context, child) => ValueListenableBuilder<bool>(
                valueListenable: DockController.instance.collapsed,
                builder: (context, collapsed, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(offstage: collapsed, child: child),
                    if (collapsed) const CollapsedStrip(),
                  ],
                ),
              )
          : null,
      home: Platform.isWindows ? const DesktopShell() : const HomeScreen(),
    );
  }
}
