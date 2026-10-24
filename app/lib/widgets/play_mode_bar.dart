import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';

const Map<PlayMode, IconData> _icons = {
  PlayMode.repeat: Icons.repeat_one,
  PlayMode.standard: Icons.playlist_play,
  PlayMode.shuffle: Icons.shuffle,
  PlayMode.anarchy: Icons.local_fire_department,
};

const Map<PlayMode, String> _names = {
  PlayMode.repeat: 'Повтор',
  PlayMode.standard: 'Стандартный',
  PlayMode.shuffle: 'Разнобой',
  PlayMode.anarchy: 'Анархия',
};

/// Цвет акцента плеера: зелёный, а в «Анархии» красный. Им окрашены все
/// «зелёные» элементы плеера (кнопка паузы, полосы, переключатель режимов).
Color accentFor(PlayMode m) => m == PlayMode.anarchy ? Metro.blood : Metro.green;

/// Широкий переключатель режимов в виде ползунка: Повтор | Стандартный | Разнобой | Анархия.
/// Режим выбирается нажатием на значок, квадрат-ползунок плавно переезжает на него.
class PlayModeBar extends StatelessWidget {
  const PlayModeBar({super.key, this.height = 44});

  final double height;

  static const double _frame = 3;

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    // сам слушает плеер: родитель держит его как const и сам его не перестраивает
    return ListenableBuilder(
      listenable: ps,
      builder: (context, _) {
        final accent = accentFor(ps.mode);
        final selected = ps.mode.index;
        final n = PlayMode.values.length;
        return SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final seg = (constraints.maxWidth - _frame * 2) / n;
              return Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: Color.lerp(Colors.black, accent, 0.35)!, width: _frame),
                ),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      left: seg * selected,
                      top: 0,
                      bottom: 0,
                      width: seg,
                      child: ColoredBox(color: accent),
                    ),
                    Row(
                      children: [
                        for (final m in PlayMode.values)
                          Expanded(
                            child: Tooltip(
                              message: _names[m]!,
                              child: InkWell(
                                onTap: () => ps.setMode(m),
                                child: Center(
                                  child: Icon(
                                    _icons[m],
                                    size: 24,
                                    color: m.index == selected ? Colors.white : Metro.textDim,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
