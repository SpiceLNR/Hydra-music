import 'package:flutter/material.dart';

/// Metro-палитра: плоско, без скруглений и теней, зелёный акцент.
class Metro {
  static const green = Color(0xFF60A917);
  static const greenDark = Color(0xFF3F7A0A);
  static const bg = Color(0xFF000000);
  static const surface = Color(0xFF1B1B1B);
  static const textDim = Color(0xFFAAAAAA);
  static const danger = Color(0xFFE51400);

  static const fontFamily = 'Selawik'; // если шрифта нет, Flutter возьмёт системный

  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: green,
      secondary: green,
      surface: surface,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 32,
          fontWeight: FontWeight.w300,
          color: Colors.white,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 40, fontWeight: FontWeight.w300),
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w300),
        bodyLarge: TextStyle(fontSize: 18),
        bodyMedium: TextStyle(fontSize: 16, color: textDim),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: green,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: const RoundedRectangleBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white54, width: 2),
          shape: const RoundedRectangleBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 4,
        activeTrackColor: green,
        thumbColor: green,
        inactiveTrackColor: Colors.white24,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
      ),
    );
  }
}
