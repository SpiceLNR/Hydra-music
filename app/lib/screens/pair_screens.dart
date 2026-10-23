import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core_bridge.dart';
import '../net_service.dart';
import '../theme.dart';

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
        _error = link.addrs.isEmpty ? 'Нет подключения к локальной сети (Wi-Fi).' : null;
      });
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _onNet() {
    if (hydraNet.familyGeneration != _familyAtStart && mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Устройство добавлено')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    return Scaffold(
      appBar: AppBar(title: const Text('QR-код')),
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
                  ? 'Код действует ещё ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}. '
                      'На втором устройстве откройте «Устройства» -> «Добавить устройство» -> «Сканировать».'
                  : 'Код устарел.',
            ),
            const SizedBox(height: 8),
            const Text('Оба устройства должны быть в одной Wi-Fi сети.'),
            const SizedBox(height: 16),
            if (_left == 0)
              ElevatedButton(onPressed: _create, child: const Text('Показать новый код')),
            OutlinedButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link.toUri()));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ссылка скопирована')),
                );
              },
              child: const Text('Скопировать ссылку (для ввода вручную)'),
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
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String _hint = 'Наведите камеру на QR-код на втором устройстве';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue ?? '';
      final link = PairLink.parse(raw);
      if (link == null) {
        if (raw.isNotEmpty && mounted) {
          setState(() => _hint = 'QR прочитан, но это не код сопряжения Hydra Music');
        }
        continue;
      }
      _handled = true;
      await hydraNet.pairWith(link);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Подключаюсь к устройству...')),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('сканировать QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error, child) {
                final details = error.errorDetails?.message;
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Камера недоступна: ${error.errorCode.name}'
                      '${details == null ? '' : '\n$details'}'
                      '\n\nНа телефоне без сервисов Google можно сканировать QR обычной '
                      'камерой телефона: ссылка откроется в Hydra Music сама.',
                      style: const TextStyle(color: Metro.danger),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_hint),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    final started = await showPasteDialog(context);
                    if (started && context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Ввести ссылку вручную'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ввод ссылки сопряжения вручную (удобно на ПК, где нет камеры).
Future<bool> showPasteDialog(BuildContext context) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ссылка сопряжения'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'hydra://pair?...'),
        minLines: 2,
        maxLines: 4,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Подключиться'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (text == null || !context.mounted) return false;
  final link = PairLink.parse(text);
  if (link == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Это не похоже на ссылку сопряжения')),
    );
    return false;
  }
  await hydraNet.pairWith(link);
  return true;
}
