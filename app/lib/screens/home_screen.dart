import 'package:flutter/material.dart';

import '../demo_data.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'devices_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';

/// Главный экран: сетка плиток-кнопок. Без панорамы и свайпов.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<Playlist> playlists = demoPlaylists();

  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)).then((_) {
        if (mounted) setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final trackCount = playlists.fold<int>(0, (n, p) => n + p.tracks.length);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
              child: Text('HYDRA MUSIC',
                  style: TextStyle(fontSize: 14, letterSpacing: 2, color: Metro.green)),
            ),
            const SectionTitle('главная'),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    MetroTile(
                      label: 'Плейлисты',
                      subtitle: '${playlists.length} папок, $trackCount треков',
                      icon: Icons.queue_music,
                      onTap: () => _open(PlaylistsScreen(playlists: playlists)),
                    ),
                    MetroTile(
                      label: 'Устройства',
                      subtitle: 'синхронизация',
                      icon: Icons.devices,
                      color: Metro.greenDark,
                      onTap: () => _open(DevicesScreen(devices: demoDevices())),
                    ),
                    MetroTile(
                      label: 'Корзина',
                      subtitle: 'хранится 30 дней',
                      icon: Icons.delete_outline,
                      color: Metro.surface,
                      onTap: () => _open(const TrashScreen()),
                    ),
                    MetroTile(
                      label: 'Настройки',
                      icon: Icons.settings,
                      color: Metro.surface,
                      onTap: () => _open(const SettingsScreen()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
