import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../net_service.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';
import 'pair_screens.dart';

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
      title: 'Удалить устройство?',
      message: '«${d.name}» исчезнет из списка, и это устройство перестанет с ним синхронизироваться. '
          'Музыка на обоих устройствах останется на месте. '
          'Чтобы оно не могло подключиться и с другой стороны, удалите этот телефон/ПК и в его списке.',
      confirmLabel: 'Удалить',
      danger: true,
    );
    if (ok) await hydraNet.forget(d);
  }

  Future<void> _add() async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Добавить устройство'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'show'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Показать QR-код на этом устройстве'),
            ),
          ),
          if (isMobile)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'scan'),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Сканировать QR-код другого устройства'),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'paste'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Ввести ссылку сопряжения'),
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
      appBar: AppBar(title: const Text('устройства')),
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
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Пока нет ни одного устройства. Оба устройства должны быть в одной Wi-Fi сети. '
                    'Нажмите «Добавить устройство»: на одном покажите QR-код, на другом отсканируйте его.',
                  ),
                ),
              for (final d in devices) ...[
                _DeviceCard(
                  device: d,
                  busy: hydraNet.busy,
                  onSync: () => hydraNet.sync(d),
                  onRevoke: () => _revoke(d),
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
                  label: const Text('Добавить устройство'),
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
      lines.add(const Text('Сеть запускается...'));
    } else if (net.busy) {
      lines.add(Text(net.message.isEmpty ? 'Идёт синхронизация...' : net.message));
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
  });

  final DeviceInfo device;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onRevoke;

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
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${d.online ? 'в сети' : 'не в сети'} · синхронизация: ${d.lastSyncLabel}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: busy ? null : onSync,
                  child: const Text('Синхронизировать'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onRevoke, child: const Text('Удалить')),
            ],
          ),
        ],
      ),
    );
  }
}
