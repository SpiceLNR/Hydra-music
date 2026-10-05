import 'package:flutter/material.dart';

import '../player_service.dart';
import '../screens/player_screen.dart';
import '../theme.dart';

/// Панель «Сейчас играет»: название трека, пауза/play, по нажатию открывает плеер.
/// Скрыта, пока ничего не играло. Ставится внизу экранов (кроме настроек и самого плеера).
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key, this.safeBottom = false});

  /// true, если под панелью нет других кнопок и нужен отступ от системной полосы.
  final bool safeBottom;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerService.hasTrack,
      builder: (context, has, _) {
        if (!has) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: PlayerService.instance,
          builder: (context, _) {
            final ps = PlayerService.instance;
            final t = ps.current;
            final bar = Material(
              color: Metro.greenDark,
              child: InkWell(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen())),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  child: Row(
                    children: [
                      Icon(ps.playing ? Icons.graphic_eq : Icons.pause),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          t == null ? 'Сейчас играет' : 'Сейчас играет: ${t.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      IconButton(
                        tooltip: ps.playing ? 'Пауза' : 'Играть',
                        onPressed: ps.playOrPause,
                        icon: Icon(ps.playing ? Icons.pause : Icons.play_arrow),
                      ),
                    ],
                  ),
                ),
              ),
            );
            return safeBottom ? SafeArea(top: false, child: bar) : bar;
          },
        );
      },
    );
  }
}
