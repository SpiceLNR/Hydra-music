import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../build_info.dart';
import '../core_bridge.dart';
import '../desktop/desktop_settings.dart';
import '../desktop/dock_controller.dart';
import '../library_controller.dart';
import '../theme.dart';
import '../widgets/metro_widgets.dart';

/// Настройки. Панели «Сейчас играет» здесь нет намеренно.
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
          if (Platform.isWindows) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Окно (Windows)', style: TextStyle(fontSize: 20)),
            ),
            ListenableBuilder(
              listenable: DesktopSettings.instance,
              builder: (context, _) {
                final s = DesktopSettings.instance;
                Widget side(String label, bool right) {
                  final selected = s.dockRight == right;
                  void choose() {
                    s.setDockRight(right);
                    DockController.instance.reapply();
                  }

                  return Expanded(
                    child: selected
                        ? ElevatedButton(onPressed: choose, child: Text(label))
                        : OutlinedButton(onPressed: choose, child: Text(label)),
                  );
                }

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Сторона закрепления', style: TextStyle(fontSize: 18)),
                          const SizedBox(height: 8),
                          Row(children: [side('Слева', false), const SizedBox(width: 8), side('Справа', true)]),
                        ],
                      ),
                    ),
                    MetroSwitchRow(
                      title: 'Сворачиваться в полоску при клике вне окна',
                      value: s.autoCollapse,
                      onChanged: s.setAutoCollapse,
                    ),
                  ],
                );
              },
            ),
            const Divider(),
          ],
          MetroSwitchRow(
            title: 'Синхронизировать только по Wi-Fi',
            value: wifiOnly,
            onChanged: (v) => setState(() => wifiOnly = v),
          ),
          MetroSwitchRow(
            title: 'Только во время зарядки',
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
                TextField(controller: relay, decoration: Metro.inputDecoration()),
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
          ListTile(
            title: const Text('Сборка'),
            subtitle: Text(kBuild),
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
