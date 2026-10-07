import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Настройки окна Windows: сторона закрепления, ширина, автосворачивание, громкость.
/// Хранятся в SharedPreferences; если хранилище недоступно, работают значения по умолчанию.
class DesktopSettings extends ChangeNotifier {
  DesktopSettings._();

  static final DesktopSettings instance = DesktopSettings._();

  static const double minWidth = 320;
  static const double maxWidth = 700;
  static const double defaultWidth = 400;

  /// true - окно прижато к правому краю экрана, false - к левому.
  bool dockRight = true;
  double width = defaultWidth;

  /// Сворачиваться в полоску, когда пользователь кликает вне приложения.
  bool autoCollapse = true;

  /// Громкость плеера, 0..100.
  double volume = 100;

  SharedPreferences? _prefs;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      dockRight = p.getBool('dock_right') ?? true;
      width = (p.getDouble('width') ?? defaultWidth).clamp(minWidth, maxWidth).toDouble();
      autoCollapse = p.getBool('auto_collapse') ?? true;
      volume = (p.getDouble('volume') ?? 100).clamp(0, 100).toDouble();
    } catch (_) {
      // хранилище недоступно: остаются значения по умолчанию
    }
  }

  void setDockRight(bool value) {
    if (dockRight == value) return;
    dockRight = value;
    notifyListeners();
    _prefs?.setBool('dock_right', value);
  }

  void setAutoCollapse(bool value) {
    if (autoCollapse == value) return;
    autoCollapse = value;
    notifyListeners();
    _prefs?.setBool('auto_collapse', value);
  }

  /// Ширину задаёт пользователь, растягивая окно; здесь она только запоминается.
  void setWidth(double value) {
    final w = value.clamp(minWidth, maxWidth).toDouble();
    if ((w - width).abs() < 1) return;
    width = w;
    _prefs?.setDouble('width', w);
  }

  void setVolume(double value) {
    volume = value.clamp(0, 100).toDouble();
    _prefs?.setDouble('volume', volume);
  }
}
