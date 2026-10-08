import 'package:flutter/material.dart';

import '../theme.dart';
import 'desktop_settings.dart';
import 'dock_controller.dart';

/// Свёрнутое окно: маленькая зелёная кнопка у края экрана, посередине по высоте.
/// Всё остальное место на экране свободно. Нажатие разворачивает окно обратно.
class CollapsedStrip extends StatelessWidget {
  const CollapsedStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final dockRight = DesktopSettings.instance.dockRight;
    return Material(
      color: Metro.green,
      child: InkWell(
        onTap: DockController.instance.expand,
        child: Center(
          child: Icon(
            dockRight ? Icons.chevron_left : Icons.chevron_right,
            size: 28,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
