import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';
import 'cover_image.dart';
import 'desktop_settings.dart';
import 'dock_controller.dart';

/// Свёрнутое окно: узкая вертикальная полоска у края экрана.
/// Сверху обложка (или логотип), внизу «пауза» и «следующий». Маленькая кнопка
/// разворота появляется, когда курсор над полоской.
class CollapsedStrip extends StatefulWidget {
  const CollapsedStrip({super.key});

  @override
  State<CollapsedStrip> createState() => _CollapsedStripState();
}

class _CollapsedStripState extends State<CollapsedStrip> {
  bool _hover = false;

  Widget _button(IconData icon, String tooltip, VoidCallback? onPressed) {
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Material(
          color: Metro.surface,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: DockController.stripWidth - 8,
              height: 40,
              child: Icon(icon, size: 24, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dockRight = DesktopSettings.instance.dockRight;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: Metro.bg,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: ListenableBuilder(
          listenable: PlayerService.instance,
          builder: (context, _) {
            final ps = PlayerService.instance;
            final track = ps.current;
            return Column(
              children: [
                if (track != null)
                  CoverImage(trackId: track.id, size: DockController.stripWidth - 8, isVideo: track.isVideo)
                else
                  Image.asset(
                    'assets/logo.png',
                    width: DockController.stripWidth - 8,
                    height: DockController.stripWidth - 8,
                    errorBuilder: (_, __, ___) =>
                        const SizedBox(width: DockController.stripWidth - 8, height: DockController.stripWidth - 8),
                  ),
                const Spacer(),
                // кнопка разворота: только при наведении
                AnimatedOpacity(
                  opacity: _hover ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: Tooltip(
                      message: 'Развернуть',
                      child: Material(
                        color: Metro.green,
                        child: InkWell(
                          onTap: DockController.instance.expand,
                          child: SizedBox(
                            width: DockController.stripWidth - 8,
                            height: 40,
                            child: Icon(
                              dockRight ? Icons.chevron_left : Icons.chevron_right,
                              size: 28,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                _button(
                  ps.playing ? Icons.pause : Icons.play_arrow,
                  ps.playing ? 'Пауза' : 'Играть',
                  track == null ? null : ps.playOrPause,
                ),
                const SizedBox(height: 4),
                _button(
                  Icons.skip_next,
                  'Вперёд',
                  track != null && ps.index < ps.queue.length - 1 ? ps.next : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
