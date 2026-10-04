import 'package:flutter/material.dart';

import '../demo_data.dart';
import '../library_controller.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'devices_screen.dart';
import 'player_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';

/// Главный экран: сетка плиток-кнопок. Без панорамы и свайпов.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) hydraLibrary.onResume();
  }

  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  String _playlistsSubtitle(LibraryController lib) {
    if (lib.status != LibraryStatus.ready) return 'библиотека';
    final tracks = lib.playlists.fold<int>(0, (n, p) => n + p.trackCount);
    return '${lib.playlists.length} папок, $tracks треков';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: hydraLibrary,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 24, 16, 4),
                  child: Text('HYDRA MUSIC',
                      style: TextStyle(fontSize: 14, letterSpacing: 2, color: Metro.green)),
                ),
                const SectionTitle('главная'),
                _StatusBanner(lib: hydraLibrary),
                ValueListenableBuilder<bool>(
                  valueListenable: PlayerService.hasTrack,
                  builder: (context, has, _) {
                    if (!has) return const SizedBox.shrink();
                    return ListenableBuilder(
                      listenable: PlayerService.instance,
                      builder: (context, _) {
                        final t = PlayerService.instance.current;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          child: Material(
                            color: Metro.greenDark,
                            child: InkWell(
                              onTap: () => _open(const PlayerScreen()),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    Icon(PlayerService.instance.playing
                                        ? Icons.graphic_eq
                                        : Icons.pause),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        t == null ? 'Сейчас играет' : 'Сейчас играет: ${t.title}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      MetroTile(
                        label: 'Плейлисты',
                        subtitle: _playlistsSubtitle(hydraLibrary),
                        icon: Icons.queue_music,
                        onTap: () => _open(const PlaylistsScreen()),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Состояние библиотеки: сканирование, нужен доступ, ошибка.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.lib});
  final LibraryController lib;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (lib.status == LibraryStatus.loading || lib.scanning) {
      children.addAll(const [
        LinearProgressIndicator(color: Metro.green, backgroundColor: Metro.surface),
        SizedBox(height: 8),
        Text('Сканирую библиотеку…'),
      ]);
    } else if (lib.status == LibraryStatus.needPermission) {
      children.addAll([
        const Text('Нужен доступ ко всем файлам, чтобы работать с папкой Music/Hydra.'),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: lib.requestPermission,
          child: const Text('Разрешить доступ'),
        ),
      ]);
    } else if (lib.status == LibraryStatus.error) {
      children.addAll([
        Text('Ошибка: ${lib.error ?? 'неизвестная'}', style: const TextStyle(color: Metro.danger)),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: lib.init, child: const Text('Повторить')),
      ]);
    }
    if (lib.notice != null) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(Text(lib.notice!, style: const TextStyle(color: Metro.danger)));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
