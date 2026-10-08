import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:window_manager/window_manager.dart';

import '../core_bridge.dart';
import '../demo_data.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../screens/devices_screen.dart';
import '../screens/settings_screen.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import 'collapsed_strip.dart';
import 'context_menu.dart';
import 'desktop_settings.dart';
import 'dock_controller.dart';
import 'player_panel.dart';
import 'resize_handle.dart';

/// Главный экран Windows: «шторка» у края экрана. Развёрнутая или свёрнутая в полоску.
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DockController.instance.collapsed,
      builder: (context, collapsed, _) =>
          collapsed ? const CollapsedStrip() : const _ExpandedShell(),
    );
  }
}

enum _Mode { playlist, trash }

enum _TrackAction { play, rename, cover, move, delete }

enum _PlaylistAction { open, rename, delete }

enum _TrashAction { restore, purge }

class _ExpandedShell extends StatefulWidget {
  const _ExpandedShell();

  @override
  State<_ExpandedShell> createState() => _ExpandedShellState();
}

class _ExpandedShellState extends State<_ExpandedShell> with WidgetsBindingObserver {
  String? _playlistId;
  List<TrackInfo> _tracks = const [];
  List<TrashItem> _trash = const [];
  String? _selectedId;
  _Mode _mode = _Mode.playlist;
  bool _listOpen = false;

  /// Перестановки идут в ядро строго по очереди.
  Future<void> _queue = Future<void>.value();

