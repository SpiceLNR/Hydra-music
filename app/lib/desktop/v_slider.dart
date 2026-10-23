import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Вертикальная полоса (громкость): тонкая линия и прямоугольный ползунок, без скруглений.
/// Нажатие и перетаскивание задают значение, колесо мыши меняет его на 5.
class MetroVSlider extends StatelessWidget {
  const MetroVSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.max = 100,
    this.color = Metro.green,
  });

  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 100.0;
        final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0).toDouble();
        final thumbBottom = (h * frac - 5).clamp(0.0, h > 10 ? h - 10 : 0.0).toDouble();

        double toValue(double dy) {
          final f = 1 - (dy / (h <= 0 ? 1 : h)).clamp(0.0, 1.0).toDouble();
          return f * max;
        }

        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final v = (value + (e.scrollDelta.dy < 0 ? 5 : -5)).clamp(0.0, max).toDouble();
              onChanged(v);
              onChangeEnd?.call(v);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onChanged(toValue(d.localPosition.dy)),
            onTapUp: (d) => onChangeEnd?.call(toValue(d.localPosition.dy)),
            onVerticalDragUpdate: (d) => onChanged(toValue(d.localPosition.dy)),
            onVerticalDragEnd: (_) => onChangeEnd?.call(value),
            child: SizedBox(
              width: 24,
              height: double.infinity,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(width: 4, height: h, color: Colors.white24),
                  Container(width: 4, height: h * frac, color: color),
                  Positioned(
                    bottom: thumbBottom,
                    child: Container(width: 18, height: 10, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
