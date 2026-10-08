import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_settings.dart';
import 'win32_frame.dart';

/// Окно Windows как «шторка» у края экрана.
///
/// Развёрнутое: узкое окно на всю высоту рабочей области (до панели задач), прижато к
/// выбранному краю. Когда пользователь кликает вне приложения (окно теряет фокус),
/// оно само сжимается в маленькую зелёную кнопку (40x40) у того же края, посередине по
/// высоте, и остаётся поверх остальных окон. Кнопка разворачивает окно обратно.
/// В панели задач приложения нет. Рамки Windows у окна нет, ширину меняет [resizeToCursor].
///
/// Пока открыт системный диалог (например, выбор картинки), сворачивание отключено:
/// такие вызовы нужно оборачивать в [guard].
class DockController with WindowListener {
  DockController._();

  static final DockController instance = DockController._();

  /// Размер свёрнутой кнопки.
  static const double collapsedSize = 40;
  static const String _title = 'Hydra Music';
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
      skipTaskbar: true, // приложения нет в панели задач
      title: _title,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      Win32Frame.makeBorderless(_title);
      await _place(expanded: true);
      await windowManager.setSkipTaskbar(true);
      // окно пока скрыто: показываем его после первого кадра (см. [reveal])
    });
    _ready = true;
  }

  /// Показывает окно, когда Flutter уже нарисовал первый кадр: иначе на миг видна
  /// пустая белая рамка. Вызывается из `main` после `runApp`.
  Future<void> reveal() async {
    if (!Platform.isWindows || !_ready) return;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setSkipTaskbar(true);
  }

  Future<Rect> _workArea() async {
    final d = await screenRetriever.getPrimaryDisplay();
    final pos = d.visiblePosition ?? Offset.zero;
    final size = d.visibleSize ?? d.size;
    return Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
  }

  Rect _expandedRect(Rect area, double width) => Rect.fromLTWH(
        settings.dockRight ? area.right - width : area.left,
        area.top,
        width,
        area.height,
      );

  Rect _collapsedRect(Rect area) => Rect.fromLTWH(
        settings.dockRight ? area.right - collapsedSize : area.left,
        area.top + (area.height - collapsedSize) / 2,
        collapsedSize,
        collapsedSize,
      );

  Future<void> _place({required bool expanded}) async {
    _ignoreUntil = DateTime.now().add(const Duration(milliseconds: 800));
    final area = await _workArea();
    if (expanded) {
      final w = settings.width.clamp(DesktopSettings.minWidth, DesktopSettings.maxWidth).toDouble();
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(DesktopSettings.minWidth, _minHeight));
      await windowManager.setMaximumSize(const Size(DesktopSettings.maxWidth, _maxHeight));
      await windowManager.setBounds(_expandedRect(area, w));
    } else {
      await windowManager.setMinimumSize(const Size(collapsedSize, collapsedSize));
      await windowManager.setMaximumSize(const Size(collapsedSize, collapsedSize));
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(_collapsedRect(area));
    }
  }

  bool _resizing = false;

  /// Меняет ширину окна по положению курсора (тянут за край [ResizeHandle]).
  Future<void> resizeToCursor() async {
    if (!_ready || collapsed.value || _busy || _resizing) return;
    _resizing = true;
    try {
      final p = await screenRetriever.getCursorScreenPoint();
      final area = await _workArea();
      final raw = settings.dockRight ? area.right - p.dx : p.dx - area.left;
      final w = raw.clamp(DesktopSettings.minWidth, DesktopSettings.maxWidth).toDouble();
      settings.setWidth(w);
      _ignoreUntil = DateTime.now().add(const Duration(milliseconds: 400));
      await windowManager.setBounds(_expandedRect(area, w));
    } finally {
      _resizing = false;
    }
  }

  /// Сжимает окно в маленькую кнопку у края.
  Future<void> collapse() async {
    if (!_ready || collapsed.value || _busy) return;
    _busy = true;
    try {
      await _place(expanded: false);
      collapsed.value = true;
      await _setButtonVisible(false);
      _startEdgeWatch();
    } finally {
      _busy = false;
    }
  }

  /// Разворачивает кнопку обратно в окно.
  Future<void> expand() async {
    if (!_ready || !collapsed.value || _busy) return;
    _busy = true;
    try {
      _stopEdgeWatch();
      await _setButtonVisible(true);
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

  // ---- кнопка появляется, только когда курсор дошёл до самого края экрана ----

  Timer? _edgeTimer;
  bool _buttonShown = true;
  bool _edgeChecking = false;

  /// Кнопка «спрятана»: окно на месте, но невидимо и пропускает мышь сквозь себя.
  Future<void> _setButtonVisible(bool visible) async {
    if (_buttonShown == visible) return;
    _buttonShown = visible;
    await windowManager.setOpacity(visible ? 1.0 : 0.0);
    await windowManager.setIgnoreMouseEvents(!visible);
  }

  void _startEdgeWatch() {
    _edgeTimer?.cancel();
    _edgeTimer = Timer.periodic(const Duration(milliseconds: 80), (_) => _checkEdge());
  }

  void _stopEdgeWatch() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
  }

  Future<void> _checkEdge() async {
    if (_edgeChecking || _busy || !collapsed.value) return;
    _edgeChecking = true;
    try {
      final p = await screenRetriever.getCursorScreenPoint();
      final area = await _workArea();
      final btn = _collapsedRect(area);
      // расстояние от курсора до края экрана, у которого стоит кнопка
      final fromEdge = settings.dockRight ? area.right - p.dx : p.dx - area.left;
      final nearY = p.dy >= btn.top - 30 && p.dy <= btn.bottom + 30;
      final show = _buttonShown
          ? fromEdge <= collapsedSize + 24 && nearY // уже видна: держим, пока курсор рядом
          : fromEdge <= 2 && nearY; // скрыта: появляется только у самого края
      if (collapsed.value && !_busy) await _setButtonVisible(show);
    } catch (_) {
      // не удалось прочитать курсор: оставляем как есть
    } finally {
      _edgeChecking = false;
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
}
