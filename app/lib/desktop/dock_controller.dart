import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_settings.dart';

/// Окно Windows как «шторка» у края экрана.
///
/// Развёрнутое: узкое окно на всю высоту рабочей области (до панели задач), прижато к
/// выбранному краю. Когда пользователь кликает вне приложения (окно теряет фокус),
/// оно само сжимается в узкую вертикальную полоску у того же края и остаётся поверх
/// остальных окон. Кнопка в полоске разворачивает его обратно.
///
/// Пока открыт системный диалог (например, выбор картинки), сворачивание отключено:
/// такие вызовы нужно оборачивать в [guard].
class DockController with WindowListener {
  DockController._();

  static final DockController instance = DockController._();

  /// Ширина свёрнутой полоски.
  static const double stripWidth = 48;
  static const double _minHeight = 360;
  static const double _maxHeight = 10000;

  final ValueNotifier<bool> collapsed = ValueNotifier<bool>(false);
  final DesktopSettings settings = DesktopSettings.instance;

  int _guards = 0;
  bool _busy = false;
  bool _ready = false;
  DateTime _ignoreUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Готовит окно: убирает рамку, ставит у края. Вызывается один раз до `runApp`.
  Future<void> init() async {
    if (!Platform.isWindows) return;
    await settings.load();
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    final options = WindowOptions(
      size: Size(settings.width, 800),
      minimumSize: const Size(DesktopSettings.minWidth, _minHeight),
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: const Color(0xFF000000),
      title: 'Hydra Music',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await _place(expanded: true);
      await windowManager.show();
      await windowManager.focus();
    });
    _ready = true;
  }

  Future<Rect> _workArea() async {
    final d = await screenRetriever.getPrimaryDisplay();
    final pos = d.visiblePosition ?? Offset.zero;
    final size = d.visibleSize ?? d.size;
    return Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
  }

  Future<void> _place({required bool expanded}) async {
    _ignoreUntil = DateTime.now().add(const Duration(milliseconds: 800));
    final area = await _workArea();
    final right = settings.dockRight;
    if (expanded) {
      final w = settings.width.clamp(DesktopSettings.minWidth, DesktopSettings.maxWidth).toDouble();
      await windowManager.setResizable(true);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(DesktopSettings.minWidth, _minHeight));
      await windowManager.setMaximumSize(const Size(DesktopSettings.maxWidth, _maxHeight));
      await windowManager.setBounds(
        Rect.fromLTWH(right ? area.right - w : area.left, area.top, w, area.height),
      );
    } else {
      await windowManager.setMinimumSize(const Size(stripWidth, 100));
      await windowManager.setMaximumSize(const Size(stripWidth, _maxHeight));
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(
        Rect.fromLTWH(right ? area.right - stripWidth : area.left, area.top, stripWidth, area.height),
      );
    }
  }

  /// Сжимает окно в полоску у края.
  Future<void> collapse() async {
    if (!_ready || collapsed.value || _busy) return;
    _busy = true;
    try {
      await _place(expanded: false);
      collapsed.value = true;
    } finally {
      _busy = false;
    }
  }

  /// Разворачивает полоску обратно в окно.
  Future<void> expand() async {
    if (!_ready || !collapsed.value || _busy) return;
    _busy = true;
    try {
      await _place(expanded: true);
      collapsed.value = false;
      await windowManager.focus();
    } finally {
      _busy = false;
    }
  }

  /// Применяет новую сторону закрепления, не меняя состояния (развёрнуто/свёрнуто).
  Future<void> reapply() async {
    if (!_ready || _busy) return;
    _busy = true;
    try {
      await _place(expanded: !collapsed.value);
    } finally {
      _busy = false;
    }
  }

  Future<void> close() => windowManager.close();

  /// Выполняет [action] (диалог выбора файла и т. п.), не давая окну свернуться,
  /// пока системное окно забирает фокус.
  Future<T> guard<T>(Future<T> Function() action) async {
    _guards++;
    try {
      return await action();
    } finally {
      _guards--;
      _ignoreUntil = DateTime.now().add(const Duration(milliseconds: 800));
    }
  }

  @override
  void onWindowBlur() {
    if (!_ready || !settings.autoCollapse || collapsed.value || _guards > 0 || _busy) return;
    if (DateTime.now().isBefore(_ignoreUntil)) return;
    unawaited(collapse());
  }

  @override
  void onWindowResized() {
    unawaited(_rememberWidth());
  }

  Future<void> _rememberWidth() async {
    if (!_ready || collapsed.value || _busy) return;
    if (DateTime.now().isBefore(_ignoreUntil)) return;
    final b = await windowManager.getBounds();
    settings.setWidth(b.width);
  }
}
