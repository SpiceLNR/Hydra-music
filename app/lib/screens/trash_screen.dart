import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import '../l10n/l10n.dart';

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
    final remote = _items.any((i) => i.id == id && !i.hasFile);
    try {
      await hydraLibrary.restoreTrack(id);
      if (remote && mounted) {
        _toast(tr('Трек вернулся в плейлист: файл придёт с другого устройства при синхронизации'));
      }
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  Future<void> _purge(TrashItem item) async {
    final ok = await confirmAction(
      context,
      title: tr('Удалить навсегда?'),
      message: tr('«{title}» будет стёрт без возможности восстановления.', {'title': item.title}),
      confirmLabel: tr('Удалить'),
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

  Future<void> _emptyAll() async {
    final ok = await confirmAction(
      context,
      title: tr('Очистить корзину?'),
      message: tr('Все треки в корзине ({length}) будут стёрты без возможности восстановления.', {'length': _items.length}),
      confirmLabel: tr('Очистить'),
      danger: true,
    );
    if (!ok) return;
    try {
      await hydraLibrary.emptyTrash();
    } on CoreException catch (e) {
      if (mounted) _toast(e.message);
    }
    await _load();
  }

  String _age(int deletedMs) {
    final days = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(deletedMs)).inDays;
    final left = (30 - days).clamp(0, 30);
    final when = days <= 0 ? tr('удалён сегодня') : tr('удалён {days} дн. назад', {'days': days});
    return tr('{when}, осталось {left} дн.', {'when': when, 'left': left});
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(title: Text(tr('корзина'))),
      body: _loading
          ? const Center(child: SizedBox(width: 200, child: MetroProgress()))
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      tr('Корзина пуста.\nУдалённые треки хранятся здесь 30 дней, затем стираются окончательно.'),
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
                        subtitle: Text(
                          '${item.fileName} · ${_age(item.deletedMs)}'
                              '${item.hasFile ? '' : tr(' · файл на другом устройстве')}',
                        ),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.restore),
                      label: Text(tr('Восстановить')),
                      onPressed: selected == null ? null : () => _restore(selected.id),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.delete_forever),
                      label: Text(tr('Навсегда')),
                      onPressed: selected == null ? null : () => _purge(selected),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(tr('Очистить корзину')),
                  onPressed: _items.isEmpty ? null : _emptyAll,
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
