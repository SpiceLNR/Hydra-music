import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';

import '../app_messenger.dart';
import '../core_bridge.dart';
import '../net_service.dart';
import '../theme.dart';
import '../l10n/l10n.dart';

/// Показывает QR-код сопряжения. Закрывается сам, когда второе устройство подключилось.
class PairOfferScreen extends StatefulWidget {
  const PairOfferScreen({super.key});

  @override
  State<PairOfferScreen> createState() => _PairOfferScreenState();
}

class _PairOfferScreenState extends State<PairOfferScreen> {
  PairLink? _link;
  String? _error;
  late final int _familyAtStart;
  Timer? _tick;
  int _left = 180;

  @override
  void initState() {
    super.initState();
    _familyAtStart = hydraNet.familyGeneration;
    hydraNet.addListener(_onNet);
    hydraNet.watch();
    unawaited(_create());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = _left > 0 ? _left - 1 : 0);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    hydraNet.removeListener(_onNet);
    hydraNet.unwatch();
    unawaited(hydraNet.cancelOffer());
    super.dispose();
  }

  Future<void> _create() async {
    try {
      final link = await hydraNet.createOffer();
      if (!mounted) return;
      setState(() {
        _link = link;
        _left = 180;
        _error = link.addrs.isEmpty ? tr('Нет подключения к локальной сети (Wi-Fi).') : null;
      });
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _onNet() {
    if (hydraNet.familyGeneration != _familyAtStart && mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Устройство добавлено'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    return Scaffold(
      appBar: AppBar(title: Text(tr('QR-код'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Metro.danger)),
          if (link != null && link.addrs.isNotEmpty) ...[
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: link.toUri(),
                  size: 300,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _left > 0
                  ? tr('Код действует ещё {a1}:{a2}. На втором устройстве откройте «Устройства» -> «Добавить устройство» -> «Сканировать».', {'a1': _left ~/ 60, 'a2': (_left % 60).toString().padLeft(2, '0')})
                  : tr('Код устарел.'),
            ),
            const SizedBox(height: 8),
            Text(tr('Оба устройства должны быть в одной Wi-Fi сети.')),
            const SizedBox(height: 16),
            if (_left == 0)
              ElevatedButton(onPressed: _create, child: Text(tr('Показать новый код'))),
            OutlinedButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link.toUri()));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('Ссылка скопирована'))),
                );
              },
              child: Text(tr('Скопировать ссылку (для ввода вручную)')),
            ),
          ] else if (_error == null)
            const Center(child: CircularProgressIndicator(color: Metro.green)),
        ],
      ),
    );
  }
}

/// Сканирует QR-код другого устройства (только Android).
class PairScanScreen extends StatefulWidget {
  const PairScanScreen({super.key});

  @override
  State<PairScanScreen> createState() => _PairScanScreenState();
}

class _PairScanScreenState extends State<PairScanScreen> {
  CameraController? _camera;
  String? _error;
  bool _handled = false;
  bool _busy = false; // кадр сейчас разбирается: остальные пропускаем
  int _frames = 0;
  String _status = '';
  String _hint = tr('Наведите камеру на QR-код на втором устройстве');

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _error = tr('Камера не найдена'));
        return;
      }
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final controller = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      setState(() {});
      await controller.startImageStream(_onFrame);
    } on CameraException catch (e) {
      if (mounted) setState(() => _error = '${e.code}\n${e.description ?? ''}');
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    final c = _camera;
    _camera = null;
    if (c != null) {
      unawaited(() async {
        try {
          if (c.value.isStreamingImages) await c.stopImageStream();
        } on Object {
          // камера уже закрыта
        }
        await c.dispose();
      }());
    }
    super.dispose();
  }

  void _onFrame(CameraImage image) {
    if (_busy || _handled) return;
    _busy = true;
    final plane = image.planes.first; // яркость (Y): для QR цвет не нужен
    final frame = _Frame(
      Uint8List.fromList(plane.bytes),
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    unawaited(() async {
      try {
        // top-level функция без замыкания: в поток уходит только кадр, а не экран
        final text = await compute(_decodeQr, frame);
        _frames++;
        if (mounted && _frames % 5 == 0 && !_handled) {
          setState(() => _status = tr('кадров проверено: {_frames}', {'_frames': _frames}));
        }
        if (text != null) await _onText(text);
      } on Object catch (e) {
        if (mounted && !_handled) setState(() => _status = tr('ошибка разбора: {e}', {'e': e}));
      } finally {
        _busy = false;
      }
    }());
  }

  Future<void> _onText(String raw) async {
    if (_handled || !mounted) return;
    final link = PairLink.parse(raw);
    if (link == null) {
      setState(() => _hint = tr('QR прочитан, но это не код сопряжения Hydra Music'));
      return;
    }
    _handled = true;
    await hydraNet.pairWith(link);
    if (!mounted) return;
    Navigator.of(context).pop();
    showAppMessage(tr('Подключаюсь к устройству...'));
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: Text(tr('сканировать QR'))),
      body: Column(
        children: [
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        tr('Камера недоступна: {_error}', {'_error': _error}),
                        style: const TextStyle(color: Metro.danger),
                      ),
                    ),
                  )
                : camera == null || !camera.value.isInitialized
                    ? const Center(child: CircularProgressIndicator())
                    : ClipRect(
                        child: Center(child: CameraPreview(camera)),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_hint),
                if (_status.isNotEmpty)
                  Text(_status, style: const TextStyle(fontSize: 12, color: Metro.textDim)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    final started = await showPasteDialog(context);
                    if (started && context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(tr('Ввести ссылку вручную')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Кадр с камеры: только яркость.
class _Frame {
  const _Frame(this.bytes, this.width, this.height, this.stride);
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
}

/// Ищет QR-код в кадре (чистый Dart, без сервисов Google). Выполняется в отдельном потоке.
String? _decodeQr(_Frame f) {
  final px = Int32List(f.width * f.height);
  for (var y = 0; y < f.height; y++) {
    final row = y * f.stride;
    final out = y * f.width;
    for (var x = 0; x < f.width; x++) {
      final g = f.bytes[row + x];
      px[out + x] = 0xFF000000 | (g << 16) | (g << 8) | g;
    }
  }
  final source = RGBLuminanceSource(f.width, f.height, px);
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    BinaryBitmap(GlobalHistogramBinarizer(source)),
  ]) {
    try {
      return QRCodeReader().decode(bitmap).text;
    } on Object {
      // в кадре нет читаемого кода
    }
  }
  return null;
}

/// Ввод ссылки сопряжения вручную (удобно на ПК, где нет камеры).
Future<bool> showPasteDialog(BuildContext context) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Ссылка сопряжения')),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'hydra://pair?...'),
        minLines: 2,
        maxLines: 4,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(tr('Подключиться')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (text == null || !context.mounted) return false;
  final link = PairLink.parse(text);
  if (link == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Это не похоже на ссылку сопряжения'))),
    );
    return false;
  }
  await hydraNet.pairWith(link);
  return true;
}
