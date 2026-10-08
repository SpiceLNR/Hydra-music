import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_messenger.dart';
import 'desktop/desktop_settings.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/dock_controller.dart';
import 'library_controller.dart';
import 'player_service.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    // окно показывается только после первого кадра: без белой вспышки при запуске
    WidgetsBinding.instance.addPostFrameCallback((_) => DockController.instance.reveal());
  }
}

class HydraApp extends StatelessWidget {
  const HydraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hydra Music',
      scaffoldMessengerKey: messengerKey,
      debugShowCheckedModeBanner: false,
      theme: Metro.theme(),
      home: Platform.isWindows ? const DesktopShell() : const HomeScreen(),
    );
  }
}
