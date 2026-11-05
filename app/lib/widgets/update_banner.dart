import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';
import '../updater.dart';
import 'metro_widgets.dart';
import '../l10n/l10n.dart';

/// Плашка обновления внизу главного экрана: «Доступна версия X» → загрузка с паузой и
/// остановкой → «Установить». Пока новой версии нет, ничего не занимает.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _install(BuildContext context) async {
    if (PlayerService.instance.playing) {
      final ok = await confirmAction(
        context,
        title: tr('Установить обновление?'),
        message: Platform.isAndroid
            ? tr('Воспроизведение прервётся: Android закроет приложение на время установки.')
            : tr('Воспроизведение прервётся: программа закроется и сразу запустится в новой версии.'),
        confirmLabel: tr('Установить'),
      );
      if (!ok) return;
    }
    await UpdateService.instance.install();
  }

  @override
  Widget build(BuildContext context) {
    final u = UpdateService.instance;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final i = u.info;
        if (i == null || u.state == UpdateState.idle) return const SizedBox.shrink();
        final size = tr('{a1} МБ', {'a1': _mb(i.size)});
        final progress = tr('{a1} из {size}', {'a1': _mb(u.received), 'size': size});
        final children = <Widget>[];
        void title(String t) => children.add(Text(t, style: const TextStyle(fontWeight: FontWeight.w600)));
        void dim(String t) {
          children
            ..add(const SizedBox(height: 4))
            ..add(Text(t, style: const TextStyle(fontSize: 13, color: Metro.textDim)));
        }

        void buttons(List<Widget> b) {
          children.add(const SizedBox(height: 8));
          children.add(Row(
            children: [
              for (var k = 0; k < b.length; k++) ...[
                if (k > 0) const SizedBox(width: 8),
                Expanded(child: b[k]),
              ],
            ],
          ));
        }

        switch (u.state) {
          case UpdateState.idle:
            break;
          case UpdateState.available:
            title(tr('Доступна версия {version}', {'version': i.version}));
            dim(u.received > 0 ? tr('Скачано {progress}', {'progress': progress}) : tr('Размер {size}', {'size': size}));
            buttons([ElevatedButton(onPressed: u.download, child: Text(tr('Скачать')))]);
          case UpdateState.downloading:
          case UpdateState.paused:
            final paused = u.state == UpdateState.paused;
            title(paused ? tr('Загрузка версии {version}: пауза', {'version': i.version}) : tr('Загрузка версии {version}', {'version': i.version}));
            children.add(const SizedBox(height: 8));
            children.add(_Bar(value: i.size > 0 ? u.received / i.size : 0));
            dim(progress);
            buttons([
              paused
                  ? ElevatedButton(onPressed: u.download, child: Text(tr('Продолжить')))
                  : OutlinedButton(onPressed: u.pause, child: Text(tr('Пауза'))),
              OutlinedButton(onPressed: u.stop, child: Text(tr('Стоп'))),
            ]);
          case UpdateState.preparing:
            title(tr('Версия {version}: проверяю и распаковываю…', {'version': i.version}));
            children.add(const SizedBox(height: 8));
            children.add(const MetroProgress());
          case UpdateState.ready:
            title(tr('Версия {version} готова', {'version': i.version}));
            dim(u.error != null
                ? tr('Не удалось установить: {error}', {'error': u.error})
                : Platform.isAndroid
                    ? tr('Android попросит подтвердить установку. После неё откройте приложение снова.')
                    : tr('Программа закроется на пару секунд и запустится уже обновлённой.'));
            buttons([ElevatedButton(onPressed: () => _install(context), child: Text(tr('Установить')))]);
          case UpdateState.installing:
            title(tr('Устанавливаю версию {version}…', {'version': i.version}));
            children.add(const SizedBox(height: 8));
            children.add(const MetroProgress());
          case UpdateState.error:
            title(tr('Не удалось скачать версию {version}', {'version': i.version}));
            dim(u.error ?? tr('неизвестная ошибка'));
            buttons([
              ElevatedButton(onPressed: u.download, child: Text(tr('Повторить'))),
              OutlinedButton(onPressed: u.stop, child: Text(tr('Стоп'))),
            ]);
        }
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Metro.surface,
            border: Border.all(color: Metro.green, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}

/// Плоская полоса прогресса в стиле Metro.
class _Bar extends StatelessWidget {
  const _Bar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 6,
      child: ColoredBox(
        color: Metro.bg,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            heightFactor: 1,
            child: const ColoredBox(color: Metro.green),
          ),
        ),
      ),
    );
  }
}
