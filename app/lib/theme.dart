import 'package:flutter/material.dart';

/// Metro-палитра: плоско, без скруглений и теней, зелёный акцент.
class Metro {
  static const green = Color(0xFF60A917);
  static const greenDark = Color(0xFF3F7A0A);
  static const bg = Color(0xFF000000);
  static const surface = Color(0xFF1B1B1B);
  static const textDim = Color(0xFFAAAAAA);
  static const danger = Color(0xFFE51400);

  // режим «Анархия»: зелёные элементы плеера становятся красными
  static const blood = Color(0xFFE51400);

  /// Подсветка нажатия вместо круглой «волны».
  static const press = Color(0x33FFFFFF);

  static const fontFamily = 'Selawik'; // если шрифта нет, Flutter возьмёт системный

  static const OutlineInputBorder _frame = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: Colors.white54, width: 2),
  );

  /// Плоское прямоугольное поле ввода.
  static InputDecoration inputDecoration({String? hint}) => InputDecoration(
        hintText: hint,
        border: _frame,
        enabledBorder: _frame,
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: green, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: green,
      secondary: green,
      surface: surface,
      error: danger,
    );
    const square = RoundedRectangleBorder();
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: fontFamily,
      splashFactory: NoSplash.splashFactory,
      highlightColor: press,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: MetroPageTransitionsBuilder(),
          TargetPlatform.windows: MetroPageTransitionsBuilder(),
          TargetPlatform.linux: MetroPageTransitionsBuilder(),
          TargetPlatform.iOS: MetroPageTransitionsBuilder(),
          TargetPlatform.macOS: MetroPageTransitionsBuilder(),
          TargetPlatform.fuchsia: MetroPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
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
          shape: square,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white54, width: 2),
          shape: square,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: green, shape: square),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: square),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: square,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: Colors.white, fontSize: 16),
        actionTextColor: green,
        shape: square,
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(color: Color(0xFF2B2B2B)),
        textStyle: TextStyle(color: Colors.white, fontSize: 14),
      ),
      scrollbarTheme: const ScrollbarThemeData(radius: Radius.zero),
    );
  }
}

/// Смена экранов без скруглённых «карточек»: короткое появление и сдвиг на 8%.
class MetroPageTransitionsBuilder extends PageTransitionsBuilder {
  const MetroPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}
