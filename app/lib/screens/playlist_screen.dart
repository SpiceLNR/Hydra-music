import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/marquee_text.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'player_screen.dart';

/// Список треков плейлиста.
///
/// Обычный режим: нажатие выбирает трек, внизу кнопки «Играть», «Название», «Обложка»,
/// «Переместить», «Удалить» (удаление и перемещение с подтверждением).
/// Пустой плейлист можно удалить кнопкой по центру экрана.
/// Режим редактирования: включается долгим нажатием на любой трек; порядок меняется
/// перетаскиванием за зелёную область справа. Кнопка «Готово» (или «назад») выходит из режима.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlist});
  final PlaylistInfo playlist;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<TrackInfo> _tracks = const [];
  bool _loading = true;
  bool _editing = false;
  String? _selectedId;

  /// Правило порядка треков этого плейлиста: manual (как попало), artist, title.
  late String _sortMode = widget.playlist.sortMode;

  /// Перестановки идут в ядро строго по очереди, чтобы порядок операций не перепутался.
  Future<void> _reorderQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _load();
  }

  TrackInfo? get _selected {
    for (final t in _tracks) {
      if (t.id == _selectedId) return t;
    }
    return null;
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _load() async {
    try {
      final tracks = await hydraLibrary.tracks(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
        if (_selected == null) _selectedId = null;
      });
    } on CoreException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.message);
    }
  }

  /// Выполняет действие ядра, показывает ошибку и перечитывает список.
  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _refresh() async {
    await hydraLibrary.refresh();
    await _load();
  }

  /// Высота строки трека одинакова в обычном режиме и в режиме перестановки:
  /// иначе при переключении список «уезжает» (ошибка набегает с каждой строкой).
  static const double _rowExtent = 74;

  ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Список при смене режима пересоздаётся: переносим положение прокрутки,
  /// чтобы остаться на том же месте, а не прыгнуть в начало.
  void _carryScroll() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final old = _scroll;
    _scroll = ScrollController(initialScrollOffset: offset);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _startEditing() {
    HapticFeedback.mediumImpact();
    _carryScroll();
    setState(() {
      _editing = true;
      _selectedId = null;
    });
  }

  void _stopEditing() {
    _carryScroll();
    setState(() => _editing = false);
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex == oldIndex) return;
    final moved = _tracks[oldIndex];
    final target = newIndex;
    if (_sortMode != 'manual') {
      // ручная перестановка отключает правило, иначе оно сразу вернуло бы всё назад
      _sortMode = 'manual';
      _reorderQueue = _reorderQueue.then((_) async {
        try {
          await hydraLibrary.setPlaylistSort(widget.playlist.id, 'manual');
        } on CoreException catch (e) {
          if (mounted) _toast(e.message);
        }
      });
    }
    setState(() {
      final list = List<TrackInfo>.of(_tracks);
      list.removeAt(oldIndex);
      list.insert(target, moved);
      _tracks = list;
    });
    _reorderQueue = _reorderQueue.then((_) async {
      try {
        await hydraLibrary.reorder(moved.id, target);
      } on CoreException catch (e) {
        if (mounted) _toast(e.message);
        await _load();
      }
    });
  }

  static const List<(String, String)> _sortOptions = [
    ('artist', 'По исполнителю'),
    ('title', 'По названию трека'),
    ('manual', 'Как попало'),
  ];

  String get _sortLabel =>
      _sortOptions.firstWhere((o) => o.$1 == _sortMode, orElse: () => _sortOptions.last).$2;

  /// Меняет правило порядка. Для «по исполнителю» и «по названию» треки сразу
  /// пересортировываются, и новые песни потом встают на своё место сами.
  Future<void> _setSort(String mode) async {
    if (mode == _sortMode) return;
    try {
      await hydraLibrary.setPlaylistSort(widget.playlist.id, mode);
      if (mounted) setState(() => _sortMode = mode);
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _delete(TrackInfo t) async {
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

  Future<void> _rename(TrackInfo t) async {
    final controller = TextEditingController(text: t.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название трека'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: Metro.inputDecoration(hint: 'Название'),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == t.title) return;
    try {
      final written = await hydraLibrary.renameTrack(t.id, title);
      if (mounted) {
        _toast(written
            ? 'Название записано в файл.'
            : 'Этот формат не хранит теги: название сохранено только в приложении.');
      }
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _changeCover(TrackInfo t) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (mounted) _toast('Не удалось открыть выбор картинки: $e');
      return;
    }
    if (picked == null) return;
    try {
      await hydraLibrary.setCover(t.id, picked.path);
      if (mounted) _toast('Обложка записана в файл.');
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _deletePlaylist() async {
    final ok = await confirmAction(
      context,
      title: 'Удалить плейлист?',
      message: 'Пустая папка «${widget.playlist.name}» будет удалена.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (!ok) return;
    try {
      await hydraLibrary.deletePlaylist(widget.playlist.id);
      if (mounted) Navigator.of(context).pop();
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Future<void> _move(TrackInfo t) async {
    final targets = hydraLibrary.playlists.where((p) => p.id != widget.playlist.id).toList();
    if (targets.isEmpty) {
      _toast('Нет другого плейлиста. Создайте его на экране «Плейлисты».');
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
    final ok = await confirmAction(
      context,
      title: 'Переместить трек?',
      message: '«${t.title}» будет перенесён из «${widget.playlist.name}» в «${target.name}». '
          'Файл физически переместится между папками.',
      confirmLabel: 'Переместить',
    );
    if (!ok) return;
    await _act(() => hydraLibrary.moveTrack(t.id, target.id));
  }

  Future<void> _play(TrackInfo t) async {
    await PlayerService.instance.playQueue(_tracks, _tracks.indexOf(t));
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen()));
  }

  Widget _normalList() {
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowExtent,
      itemCount: _tracks.length,
      itemBuilder: (context, i) {
        final t = _tracks[i];
        final isSel = t.id == _selectedId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Container(
          color: isSel ? Metro.surface : null,
          child: ListTile(
            leading: Cover(isVideo: t.isVideo),
            // у выбранного трека название и исполнитель едут бегущей строкой;
            // высота строки у всех одинаковая
            title: MarqueeText('${i + 1}. ${t.title}',
                style: const TextStyle(fontSize: 18), active: isSel),
            subtitle: MarqueeText(t.artist ?? t.fileName, active: isSel),
            onTap: () => setState(() => _selectedId = isSel ? null : t.id),
            onLongPress: _startEditing,
          ),
          ),
        );
      },
    );
  }

  Widget _editList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: PopupMenuButton<String>(
            tooltip: 'Порядок треков',
            onSelected: _setSort,
            itemBuilder: (context) => [
              for (final o in _sortOptions)
                CheckedPopupMenuItem<String>(
                  value: o.$1,
                  checked: o.$1 == _sortMode,
                  child: Text(o.$2),
                ),
            ],
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(border: Border.all(color: Metro.green, width: 2)),
              child: Row(
                children: [
                  const Icon(Icons.sort, color: Metro.green),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Порядок: $_sortLabel', style: const TextStyle(fontSize: 16))),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ReorderableListView.builder(
            scrollController: _scroll,
            itemExtent: _rowExtent,
            buildDefaultDragHandles: false,
            itemCount: _tracks.length,
            onReorder: _onReorder,
            proxyDecorator: (child, index, animation) =>
                Material(color: Metro.surface, child: child),
            itemBuilder: (context, i) {
              final t = _tracks[i];
              return Padding(
                key: ValueKey<String>(t.id),
                padding: const EdgeInsets.only(bottom: 2),
                child: Container(
                color: Metro.surface,
                child: ListTile(
                  leading: Cover(isVideo: t.isVideo),
                  title: MarqueeText('${i + 1}. ${t.title}', style: const TextStyle(fontSize: 18)),
                  subtitle: MarqueeText(t.artist ?? t.fileName),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: Container(
                      width: 56,
                      height: 56,
                      color: Metro.green,
                      child: const Icon(Icons.drag_handle, color: Colors.white, size: 32),
                    ),
                  ),
                ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _bottom(TrackInfo? selected) {
    if (_editing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NowPlayingBar(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Готово'),
                  onPressed: _stopEditing,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (selected == null) return const NowPlayingBar(safeBottom: true);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const NowPlayingBar(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: MetroAction(
                    icon: Icons.play_arrow,
                    label: 'Играть',
                    filled: true,
                    onPressed: () => _play(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.edit_outlined,
                    label: 'Название',
                    onPressed: () => _rename(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.image_outlined,
                    label: 'Обложка',
                    onPressed: () => _changeCover(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.drive_file_move_outline,
                    label: 'Переместить',
                    onPressed: () => _move(selected),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: MetroAction(
                    icon: Icons.delete_outline,
                    label: 'Удалить',
                    onPressed: () => _delete(selected),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _stopEditing();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? 'редактирование' : widget.playlist.name.toLowerCase()),
          actions: [
            if (!_editing)
              IconButton(
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
              ),
          ],
        ),
        body: _loading
            ? const Center(child: SizedBox(width: 200, child: MetroProgress()))
            : _tracks.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Папка пуста. Положите файлы в Music/Hydra/${widget.playlist.name} '
                            'и нажмите «Обновить».',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить плейлист'),
                            onPressed: _deletePlaylist,
                          ),
                        ],
                      ),
                    ),
                  )
                : (_editing ? _editList() : _normalList()),
        bottomNavigationBar: _bottom(_selected),
      ),
    );
  }
}
