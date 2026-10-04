import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'playlist_screen.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key, required this.playlists});
  final List<Playlist> playlists;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  Future<void> _create() async {
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
    // TODO(core): имя пройдёт через naming::unique_name и создаст папку Music/Hydra/<имя>
    setState(() => widget.playlists.add(Playlist(id: name.toLowerCase(), name: name)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('плейлисты')),
      body: widget.playlists.isEmpty
          ? const Center(child: Text('Плейлистов пока нет'))
          : ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: widget.playlists.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final p = widget.playlists[i];
                return Material(
                  color: Metro.green,
                  child: InkWell(
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              PlaylistScreen(playlist: p, allPlaylists: widget.playlists)));
                      if (mounted) setState(() {});
                    },
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
                                Text('${p.tracks.length} треков',
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('Новый плейлист'),
          ),
        ),
      ),
    );
  }
}
