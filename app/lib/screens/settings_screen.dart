import 'package:flutter/material.dart';

import '../core_bridge.dart';
import '../library_controller.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool wifiOnly = true;
  bool chargingOnly = false;
  final relay = TextEditingController(text: 'по умолчанию (общедоступный)');

  @override
  void dispose() {
    relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('настройки')),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          SwitchListTile(
            activeThumbColor: Metro.green,
            title: const Text('Синхронизировать только по Wi-Fi'),
            value: wifiOnly,
            onChanged: (v) => setState(() => wifiOnly = v),
          ),
          SwitchListTile(
            activeThumbColor: Metro.green,
            title: const Text('Только во время зарядки'),
            value: chargingOnly,
            onChanged: (v) => setState(() => chargingOnly = v),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Relay-сервер (для связи через интернет)',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                TextField(controller: relay),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            title: const Text('Папка библиотеки'),
            subtitle: Text(hydraLibrary.rootPath ?? 'Android: Music/Hydra  ·  Windows: Музыка\\Hydra'),
          ),
          // Проверка связи Flutter <-> Rust (временная диагностика этапа 2)
          FutureBuilder<dynamic>(
            future: Core.call('version'),
            builder: (context, snap) {
              final String text;
              if (snap.connectionState != ConnectionState.done) {
                text = 'проверяю…';
              } else if (snap.hasError) {
                text = 'ОШИБКА: ${snap.error}';
              } else {
                final v = snap.data as Map<String, dynamic>;
                text = 'работает (ядро ${v['core']}, мост ${v['ffi']})';
              }
              return ListTile(title: const Text('Ядро синхронизации'), subtitle: Text(text));
            },
          ),
          const ListTile(
            title: Text('О приложении'),
            subtitle: Text('Hydra Music 0.1.0 · открытый исходный код'),
          ),
        ],
      ),
    );
  }
}
