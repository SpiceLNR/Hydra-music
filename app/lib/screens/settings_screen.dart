import 'package:flutter/material.dart';

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
            activeColor: Metro.green,
            title: const Text('Синхронизировать только по Wi-Fi'),
            value: wifiOnly,
            onChanged: (v) => setState(() => wifiOnly = v),
          ),
          SwitchListTile(
            activeColor: Metro.green,
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
            subtitle: const Text('Android: Music/Hydra/  ·  Windows: %USERPROFILE%\\Music\\Hydra'),
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
