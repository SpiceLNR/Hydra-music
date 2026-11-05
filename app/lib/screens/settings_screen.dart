import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../build_info.dart';
import '../core_bridge.dart';
import '../desktop/autostart.dart';
import '../desktop/desktop_settings.dart';
import '../desktop/dock_controller.dart';
import '../library_controller.dart';
import '../net_service.dart';
import '../theme.dart';
import '../updater.dart';
import '../widgets/metro_widgets.dart';

/// Настройки. Панели «Сейчас играет» здесь нет намеренно.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  final relay = TextEditingController(text: 'по умолчанию (общедоступный)');
  bool? _batteryFree; // null: ещё не узнали

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readBattery();
  }

  /// Выбор новой папки и перенос в неё всей библиотеки.
  Future<void> _changeRoot() async {
    final old = hydraLibrary.rootPath ?? '';
    final String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(dialogTitle: 'Новая папка библиотеки');
    } catch (e) {
      _toast('Не удалось открыть выбор папки: $e');
      return;
    }
    if (picked == null || !mounted) return;
    // непустую папку (например, «Музыка») не трогаем: библиотека ляжет в подпапку Hydra
    var target = picked;
    try {
      final dir = Directory(picked);
      if (await dir.exists() && !await dir.list().isEmpty) {
        target = '$picked${Platform.pathSeparator}Hydra';
      }
    } catch (_) {
      // проверку выполнит ядро
    }
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Папка библиотеки'),
        content: Text(
          'Выбрано: $picked\n\n'
          '«Перенести»: все плейлисты и корзина переедут\nиз: $old\nв: $target\n'
          'Если папки на разных дисках, это может занять много времени. '
          'Если что-то пойдёт не так, всё вернётся на место.\n\n'
          '«Использовать эту»: ничего не переносится, приложение начнёт работать с выбранной '
          'папкой как с библиотекой (например, после переустановки, когда музыка уже лежит там).\n\n'
          'Музыка остановится, идущая синхронизация прервётся.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'use'), child: const Text('Использовать эту')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'move'), child: const Text('Перенести')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'use') {
      try {
        await hydraLibrary.useFolder(picked);
        if (mounted) {
          setState(() {});
          _toast('Теперь библиотека: $picked');
        }
      } catch (e) {
        if (mounted) _toast('Не удалось открыть папку: $e');
      }
      return;
    }
    final nav = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Переношу файлы…')),
            ],
          ),
        ),
      ),
    ));
    String message;
    try {
      final r = await hydraLibrary.moveTo(target);
      final left = (r['leftover'] as List?)?.length ?? 0;
      message = 'Библиотека перенесена: файлов ${r['files']}'
          '${left > 0 ? '. Не удалось убрать старые файлы: $left (папка занята)' : ''}';
    } on CoreException catch (e) {
      message = 'Перенос не выполнен, всё осталось на месте: ${e.message}';
    } catch (e) {
      message = 'Перенос не выполнен: $e';
    }
    nav.pop();
    if (mounted) {
      setState(() {});
      _toast(message);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    relay.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вернулись из системного окна про батарею
    if (state == AppLifecycleState.resumed) _readBattery();
  }

  String _internetText() {
    if (!hydraNet.internetOn) return 'Выключено: устройства синхронизируются только в одной сети Wi-Fi.';
    if (hydraNet.internetError.isNotEmpty) return 'Не запустилось: ${hydraNet.internetError}';
    if (hydraNet.endpoint.isEmpty) {
      return 'Включено. Заработает после перезапуска приложения.';
    }
    return 'Работает. Устройства из вашей семьи находят друг друга и вне дома: '
        'напрямую или через промежуточный сервер. Музыка при этом идёт зашифрованной.';
  }

  Future<void> _readBattery() async {
    if (!Platform.isAndroid) return;
    final v = await hydraNet.batteryExempt();
    if (mounted) setState(() => _batteryFree = v);
  }

  /// Своё имя: так это устройство видят остальные (в «Устройствах» и журнале).
  Future<void> _editName() async {
    final controller = TextEditingController(text: hydraNet.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Имя этого устройства'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 40,
              decoration: const InputDecoration(hintText: 'Например, «Телефон Даши»'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const Text(
              'Так это устройство увидят остальные. Они узнают новое имя при следующей синхронизации.',
              style: TextStyle(fontSize: 13, color: Metro.textDim),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim() == hydraNet.deviceName) return;
    final err = await hydraNet.setDeviceName(name);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Имя не сохранено: $err')));
    }
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
            const _AutostartRow(),
            const Divider(),
          ],
          ListenableBuilder(
            listenable: hydraNet,
            builder: (context, _) => ListTile(
              title: const Text('Имя этого устройства'),
              subtitle: Text(hydraNet.deviceName.isEmpty ? '…' : hydraNet.deviceName),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editName,
            ),
          ),
          ListenableBuilder(
            listenable: hydraNet,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MetroSwitchRow(
                  title: 'Автосинхронизация',
                  value: hydraNet.autoSync,
                  onChanged: hydraNet.setAutoSync,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    Platform.isAndroid
                        ? 'Устройства из вашей семьи сами синхронизируются, когда оказываются в одной '
                            'сети Wi-Fi. Пока включено, в шторке висит уведомление: так Android не '
                            'закрывает приложение.'
                        : 'Устройства из вашей семьи сами синхронизируются, когда оказываются в одной '
                            'сети Wi-Fi, пока Hydra Music запущена.',
                    style: const TextStyle(fontSize: 13, color: Metro.textDim),
                  ),
                ),
                MetroSwitchRow(
                  title: 'Связь через интернет',
                  value: hydraNet.internetOn,
                  onChanged: hydraNet.setInternetOn,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    _internetText(),
                    style: TextStyle(
                      fontSize: 13,
                      color: hydraNet.internetError.isNotEmpty ? Metro.danger : Metro.textDim,
                    ),
                  ),
                ),
                if (Platform.isAndroid)
                  MetroSwitchRow(
                    title: 'Через интернет только по Wi-Fi',
                    value: hydraNet.internetWifiOnly,
                    onChanged: hydraNet.internetOn ? hydraNet.setInternetWifiOnly : (_) {},
                  ),
                if (Platform.isAndroid) ...[
                  MetroSwitchRow(
                    title: 'Только во время зарядки',
                    value: hydraNet.autoOnlyCharging,
                    onChanged: hydraNet.autoSync ? hydraNet.setAutoOnlyCharging : (_) {},
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: OutlinedButton(
                      onPressed: _batteryFree == true ? null : hydraNet.requestBatteryExempt,
                      child: Text(_batteryFree == true
                          ? 'Работа в фоне разрешена'
                          : 'Разрешить работу в фоне (батарея)'),
                    ),
                  ),
                ],
              ],
            ),
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
            trailing: const Icon(Icons.drive_file_move_outline),
            onTap: _changeRoot,
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
            title: const Text('Версия'),
            subtitle: Text('$kVersion (сборка $kBuild)'),
          ),
          const _UpdateTile(),
          const ListTile(
            title: Text('О приложении'),
            subtitle: Text('Hydra Music · SpiceLNR · PolyForm Noncommercial'),
          ),
        ],
      ),
    );
  }
}