  String? _lastTapId;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    hydraLibrary.addListener(_onLibrary);
    _syncSelection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    hydraLibrary.removeListener(_onLibrary);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) hydraLibrary.onResume();
  }

  // ---------- состояние ----------

  PlaylistInfo? get _current {
    for (final p in hydraLibrary.playlists) {
      if (p.id == _playlistId) return p;
    }
    return null;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Подбирает текущий плейлист и перечитывает список (без setState: годится для initState).
  void _syncSelection() {
    final pls = hydraLibrary.playlists;
    if (_playlistId == null || !pls.any((p) => p.id == _playlistId)) {
      _playlistId = pls.isEmpty ? null : pls.first.id;
      _tracks = const [];
    }
    if (_mode == _Mode.trash) {
      unawaited(_loadTrash());
    } else {
      unawaited(_loadTracks());
    }
  }

  void _onLibrary() {
    _syncSelection();
    if (mounted) setState(() {});
  }

  Future<void> _loadTracks() async {
    final id = _playlistId;
    if (id == null) {
      if (mounted) setState(() => _tracks = const []);
      return;
    }
    try {
      final tracks = await hydraLibrary.tracks(id);
      if (!mounted || id != _playlistId) return;
      setState(() {
        _tracks = tracks;
        if (_mode == _Mode.playlist && !tracks.any((t) => t.id == _selectedId)) _selectedId = null;
      });
    } on CoreException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _loadTrash() async {
    try {
      final items = await hydraLibrary.trashItems();
      if (!mounted) return;
      setState(() {
        _trash = items;
        if (_mode == _Mode.trash && !items.any((t) => t.id == _selectedId)) _selectedId = null;
      });
    } on CoreException catch (e) {
      _toast(e.message);
    }
  }

  /// Выполняет действие ядра, показывает ошибку и перечитывает списки.
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTracks();
    if (_mode == _Mode.trash) await _loadTrash();
  }

  void _selectPlaylist(String id) {
    setState(() {
      _playlistId = id;
      _listOpen = false;
      _mode = _Mode.playlist;
      _selectedId = null;
      _tracks = const [];
    });
    unawaited(_loadTracks());
  }

  void _toggleTrash() {
    setState(() {
      _listOpen = false;
      _selectedId = null;
      _mode = _mode == _Mode.trash ? _Mode.playlist : _Mode.trash;
    });
    if (_mode == _Mode.trash) {
      unawaited(_loadTrash());
    } else {
      unawaited(_loadTracks());
    }
  }

  // ---------- диалоги ----------

  Future<String?> _askText({
    required String title,
    String initial = '',
    required String hint,
    required String okLabel,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 24)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: Metro.inputDecoration(hint: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: Text(okLabel)),
        ],
      ),
    );
  }

  // ---------- плейлисты ----------

  Future<void> _newPlaylist() async {
    final name = await _askText(
        title: 'Новый плейлист', hint: 'Название папки', okLabel: 'Создать');
    if (name == null || name.isEmpty) return;
    await _act(() => hydraLibrary.createPlaylist(name));
  }

  Future<void> _renamePlaylist(PlaylistInfo p) async {
    final name = await _askText(
        title: 'Переименовать плейлист', initial: p.name, hint: 'Название папки', okLabel: 'Сохранить');
    if (name == null || name.isEmpty || name == p.name) return;
    await _act(() => hydraLibrary.renamePlaylist(p.id, name));
  }

  Future<void> _deletePlaylist(PlaylistInfo p) async {
    if (p.trackCount > 0) {
      _toast('Удалить можно только пустой плейлист: в «${p.name}» есть треки.');
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Удалить плейлист?',
      message: 'Пустая папка «${p.name}» будет удалена.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await _act(() => hydraLibrary.deletePlaylist(p.id));
  }

  void _onReorderPlaylist(int oldIndex, int newIndex) {
    final list = hydraLibrary.playlists;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = list[oldIndex];
    final target = newIndex;
    _queue = _queue.then((_) async {
      try {
        await hydraLibrary.reorderPlaylist(moved.id, target);
      } on CoreException catch (e) {
        _toast(e.message);
      }
    });
  }

  Future<void> _playlistMenu(Offset pos, PlaylistInfo p) async {
    final action = await showMetroMenu<_PlaylistAction>(context, pos, const [
      MetroMenuItem(value: _PlaylistAction.open, label: 'Открыть', icon: Icons.folder_open),
      MetroMenuItem(value: _PlaylistAction.rename, label: 'Переименовать', icon: Icons.edit_outlined),
      MetroMenuItem(
          value: _PlaylistAction.delete,
          label: 'Удалить плейлист',
          icon: Icons.delete_outline,
          danger: true),
    ]);
    switch (action) {
      case _PlaylistAction.open:
        _selectPlaylist(p.id);
      case _PlaylistAction.rename:
        await _renamePlaylist(p);
      case _PlaylistAction.delete:
        await _deletePlaylist(p);
      case null:
        break;
    }
  }

  // ---------- треки ----------

  Future<void> _play(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    await PlayerService.instance.playQueue(_tracks, index);
  }

  void _onTrackTap(TrackInfo t, int index) {
    final now = DateTime.now();
    final isDouble = _lastTapId == t.id && now.difference(_lastTapAt).inMilliseconds < 400;
    _lastTapId = t.id;
    _lastTapAt = now;
    if (isDouble) {
      _lastTapId = null;
      unawaited(_play(index));
    } else {
      setState(() => _selectedId = t.id);
    }
  }

  Future<void> _renameTrack(TrackInfo t) async {
    final title = await _askText(
        title: 'Название трека', initial: t.title, hint: 'Название', okLabel: 'Сохранить');
    if (title == null || title.isEmpty || title == t.title) return;
    try {
      final written = await hydraLibrary.renameTrack(t.id, title);
      _toast(written
          ? 'Название записано в файл.'
          : 'Этот формат не хранит теги: название сохранено только в приложении.');
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTracks();
  }

  Future<void> _changeCover(TrackInfo t) async {
    final XFile? picked;
    try {
      // системное окно выбора файла забирает фокус: на это время сворачивание отключено
      picked = await DockController.instance
          .guard(() => ImagePicker().pickImage(source: ImageSource.gallery));
    } catch (e) {
      _toast('Не удалось открыть выбор картинки: $e');
      return;
    }
    if (picked == null) return;
    try {
      await hydraLibrary.setCover(t.id, picked.path);
      _toast('Обложка записана в файл.');
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTracks();
  }

  Future<void> _moveTrack(TrackInfo t) async {
    final targets = hydraLibrary.playlists.where((p) => p.id != t.playlistId).toList();
    if (targets.isEmpty) {
      _toast('Нет другого плейлиста. Создайте его кнопкой в списке плейлистов.');
      return;
    }
    final target = await showDialog<PlaylistInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Переместить в…'),
        children: [
          for (final p in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(p.name, style: const TextStyle(fontSize: 18)),
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final from = _current?.name ?? '';
    final ok = await confirmAction(
      context,
      title: 'Переместить трек?',
      message: '«${t.title}» будет перенесён из «$from» в «${target.name}». '
          'Файл физически переместится между папками.',
      confirmLabel: 'Переместить',
    );
    if (!ok) return;
    await _act(() => hydraLibrary.moveTrack(t.id, target.id));
  }

  Future<void> _deleteTrack(TrackInfo t) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить трек?',
      message: '«${t.title}» уйдёт в корзину на 30 дней.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    await _act(() => hydraLibrary.deleteTrack(t.id));
  }

  Future<void> _trackMenu(Offset pos, TrackInfo t, int index) async {
    setState(() => _selectedId = t.id);
    final action = await showMetroMenu<_TrackAction>(context, pos, const [
      MetroMenuItem(value: _TrackAction.play, label: 'Играть', icon: Icons.play_arrow),
      MetroMenuItem(value: _TrackAction.rename, label: 'Название', icon: Icons.edit_outlined),
      MetroMenuItem(value: _TrackAction.cover, label: 'Обложка', icon: Icons.image_outlined),
      MetroMenuItem(
          value: _TrackAction.move, label: 'Переместить', icon: Icons.drive_file_move_outline),
      MetroMenuItem(
          value: _TrackAction.delete, label: 'Удалить', icon: Icons.delete_outline, danger: true),
    ]);
    switch (action) {
      case _TrackAction.play:
        await _play(index);
      case _TrackAction.rename:
        await _renameTrack(t);
      case _TrackAction.cover:
        await _changeCover(t);
      case _TrackAction.move:
        await _moveTrack(t);
      case _TrackAction.delete:
        await _deleteTrack(t);
      case null:
        break;
    }
  }

  void _onReorderTrack(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = _tracks[oldIndex];
    final target = newIndex;
    setState(() {
      final list = List<TrackInfo>.of(_tracks);
      list.removeAt(oldIndex);
      list.insert(target, moved);
      _tracks = list;
    });
    _queue = _queue.then((_) async {
      try {
        await hydraLibrary.reorder(moved.id, target);
      } on CoreException catch (e) {
        _toast(e.message);
        await _loadTracks();
      }
    });
  }

  // ---------- корзина ----------

  Future<void> _restore(TrashItem item) async {
    try {
      await hydraLibrary.restoreTrack(item.id);
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTrash();
  }

  Future<void> _purge(TrashItem item) async {
    final ok = await confirmAction(
      context,
      title: 'Удалить навсегда?',
      message: '«${item.title}» будет стёрт без возможности восстановления.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    try {
      await hydraLibrary.purgeTrack(item.id);
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTrash();
  }

  Future<void> _emptyTrash() async {
    final ok = await confirmAction(
      context,
      title: 'Очистить корзину?',
      message: 'Все треки в корзине (${_trash.length}) будут стёрты без возможности восстановления.',
      confirmLabel: 'Очистить',
      danger: true,
    );
    if (!ok) return;
    try {
      await hydraLibrary.emptyTrash();
    } on CoreException catch (e) {
      _toast(e.message);
    }
    await _loadTrash();
  }

  Future<void> _trashMenu(Offset pos, TrashItem item) async {
    setState(() => _selectedId = item.id);
    final action = await showMetroMenu<_TrashAction>(context, pos, const [
      MetroMenuItem(value: _TrashAction.restore, label: 'Восстановить', icon: Icons.restore),
      MetroMenuItem(
          value: _TrashAction.purge,
          label: 'Удалить навсегда',
          icon: Icons.delete_forever,
          danger: true),
    ]);
    switch (action) {
      case _TrashAction.restore:
        await _restore(item);
      case _TrashAction.purge:
        await _purge(item);
      case null:
        break;
    }
  }

  String _age(int deletedMs) {
    final days = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(deletedMs)).inDays;
    final left = (30 - days).clamp(0, 30);
    return days <= 0 ? 'сегодня, осталось $left дн.' : '$days дн. назад, осталось $left дн.';
  }

  // ---------- клавиатура ----------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      unawaited(PlayerService.instance.playOrPause());
      return KeyEventResult.handled;
    }
    if (_mode != _Mode.playlist || _listOpen || _tracks.isEmpty) return KeyEventResult.ignored;
    final idx = _tracks.indexWhere((t) => t.id == _selectedId);
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedId = _tracks[(idx + 1).clamp(0, _tracks.length - 1)].id);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedId = _tracks[(idx <= 0 ? 0 : idx - 1)].id);
      return KeyEventResult.handled;
    }
    if (idx < 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter) {
      unawaited(_play(idx));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete) {
      unawaited(_deleteTrack(_tracks[idx]));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      unawaited(_renameTrack(_tracks[idx]));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- виджеты ----------

  void _openRoute(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Widget _headerButton(IconData icon, String tooltip, VoidCallback onPressed, {bool active = false}) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 20,
      color: active ? Metro.green : Colors.white,
      icon: Icon(icon),
    );
  }

  Widget _header() {
    // перетаскивание за шапку; двойной щелчок намеренно ничего не делает
    // (стандартная область DragToMoveArea разворачивала бы окно на весь экран)
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 44,
        color: Metro.bg,
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            const Text('HYDRA MUSIC',
                style: TextStyle(fontSize: 13, letterSpacing: 2, color: Metro.green)),
            const Spacer(),
            _headerButton(Icons.devices, 'Устройства', () => _openRoute(DevicesScreen(devices: demoDevices()))),
            _headerButton(Icons.delete_outline, 'Корзина', _toggleTrash, active: _mode == _Mode.trash),
            _headerButton(Icons.settings, 'Настройки', () => _openRoute(const SettingsScreen())),
            _headerButton(Icons.close, 'Закрыть', DockController.instance.close),
          ],
        ),
      ),
    );
  }

  Widget _playlistBar() {
    if (_mode == _Mode.trash) {
      return Material(
        color: Metro.surface,
        child: InkWell(
          onTap: _toggleTrash,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.arrow_back, size: 22),
                const SizedBox(width: 12),
                const Expanded(
                    child: Text('Корзина', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                Text('${_trash.length}', style: const TextStyle(color: Metro.textDim)),
              ],
            ),
          ),
        ),
      );
    }
    final p = _current;
    return Material(
      color: Metro.green,
      child: InkWell(
        onTap: () => setState(() => _listOpen = !_listOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.folder_open, size: 24, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(p?.name ?? 'Нет плейлистов',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, color: Colors.white)),
              ),
              if (p != null)
                Text('${p.trackCount}', style: const TextStyle(color: Colors.white70)),
              const SizedBox(width: 8),
              Icon(_listOpen ? Icons.expand_less : Icons.expand_more, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playlistPicker() {
    final pls = hydraLibrary.playlists;
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: pls.length,
            onReorder: _onReorderPlaylist,
            proxyDecorator: (child, index, animation) => Material(color: Metro.surface, child: child),
            itemBuilder: (context, i) {
              final p = pls[i];
              final selected = p.id == _playlistId;
              return Padding(
                key: ValueKey<String>(p.id),
                padding: const EdgeInsets.only(bottom: 4),
                child: _Hoverable(
                  builder: (hover) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _selectPlaylist(p.id),
                    onSecondaryTapUp: (d) => _playlistMenu(d.globalPosition, p),
                    child: Container(
                      height: 48,
                      color: selected ? Metro.greenDark : (hover ? const Color(0xFF2A2A2A) : Metro.surface),
                      padding: const EdgeInsets.only(left: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_open, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(p.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                          ),
                          Text('${p.trackCount}', style: const TextStyle(color: Metro.textDim)),
                          ReorderableDragStartListener(
                            index: i,
                            child: const SizedBox(
                              width: 40,
                              height: 48,
                              child: Icon(Icons.drag_indicator, size: 20, color: Metro.textDim),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _newPlaylist,
              icon: const Icon(Icons.add),
              label: const Text('Новый плейлист'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _trackList() {
    final p = _current;
    if (p == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Плейлистов пока нет.\nСоздайте плейлист в списке выше или положите папку с музыкой в Музыка\\Hydra.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Папка пуста. Положите файлы в Музыка\\Hydra\\${p.name}.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (p.trackCount == 0)
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить плейлист'),
                  onPressed: () => _deletePlaylist(p),
                ),
            ],
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: PlayerService.instance,
      builder: (context, _) {
        final playingId = PlayerService.instance.current?.id;
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          itemCount: _tracks.length,
          onReorder: _onReorderTrack,
          proxyDecorator: (child, index, animation) => Material(color: Metro.surface, child: child),
          itemBuilder: (context, i) {
            final t = _tracks[i];
            final selected = t.id == _selectedId;
            final playing = t.id == playingId;
            return Padding(
              key: ValueKey<String>(t.id),
              padding: const EdgeInsets.only(bottom: 2),
              child: _Hoverable(
                builder: (hover) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onTrackTap(t, i),
                  onSecondaryTapUp: (d) => _trackMenu(d.globalPosition, t, i),
                  child: Container(
                    height: 52,
                    color: selected
                        ? Metro.surface
                        : (hover ? const Color(0xFF141414) : Colors.transparent),
                    padding: const EdgeInsets.only(left: 4),
                    child: Row(
                      children: [
                        Container(width: 4, height: 52, color: playing ? Metro.green : Colors.transparent),
                        SizedBox(
                          width: 32,
                          child: Center(
                            child: playing
                                ? const Icon(Icons.graphic_eq, size: 18, color: Metro.green)
                                : Text('${i + 1}',
                                    style: const TextStyle(fontSize: 13, color: Metro.textDim)),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 16, color: playing ? Metro.green : Colors.white)),
                              Text(t.artist ?? t.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: Metro.textDim)),
                            ],
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: SizedBox(
                            width: 36,
                            height: 52,
                            child: Icon(Icons.drag_indicator,
                                size: 20, color: hover || selected ? Metro.textDim : Colors.transparent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _trashList() {
    return Column(
      children: [
        Expanded(
          child: _trash.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Корзина пуста.\nУдалённые треки хранятся здесь 30 дней.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  itemCount: _trash.length,
                  itemBuilder: (context, i) {
                    final item = _trash[i];
                    final selected = item.id == _selectedId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: _Hoverable(
                        builder: (hover) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _selectedId = item.id),
                          onSecondaryTapUp: (d) => _trashMenu(d.globalPosition, item),
                          child: Container(
                            height: 52,
                            color: selected
                                ? Metro.surface
                                : (hover ? const Color(0xFF141414) : Colors.transparent),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16)),
                                Text(_age(item.deletedMs),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12, color: Metro.textDim)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Очистить корзину'),
              onPressed: _trash.isEmpty ? null : _emptyTrash,
            ),
          ),
        ),
      ],
    );
  }

  Widget _status() {
    final lib = hydraLibrary;
    final String text;
    Color color = Metro.textDim;
    if (lib.status == LibraryStatus.error) {
      text = 'Ошибка: ${lib.error ?? 'неизвестная'}';
      color = Metro.danger;
    } else if (lib.notice != null) {
      text = lib.notice!;
      color = Metro.danger;
    } else if (lib.scanning || lib.status == LibraryStatus.loading) {
      text = 'Сканирую библиотеку…';
    } else {
      final tracks = lib.playlists.fold<int>(0, (n, p) => n + p.trackCount);
      text = '${lib.playlists.length} плейлистов · $tracks треков · правый клик - действия';
    }
    return Container(
      height: 26,
      color: Metro.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([hydraLibrary, DesktopSettings.instance]),
      builder: (context, _) {
        final Widget body;
        if (_mode == _Mode.trash) {
          body = _trashList();
        } else if (_listOpen) {
          body = _playlistPicker();
        } else {
          body = _trackList();
        }
        final dockRight = DesktopSettings.instance.dockRight;
        return Scaffold(
          body: Stack(
            children: [
              Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: Column(
                  children: [
                    _header(),
                    PlayerPanel(dockRight: dockRight),
                    if (hydraLibrary.scanning) const MetroProgress(),
                    _playlistBar(),
                    Expanded(child: body),
                    _status(),
                  ],
                ),
              ),
              // край для изменения ширины: у стороны, противоположной краю экрана
              Positioned(
                top: 0,
                bottom: 0,
                left: dockRight ? 0 : null,
                right: dockRight ? null : 0,
                child: const ResizeHandle(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Подсветка строки под курсором.
class _Hoverable extends StatefulWidget {
  const _Hoverable({required this.builder});

  final Widget Function(bool hover) builder;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.builder(_hover),
    );
  }
}
