import 'package:flutter/material.dart';

import '../theme.dart';

/// Пункт собственного контекстного меню приложения.
class MetroMenuItem<T> {
  const MetroMenuItem({
    required this.value,
    required this.label,
    required this.icon,
    this.danger = false,
  });

  final T value;
  final String label;
  final IconData icon;

  /// Красный пункт (удаление).
  final bool danger;
}

/// Плоское контекстное меню в стиле Metro. Рисуется самим приложением (не системное меню
/// Windows), поэтому не отнимает фокус у окна и не вызывает его сворачивания.
/// [position] - точка клика в глобальных координатах. Возвращает выбранное значение или null.
Future<T?> showMetroMenu<T>(
  BuildContext context,
  Offset position,
  List<MetroMenuItem<T>> items,
) {
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    color: Metro.surface,
    elevation: 0,
    shape: const RoundedRectangleBorder(side: BorderSide(color: Metro.green, width: 2)),
    items: [
      for (final item in items)
        PopupMenuItem<T>(
          value: item.value,
          height: 44,
          child: Row(
            children: [
              Icon(item.icon, size: 20, color: item.danger ? Metro.danger : Colors.white),
              const SizedBox(width: 12),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 16,
                  color: item.danger ? Metro.danger : Colors.white,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