/// «Обновления»: состояние и кнопка «Проверить» (сразу, не дожидаясь проверки раз в 6 часов).
class _UpdateTile extends StatefulWidget {
  const _UpdateTile();

  @override
  State<_UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<_UpdateTile> {
  bool _checking = false;
  String? _result;

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final u = UpdateService.instance;
    final r = await u.check();
    if (!mounted) return;
    final where = Platform.isWindows ? 'внизу шторки' : 'на главном экране под плитками';
    setState(() {
      _checking = false;
      _result = switch (r) {
        CheckResult.newer => 'Доступна версия ${u.info?.version ?? '?'}: плашка $where.',
        CheckResult.upToDate => 'Установлена последняя версия.',
        CheckResult.failed => 'Не удалось связаться с GitHub. Проверьте интернет.',
        CheckResult.busy => 'Обновление ${u.info?.version ?? ''} уже скачивается или готово: плашка $where.',
        CheckResult.skipped => 'Обновления проверяются только у сборок из GitHub.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final last = u.lastChecked;
        final String text;
        if (!u.supported) {
          text = 'Локальная сборка: обновления не проверяются.';
        } else if (_checking) {
          text = 'Проверяю…';
        } else if (_result != null) {
          text = _result!;
        } else {
          text = last == null
              ? 'Проверяется при запуске и раз в 6 часов.'
              : 'Последняя проверка в ${_time(last)}. Проверяется при запуске и раз в 6 часов.';
        }
        return ListTile(
          title: const Text('Обновления'),
          subtitle: Text(text),
          trailing: OutlinedButton(
            onPressed: u.supported && !_checking ? _check : null,
            child: const Text('Проверить'),
          ),
        );
      },
    );
  }
}

/// «Запускать вместе с Windows»: программа стартует свёрнутой у края экрана.
class _AutostartRow extends StatefulWidget {
  const _AutostartRow();

  @override
  State<_AutostartRow> createState() => _AutostartRowState();
}

class _AutostartRowState extends State<_AutostartRow> {
  bool? _on; // null: ещё не прочитали или не удалось
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final on = await Autostart.isEnabled();
      if (mounted) setState(() => _on = on);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _set(bool on) async {
    try {
      await Autostart.setEnabled(on);
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MetroSwitchRow(
          title: 'Запускать вместе с Windows',
          value: _on ?? false,
          onChanged: (v) => _set(v),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _error != null
                ? 'Не получилось: $_error'
                : 'Программа стартует свёрнутой у края экрана, значок - в области уведомлений.',
            style: TextStyle(fontSize: 13, color: _error != null ? Metro.danger : Metro.textDim),
          ),
        ),
      ],
    );
  }
}
