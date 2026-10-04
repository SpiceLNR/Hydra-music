import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'library_controller.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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
