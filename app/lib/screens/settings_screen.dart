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
  bool? _batteryFree; // null: ещё не узнали

  /// Проверка ядра: один раз при открытии экрана (строка видна только при ошибке).
  late final Future<dynamic> _core = Core.call('version');

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вернулись из системного окна про батарею
    if (state == AppLifecycleState.resumed) _readBattery();
  }

  /// Что не так со связью через интернет (null - всё в порядке или она выключена).
  String? _internetProblem() {
    if (!hydraNet.internetOn) return null;
    if (hydraNet.internetError.isNotEmpty) return 'Не запустилось: ${hydraNet.internetError}';
    if (hydraNet.endpoint.isEmpty) return 'Заработает после перезапуска приложения.';
    return null;
  }

  /// Свой relay-сервер: адрес https://...; пусто - общедоступные серверы n0.
  Future<void> _editRelay() async {
    final controller = TextEditingController(text: hydraNet.relay);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Relay-сервер'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'https://relay.example.com'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 8),
            const Text(
              'Через него устройства связываются, когда напрямую не получается. '
              'Пустое поле - общедоступные серверы n0. Музыка идёт зашифрованной.',
              style: TextStyle(fontSize: 13, color: Metro.textDim),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('По умолчанию')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim() == hydraNet.relay) return;
    final err = await hydraNet.setRelay(value);
    if (!mounted) return;
    _toast(err == null
        ? (value.trim().isEmpty ? 'Relay: серверы по умолчанию' : 'Relay-сервер сохранён')
        : 'Relay не изменён: $err');
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
      body: ListenableBuilder(
        listenable: hydraNet,
        builder: (context, _) {
          final problem = _internetProblem();
          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
            children: [
              const _Section('Это устройство'),
              _ValueRow(
                title: 'Имя',
                value: hydraNet.deviceName.isEmpty ? '…' : hydraNet.deviceName,
                onTap: _editName,
              ),

              const _Section('Синхронизация'),
              MetroSwitchRow(
                title: 'Автоматически',
                value: hydraNet.autoSync,
                onChanged: hydraNet.setAutoSync,
              ),
              if (Platform.isAndroid)
                MetroSwitchRow(
                  title: 'Только во время зарядки',
                  value: hydraNet.autoOnlyCharging,
                  onChanged: hydraNet.autoSync ? hydraNet.setAutoOnlyCharging : (_) {},
                ),
              MetroSwitchRow(
                title: 'Через интернет',
                value: hydraNet.internetOn,
                onChanged: hydraNet.setInternetOn,
              ),
              if (problem != null)
                _Note(problem, error: hydraNet.internetError.isNotEmpty),
              if (Platform.isAndroid)
                MetroSwitchRow(
                  title: 'Через интернет только по Wi-Fi',
                  value: hydraNet.internetWifiOnly,
                  onChanged: hydraNet.internetOn ? hydraNet.setInternetWifiOnly : (_) {},
                ),
              _ValueRow(
                title: 'Relay-сервер',
                value: hydraNet.relay.isEmpty ? 'по умолчанию' : hydraNet.relay,
                onTap: _editRelay,
              ),
              if (Platform.isAndroid && _batteryFree != true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: OutlinedButton(
                    onPressed: hydraNet.requestBatteryExempt,
                    child: const Text('Разрешить работу в фоне'),
                  ),
                ),

              const _Section('Библиотека'),
              _ValueRow(
                title: 'Папка',
                value: hydraLibrary.rootPath ?? '…',
                onTap: _changeRoot,
              ),

              if (Platform.isWindows) ...[
                const _Section('Окно'),
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
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                          child: Row(
                            children: [
                              const Expanded(
                                  child: Text('Сторона', style: TextStyle(fontSize: 18))),
                              SizedBox(
                                width: 200,
                                child: Row(children: [
                                  side('Слева', false),
                                  const SizedBox(width: 8),
                                  side('Справа', true),
                                ]),
                              ),
                            ],
                          ),
                        ),
                        MetroSwitchRow(
                          title: 'Сворачивать при клике вне окна',
                          value: s.autoCollapse,
                          onChanged: s.setAutoCollapse,
                        ),
                      ],
                    );
                  },
                ),
                const _AutostartRow(),
              ],

              const _Section('Обновления'),
              const _UpdateTile(),
              // ядро показываем, только если оно не запустилось: тогда тут причина
              FutureBuilder<dynamic>(
                future: _core,
                builder: (context, snap) => snap.hasError
                    ? _Note('Ядро не запустилось: ${snap.error}', error: true)
                    : const SizedBox.shrink(),
              ),

              const Padding(
                padding: EdgeInsets.fromLTRB(16, 32, 16, 0),
                child: Text(
                  'Hydra Music · SpiceLNR · PolyForm Noncommercial',
                  style: TextStyle(fontSize: 13, color: Metro.textDim),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Заголовок раздела настроек: зелёный, строчными буквами, как в Windows Phone.
class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
      child: Text(
        title.toLowerCase(),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w300, color: Metro.green),
      ),
    );
  }
}

/// Строка «название - значение ›»: по нажатию открывается изменение.
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.title, required this.value, required this.onTap});

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Text(title, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 16, color: Metro.textDim),
              ),
            ),
            const Icon(Icons.chevron_right, color: Metro.textDim),
          ],
        ),
      ),
    );
  }
}

/// Короткая пометка под настройкой (ошибка - красным).
class _Note extends StatelessWidget {
  const _Note(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: error ? Metro.danger : Metro.textDim),
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
          text = 'сборка $kBuild · локальная, обновления не проверяются';
        } else if (_checking) {
          text = 'Проверяю…';
        } else if (_result != null) {
          text = _result!;
        } else {
          text = last == null ? 'сборка $kBuild' : 'сборка $kBuild · проверено в ${_time(last)}';
        }
        return ListTile(
          title: Text('Версия $kVersion', style: const TextStyle(fontSize: 18)),
          subtitle: Text(text, style: const TextStyle(fontSize: 13, color: Metro.textDim)),
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
        if (_error != null) _Note('Не получилось: $_error', error: true),
      ],
    );
  }
}
