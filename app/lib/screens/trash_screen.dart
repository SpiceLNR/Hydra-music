import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';

/// Корзина: удалённые в приложении треки хранятся 30 дней, потом стираются сами.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashItem> _items = const [];
  bool _loading = true;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  TrashItem? get _selected {
    for (final i in _items) {
      if (i.id == _selectedId) return i;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final items = await hydraLibrary.trashItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        if (!_items.any((i) => i.id == _selectedId)) _selectedId = null;
      });
    } on CoreException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.message);
    }
  }

  Future<void> _restore(String id) async {
    try {
      await hydraLibrary.restoreTrack(id);
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
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
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  String _age(int deletedMs) {
    final days = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(deletedMs)).inDays;
    if (days <= 0) return 'удалён сегодня';
    return 'удалён $days дн. назад';
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(title: const Text('корзина')),
      body: _loading
          ? const Center(child: SizedBox(width: 200, child: MetroProgress()))
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Корзина пуста.\nУдалённые треки хранятся здесь 30 дней, '
                      'затем стираются окончательно.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    final isSel = item.id == _selectedId;
                    return Container(
                      color: isSel ? Metro.surface : null,
                      child: ListTile(
                        leading: const Cover(isVideo: false),
                        title: Text(item.title, style: const TextStyle(fontSize: 18)),
                        subtitle: Text('${item.fileName} · ${_age(item.deletedMs)}'),
                        onTap: () => setState(() => _selectedId = isSel ? null : item.id),
                      ),
                    );
                  },
                ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NowPlayingBar(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.restore),
                      label: const Text('Восстановить'),
                      onPressed: selected == null ? null : () => _restore(selected.id),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.delete_forever),
                      label: const Text('Навсегда'),
                      onPressed: selected == null ? null : () => _purge(selected),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
