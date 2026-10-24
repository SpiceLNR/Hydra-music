import 'package:flutter/material.dart';

import '../library_controller.dart';
import '../models.dart';
import '../theme.dart';
import 'metro_widgets.dart';

/// Вопрос о массовом удалении вне приложения: папка плейлиста или большая часть его
/// файлов пропала (например, удалили в проводнике). Ничего не удаляется и не уходит на
/// другие устройства, пока вы не ответите.
class HeldBanner extends StatelessWidget {
  const HeldBanner({super.key});

  String _text(HeldDeletion h) => h.folderMissing
      ? 'Папка плейлиста «${h.name}» пропала (треков: ${h.count}).'
      : 'В плейлисте «${h.name}» пропали файлы (треков: ${h.count}).';

  Future<void> _delete(BuildContext context, HeldDeletion h) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить на всех устройствах?',
      message: 'Треки уйдут в корзину на 30 дней и на остальных устройствах тоже.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (ok) await hydraLibrary.resolveHeld(h.playlistId, delete: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hydraLibrary,
      builder: (context, _) {
        if (hydraLibrary.held.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final h in hydraLibrary.held)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Metro.surface,
                  border: Border.all(color: Metro.danger, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_text(h), style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text(
                      'Пока вы не ответите, ничего не удаляется и не уходит на другие устройства.',
                      style: TextStyle(fontSize: 13, color: Metro.textDim),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: () => hydraLibrary.resolveHeld(h.playlistId, delete: false),
                      child: const Text('Вернуть с других устройств'),
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton(
                      onPressed: () => _delete(context, h),
                      child: const Text('Удалить везде'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
