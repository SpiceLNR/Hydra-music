import 'package:flutter/material.dart';

import 'dock_controller.dart';

/// Узкая область у внутреннего края окна: потяните её, чтобы изменить ширину.
/// Системной рамки у окна нет, поэтому размер меняет приложение по положению курсора.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (_) => DockController.instance.resizeToCursor(),
        child: const SizedBox(width: 6),
      ),
    );
  }
}
