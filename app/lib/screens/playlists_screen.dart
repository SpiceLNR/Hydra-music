import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../theme.dart';
import 'playlist_screen.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый плейлист'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Название папки'),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Создать')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await hydraLibrary.createPlaylist(name);
    } on CoreException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('плейлисты'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: hydraLibrary.refresh,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: hydraLibrary,
        builder: (context, _) {
          final playlists = hydraLibrary.playlists;
          return Column(
            children: [
              if (hydraLibrary.scanning)
                const LinearProgressIndicator(color: Metro.green, backgroundColor: Metro.surface),
              Expanded(
                child: playlists.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Плейлистов пока нет.\nСоздайте плейлист кнопкой ниже или положите '
                            'папку с музыкой в Music/Hydra.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(8),
                        itemCount: playlists.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final p = playlists[i];
                          return Material(
                            color: Metro.green,
                            child: InkWell(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => PlaylistScreen(playlist: p))),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    const Icon(Icons.folder_open, size: 36, color: Colors.white),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(p.name,
                                              style: const TextStyle(
                                                  fontSize: 22, fontWeight: FontWeight.w300)),
                                          Text('${p.trackCount} треков',
                                              style: const TextStyle(color: Colors.white70)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: () => _create(context),
            icon: const Icon(Icons.add),
            label: const Text('Новый плейлист'),
          ),
        ),
      ),
    );
  }
}
