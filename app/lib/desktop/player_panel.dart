import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'cover_image.dart';
import 'desktop_settings.dart';
import 'v_slider.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Верхний блок шторки: обложка, название, полоса позиции, кнопки и громкость.
/// Громкость - вертикальная полоса со стороны, к которой прижато окно ([dockRight]).
class PlayerPanel extends StatefulWidget {
  const PlayerPanel({super.key, required this.dockRight});

  final bool dockRight;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  double? _drag;

  Widget _volume(PlayerService ps) {
    final v = ps.volume;
    return SizedBox(
      width: 40,
      child: Column(
        children: [
          Icon(v <= 0 ? Icons.volume_off : Icons.volume_up, size: 20, color: Metro.textDim),
          const SizedBox(height: 6),
          Expanded(
            child: MetroVSlider(
              value: v,
              onChanged: ps.setVolume,
              onChangeEnd: (x) => DesktopSettings.instance.setVolume(x),
            ),
          ),
          const SizedBox(height: 6),
          Text('${v.round()}', style: const TextStyle(fontSize: 12, color: Metro.textDim)),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool primary = false,
    String? tooltip,
  }) {
    return Expanded(
      flex: primary ? 2 : 1,
      child: Tooltip(
        message: tooltip ?? '',
        child: Opacity(
          opacity: onPressed == null ? 0.4 : 1,
          child: Material(
            color: primary ? Metro.green : Metro.surface,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 44,
                child: Icon(icon, size: 28, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ps = PlayerService.instance;
    return ListenableBuilder(
      listenable: ps,
      builder: (context, _) {
        final track = ps.current;
        final max = ps.duration.inMilliseconds > 0 ? ps.duration.inMilliseconds.toDouble() : 1.0;
        final value = (_drag ?? ps.position.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
        final hasTrack = track != null;

        final content = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CoverImage(trackId: track?.id, size: 88, isVideo: track?.isVideo ?? false),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track?.title ?? 'Ничего не играет',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track == null ? 'Выберите трек в списке' : (track.artist ?? track.fileName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, color: Metro.textDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              MetroSlider(
                value: hasTrack ? value : 0.0,
                max: max,
                onChanged: (v) {
                  if (hasTrack) setState(() => _drag = v);
                },
                onChangeEnd: (v) {
                  if (hasTrack) ps.seek(Duration(milliseconds: v.round()));
                  setState(() => _drag = null);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(Duration(milliseconds: hasTrack ? value.round() : 0)),
                      style: const TextStyle(fontSize: 12, color: Metro.textDim)),
                  Text(_fmt(hasTrack ? ps.duration : Duration.zero),
                      style: const TextStyle(fontSize: 12, color: Metro.textDim)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _controlButton(
                    icon: Icons.skip_previous,
                    tooltip: 'Назад',
                    onPressed: hasTrack && ps.index > 0 ? ps.previous : null,
                  ),
                  const SizedBox(width: 4),
                  _controlButton(
                    icon: ps.playing ? Icons.pause : Icons.play_arrow,
                    tooltip: ps.playing ? 'Пауза' : 'Играть',
                    primary: true,
                    onPressed: hasTrack ? ps.playOrPause : null,
                  ),
                  const SizedBox(width: 4),
                  _controlButton(
                    icon: Icons.skip_next,
                    tooltip: 'Вперёд',
                    onPressed: hasTrack && ps.index < ps.queue.length - 1 ? ps.next : null,
                  ),
                ],
              ),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: SizedBox(
            height: 212,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.dockRight
                  ? [content, const SizedBox(width: 8), _volume(ps)]
                  : [_volume(ps), const SizedBox(width: 8), content],
            ),
          ),
        );
      },
    );
  }
}
