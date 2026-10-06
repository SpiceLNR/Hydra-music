import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'library_controller.dart';
import 'player_service.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Фоновая служба музыки (Android). Не бросает ошибок: при сбое всё работает без неё.
  await PlayerService.instance.initBackground();
  hydraLibrary.init(); // не ждём: интерфейс открывается сразу, статус виден на главном экране
  runApp(const HydraApp());
}

class HydraApp extends StatelessWidget {
  const HydraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hydra Music',
      debugShowCheckedModeBanner: false,
      theme: Metro.theme(),
      home: const HomeScreen(),
    );
  }
}
