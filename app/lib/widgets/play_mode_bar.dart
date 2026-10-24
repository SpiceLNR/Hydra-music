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
/// Квадрат-ползунок плавно переезжает на выбранный режим; можно нажать на значок
/// или потянуть ползунок.
class PlayModeBar extends StatefulWidget {
  const PlayModeBar({super.key, this.height = 44});

  final double height;

  @override
  State<PlayModeBar> createState() => _PlayModeBarState();
}

class _PlayModeBarState extends State<PlayModeBar> {
  int? _drag; // во время перетаскивания показываем выбранное место, режим меняем в конце

  static const double _frame = 3;

  int _indexAt(double dx, double width) {
    final seg = (width - _frame * 2) / PlayMode.values.length;
    return ((dx - _frame) / seg).floor().clamp(0, PlayMode.values.length - 1);
  }

  void _commit(int i) {
    PlayerService.instance.setMode(PlayMode.values[i]);
  }

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    final accent = accentFor(ps.mode);
    final shown = _drag ?? ps.mode.index;
    final n = PlayMode.values.length;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final seg = (w - _frame * 2) / n;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _commit(_indexAt(d.localPosition.dx, w)),
            onHorizontalDragStart: (d) => setState(() => _drag = _indexAt(d.localPosition.dx, w)),
            onHorizontalDragUpdate: (d) {
              final i = _indexAt(d.localPosition.dx, w);
              if (i != _drag) setState(() => _drag = i);
            },
            onHorizontalDragEnd: (_) {
              final i = _drag;
              setState(() => _drag = null);
              if (i != null) _commit(i);
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Color.lerp(Colors.black, accent, 0.35)!, width: _frame),
              ),
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: seg * shown,
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
                            child: Center(
                              child: Icon(
                                _icons[m],
                                size: 24,
                                color: m.index == shown ? Colors.white : Metro.textDim,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
