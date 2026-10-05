import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';
import '../widgets/now_playing_bar.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.devices});
  final List<DeviceInfo> devices;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  Future<void> _revoke(DeviceInfo d) async {
    final ok = await confirmAction(
      context,
      title: 'Отозвать устройство?',
      message: '«${d.name}» перестанет получать вашу музыку. Ключ семьи будет обновлён.',
      confirmLabel: 'Отозвать',
      danger: true,
    );
    // TODO(core): подписанная запись об отзыве + ротация ключа семьи
    if (ok) setState(() => widget.devices.remove(d));
  }

  void _pair() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить устройство'),
        content: const Text(
          'Сопряжение работает только в локальной сети.\n\n'
          'Здесь появится QR-код (действует 2-3 минуты) и 6-значный проверочный код, '
          'который нужно сверить на обоих экранах. Запасной вариант - ссылка, '
          'доступная только из локальной сети.\n\n(Реализуется на этапе 4.)',
        ),
        actions: [
          ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('устройства')),
      body: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: widget.devices.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final d = widget.devices[i];
          return Container(
            color: Metro.surface,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(width: 12, height: 12, color: d.online ? Metro.green : Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: const TextStyle(fontSize: 20)),
                      Text(
                        '${d.online ? 'в сети' : 'не в сети'} · синхронизация: ${d.lastSync}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                OutlinedButton(onPressed: () => _revoke(d), child: const Text('Отозвать')),
              ],
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
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _pair,
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
