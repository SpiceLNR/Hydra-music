import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../net_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'journal_screen.dart';
import 'pair_screens.dart';
import '../l10n/l10n.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    hydraNet.watch();
  }

  @override
  void dispose() {
    hydraNet.unwatch();
    super.dispose();
  }

  Future<void> _revoke(DeviceInfo d) async {
    final ok = await confirmAction(
      context,
      title: tr('Удалить устройство?'),
      message: tr('«{name}» исчезнет из списка, и устройства перестанут синхронизироваться. Музыка на обоих устройствах останется на месте. Это устройство тоже уберёт вас из своего списка: сразу, если оно в сети, иначе когда появится (до 14 дней).', {'name': d.name}),
      confirmLabel: tr('Удалить'),
      danger: true,
    );
    if (ok) await hydraNet.forget(d);
  }

  Future<void> _rename(DeviceInfo d) async {
    final controller = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Название устройства')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(hintText: tr('Например, «Ноутбук»')),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            if (d.originalName.isNotEmpty)
              Text(
                tr('Само устройство называет себя «{originalName}». Новое имя видно только здесь; пустое поле вернёт исходное.', {'originalName': d.originalName}),
                style: const TextStyle(fontSize: 13, color: Metro.textDim),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(tr('Сохранить')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await hydraNet.rename(d, name);
  }

  Future<void> _add() async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Добавить устройство')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'show'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(tr('Показать QR-код на этом устройстве')),
            ),
          ),
          if (isMobile)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'scan'),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(tr('Сканировать QR-код другого устройства')),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'paste'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(tr('Ввести ссылку сопряжения')),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'show':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairOfferScreen()));
      case 'scan':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScanScreen()));
      case 'paste':
        await showPasteDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
          tooltip: tr('Журнал'),
          icon: const Icon(Icons.receipt_long),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const JournalScreen()),
          ),
          ),
        ],
        title: Text(tr('устройства')),
      ),
      body: ListenableBuilder(
        listenable: hydraNet,
        builder: (context, _) {
          final devices = hydraNet.devices;
          return ListView(
            padding: const EdgeInsets.all(8),
            children: [
              _StatusCard(net: hydraNet),
              const SizedBox(height: 8),
              if (devices.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    tr('Пока нет ни одного устройства. Оба устройства должны быть в одной Wi-Fi сети. Нажмите «Добавить устройство»: на одном покажите QR-код, на другом отсканируйте его.'),
                  ),
                ),
              for (final d in devices) ...[
                _DeviceCard(
                  device: d,
                  busy: hydraNet.busy,
                  onSync: () => hydraNet.sync(d),
                  onRevoke: () => _revoke(d),
                  onRename: () => _rename(d),
                ),
                const SizedBox(height: 8),
              ],
            ],
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
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.qr_code),
                  label: Text(tr('Добавить устройство')),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.net});
  final NetService net;

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[];
    if (!net.started) {
      lines.add(Text(tr('Сеть запускается...')));
    } else if (net.busy) {
      lines.add(Text(net.message.isEmpty ? tr('Идёт синхронизация...') : net.message));
      lines.add(const SizedBox(height: 8));
      lines.add(const LinearProgressIndicator(color: Metro.green));
    } else if (net.message.isNotEmpty) {
      lines.add(Text(net.message));
    }
    if (net.error.isNotEmpty) {
      lines.add(const SizedBox(height: 8));
      lines.add(Text(net.error, style: const TextStyle(color: Metro.danger)));
    }
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      color: Metro.surface,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.busy,
    required this.onSync,
    required this.onRevoke,
    required this.onRename,
  });

  final DeviceInfo device;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onRevoke;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final d = device;
    return Container(
      color: Metro.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 12, height: 12, color: d.online ? Metro.green : Colors.grey),
              const SizedBox(width: 12),
              Expanded(child: Text(d.name, style: const TextStyle(fontSize: 20))),
              IconButton(
                tooltip: tr('Переименовать'),
                icon: const Icon(Icons.edit, size: 20),
                onPressed: onRename,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr('{a1} · синхронизация: {lastSyncLabel}', {'a1': d.online ? tr('в сети') : tr('не в сети'), 'lastSyncLabel': d.lastSyncLabel}),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: busy ? null : onSync,
                  child: Text(tr('Синхронизировать')),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onRevoke, child: Text(tr('Удалить'))),
            ],
          ),
        ],
      ),
    );
  }
}
