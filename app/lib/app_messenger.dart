import 'package:flutter/material.dart';

/// Общий ключ для сообщений поверх любого экрана (например, ошибка воспроизведения).
final GlobalKey<ScaffoldMessengerState> messengerKey = GlobalKey<ScaffoldMessengerState>();

void showAppMessage(String text) {
  final state = messengerKey.currentState;
  if (state == null) return;
  state
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 6)));
}
