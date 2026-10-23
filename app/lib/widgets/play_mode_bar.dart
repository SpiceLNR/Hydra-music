import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';

/// Подписи режимов в порядке слева направо.
const Map<PlayMode, String> _labels = {
  PlayMode.repeat: 'Повтор',
  PlayMode.standard: 'Стандартный',
  PlayMode.shuffle: 'Разнобой',
  PlayMode.anarchy: 'Анархия',
};

/// Цвет акцента плеера: зелёный, а в «Анархии» кроваво-красный.
Color accentFor(PlayMode m) => m == PlayMode.anarchy ? Metro.blood : Metro.green;

/// Цвет фона плеера (null - обычный).
Color? backgroundFor(PlayMode m) => m == PlayMode.anarchy ? Metro.bloodBg : null;

/// Цвет неактивных плоских кнопок.
Color surfaceFor(PlayMode m) => m == PlayMode.anarchy ? Metro.bloodDark : Metro.surface;

/// Широкий горизонтальный переключатель режимов: Повтор | Стандартный | Разнобой | Анархия.
class PlayModeBar extends StatelessWidget {
  const PlayModeBar({super.key, this.height = 36});

  final double height;

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    final current = ps.mode;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (final m in PlayMode.values) ...[
            if (m != PlayMode.values.first) const SizedBox(width: 2),
            Expanded(
              child: Material(
                color: m == current ? accentFor(current) : surfaceFor(current),
                child: InkWell(
                  onTap: () => ps.setMode(m),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _labels[m]!,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: m == current ? FontWeight.w700 : FontWeight.w400,
                            color: m == current ? Colors.white : Metro.textDim,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
