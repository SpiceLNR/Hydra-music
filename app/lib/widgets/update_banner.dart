import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../player_service.dart';
import '../theme.dart';
import '../updater.dart';
import 'metro_widgets.dart';

/// Плашка обновления внизу главного экрана: «Доступна версия X» → загрузка с паузой и
/// остановкой → «Установить». Пока новой версии нет, ничего не занимает.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _install(BuildContext context) async {
    if (PlayerService.instance.playing) {
      final ok = await confirmAction(
        context,
        title: 'Установить обновление?',
        message: Platform.isAndroid
            ? 'Воспроизведение прервётся: Android закроет приложение на время установки.'
            : 'Воспроизведение прервётся: программа закроется и сразу запустится в новой версии.',
        confirmLabel: 'Установить',
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
        final size = '${_mb(i.size)} МБ';
        final progress = '${_mb(u.received)} из $size';
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
            title('Доступна версия ${i.version}');
            dim(u.received > 0 ? 'Скачано $progress' : 'Размер $size');
            buttons([ElevatedButton(onPressed: u.download, child: const Text('Скачать'))]);
          case UpdateState.downloading:
          case UpdateState.paused:
            final paused = u.state == UpdateState.paused;
            title(paused ? 'Загрузка версии ${i.version}: пауза' : 'Загрузка версии ${i.version}');
            children.add(const SizedBox(height: 8));
            children.add(_Bar(value: i.size > 0 ? u.received / i.size : 0));
            dim(progress);
            buttons([
              paused
                  ? ElevatedButton(onPressed: u.download, child: const Text('Продолжить'))
                  : OutlinedButton(onPressed: u.pause, child: const Text('Пауза')),
              OutlinedButton(onPressed: u.stop, child: const Text('Стоп')),
            ]);
          case UpdateState.preparing:
            title('Версия ${i.version}: проверяю и распаковываю…');
            children.add(const SizedBox(height: 8));
            children.add(const MetroProgress());
          case UpdateState.ready:
            title('Версия ${i.version} готова');
            dim(u.error != null
                ? 'Не удалось установить: ${u.error}'
                : Platform.isAndroid
                    ? 'Android попросит подтвердить установку. После неё откройте приложение снова.'
                    : 'Программа закроется на пару секунд и запустится уже обновлённой.');
            buttons([ElevatedButton(onPressed: () => _install(context), child: const Text('Установить'))]);
          case UpdateState.installing:
            title('Устанавливаю версию ${i.version}…');
            children.add(const SizedBox(height: 8));
            children.add(const MetroProgress());
          case UpdateState.error:
            title('Не удалось скачать версию ${i.version}');
            dim(u.error ?? 'неизвестная ошибка');
            buttons([
              ElevatedButton(onPressed: u.download, child: const Text('Повторить')),
              OutlinedButton(onPressed: u.stop, child: const Text('Стоп')),
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
