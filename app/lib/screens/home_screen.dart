import 'package:flutter/material.dart';

import '../library_controller.dart';
import '../theme.dart';
import '../widgets/held_banner.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/update_banner.dart';
import 'devices_screen.dart';
import 'playlists_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import '../l10n/l10n.dart';

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
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  String _playlistsSubtitle(LibraryController lib) {
    if (lib.status != LibraryStatus.ready) return tr('библиотека');
    final tracks = lib.playlists.fold<int>(0, (n, p) => n + p.trackCount);
    return '${plural(lib.playlists.length, 'папка', 'папки', 'папок')}, ${plural(tracks, 'трек', 'трека', 'треков')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: hydraLibrary,
          builder: (context, _) {
            // без доступа к папке или пока библиотека не открыта эти разделы недоступны
            final ready = hydraLibrary.status == LibraryStatus.ready;
            return ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
                  child: const Text('HYDRA MUSIC',
                      style: const TextStyle(fontSize: 14, letterSpacing: 2, color: Metro.green)),
                ),
                SectionTitle(tr('главная')),
                _StatusBanner(lib: hydraLibrary),
                const HeldBanner(),
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
                        label: tr('Плейлисты'),
                        subtitle: _playlistsSubtitle(hydraLibrary),
                        icon: Icons.queue_music,
                        onTap: ready ? () => _open(const PlaylistsScreen()) : null,
                      ),
                      MetroTile(
                        label: tr('Устройства'),
                        subtitle: tr('синхронизация'),
                        icon: Icons.devices,
                        color: Metro.greenDark,
                        onTap: ready ? () => _open(const DevicesScreen()) : null,
                      ),
                      MetroTile(
                        label: tr('Корзина'),
                        subtitle: tr('хранится 30 дней'),
                        icon: Icons.delete_outline,
                        color: Metro.surface,
                        onTap: ready ? () => _open(const TrashScreen()) : null,
                      ),
                      MetroTile(
                        label: tr('Настройки'),
                        icon: Icons.settings,
                        color: Metro.surface,
                        onTap: () => _open(const SettingsScreen()),
                      ),
                    ],
                  ),
                ),
                // плашка обновления сразу под плитками
                const UpdateBanner(),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: const NowPlayingBar(safeBottom: true),
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
      children.addAll([
        MetroProgress(),
        SizedBox(height: 8),
        Text(tr('Сканирую библиотеку…')),
      ]);
    } else if (lib.status == LibraryStatus.needPermission) {
      children.addAll([
        Text(tr('Нужен доступ ко всем файлам, чтобы работать с папкой Music/Hydra.')),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: lib.requestPermission,
          child: Text(tr('Разрешить доступ')),
        ),
      ]);
    } else if (lib.status == LibraryStatus.error) {
      children.addAll([
        Text(tr('Ошибка: {a1}', {'a1': lib.error ?? tr('неизвестная')}), style: const TextStyle(color: Metro.danger)),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: lib.init, child: Text(tr('Повторить'))),
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
