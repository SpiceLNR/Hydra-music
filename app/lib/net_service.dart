import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_messenger.dart';
import 'core_bridge.dart';
import 'library_controller.dart';
import 'models.dart';

/// Данные для сопряжения: их показывает один телефон/ПК (в QR-коде) и вводит другой.
class PairLink {
  PairLink({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.secret,
    required this.port,
    required this.addrs,
  });

  final String deviceId;
  final String name;
  final String publicKey;
  final String secret;
  final int port;
  final List<String> addrs;

  /// `hydra://pair?k=..&s=..&p=..&a=ip1,ip2` (короче код = проще считывается камерой).
  String toUri() => Uri(
        scheme: 'hydra',
        host: 'pair',
        queryParameters: {
          'k': publicKey,
          's': secret,
          'p': '$port',
          'a': addrs.join(','),
        },
      ).toString();

  static PairLink? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'hydra' || uri.host != 'pair') return null;
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final addrs = (q['a'] ?? '').split(',').where((a) => a.isNotEmpty).toList();
    final key = q['k'];
    final secret = q['s'];
    if (port == null || addrs.isEmpty || key == null || secret == null) return null;
    return PairLink(
      deviceId: q['d'] ?? '',
      name: q['n'] ?? 'устройство',
      publicKey: key,
      secret: secret,
      port: port,
      addrs: addrs,
    );
  }
}

/// Сеть для интерфейса: запускает фоновый узел в ядре, опрашивает его состояние
/// и обновляет библиотеку, когда синхронизация принесла изменения.
class NetService extends ChangeNotifier {
  bool started = false;
  bool busy = false;
  String message = '';
  String error = '';
  List<String> log = const [];
  List<DeviceInfo> devices = const [];
  String deviceName = '';

  /// Растёт, когда в семью добавлено устройство (экран показа QR по нему закрывается).
  int familyGeneration = 0;

  /// Служба переднего плана (Android): не даёт телефону усыпить сеть при погасшем экране.
  static const MethodChannel _service = MethodChannel('hydra/sync_service');
  bool _serviceOn = false;
  DateTime _serviceStarted = DateTime.fromMillisecondsSinceEpoch(0);

  int? _generation;
  int _watchers = 0;
  Timer? _timer;
  bool _polling = false;

  static String _defaultName() {
    if (Platform.isAndroid) return 'Телефон';
    final host = Platform.localHostname;
    return host.isEmpty ? 'Компьютер' : host;
  }

  Future<void> _keepAwake(bool on, [String text = '']) async {
    if (!Platform.isAndroid) return;
    if (on == _serviceOn) return;
    if (!on && DateTime.now().difference(_serviceStarted) < const Duration(seconds: 5)) {
      return; // задача только запущена: не успела отметиться занятой
    }
    _serviceOn = on;
    if (on) _serviceStarted = DateTime.now();
    try {
      final ok = await _service.invokeMethod<bool>(on ? 'start' : 'stop', {'text': text});
      if (on && ok == false) _serviceOn = false; // Android не разрешил (например, из фона)
    } on PlatformException {
      _serviceOn = false;
    } on MissingPluginException {
      _serviceOn = false;
    }
  }

  /// Ссылки hydra://pair?..., открытые системной камерой или браузером (Android).
  Future<void> _listenLinks() async {
    if (!Platform.isAndroid) return;
    _service.setMethodCallHandler((call) async {
      if (call.method == 'link') await _openLink(call.arguments as String?);
    });
    try {
      await _openLink(await _service.invokeMethod<String>('initialLink'));
    } on PlatformException {
      // без ссылки просто работаем дальше
    } on MissingPluginException {
      // нет нативной части
    }
  }

  Future<void> _openLink(String? raw) async {
    if (raw == null || raw.isEmpty) return;
    final link = PairLink.parse(raw);
    if (link == null) {
      messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Это не ссылка сопряжения Hydra Music')),
      );
      return;
    }
    messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Подключаюсь к устройству...')),
    );
    await pairWith(link);
  }

  Future<void> start() async {
    if (started) return;
    unawaited(_listenLinks());
    deviceName = _defaultName();
    try {
      await Core.call('net_start', {'name': deviceName});
      started = true;
      error = '';
    } on CoreException catch (e) {
      error = 'Сеть не запустилась: ${e.message}';
      notifyListeners();
      return;
    }
    await _poll();
    _schedule();
  }

  /// Экран, которому нужны частые обновления, вызывает watch/unwatch.
  void watch() {
    _watchers++;
    _schedule();
    unawaited(_poll());
  }

  void unwatch() {
    if (_watchers > 0) _watchers--;
  }

  void _schedule() {
    _timer?.cancel();
    if (!started) return;
    final fast = _watchers > 0 || busy;
    _timer = Timer(Duration(seconds: fast ? 1 : 4), () async {
      await _poll();
      _schedule();
    });
  }

  Future<void> _poll() async {
    if (_polling || !started) return;
    _polling = true;
    try {
      final st = await Core.call('net_status') as Map<String, dynamic>;
      final list = await Core.call('net_family') as List;
      final gen = (st['generation'] as num).toInt();
      busy = st['busy'] as bool;
      message = st['message'] as String;
      unawaited(_keepAwake(busy, message));
      error = st['error'] as String;
      log = (st['log'] as List).cast<String>();
      familyGeneration = (st['family_generation'] as num).toInt();
      devices = list.cast<Map<String, dynamic>>().map(DeviceInfo.fromJson).toList();
      final changed = _generation != null && _generation != gen;
      _generation = gen;
      notifyListeners();
      if (changed) await hydraLibrary.refresh();
    } on CoreException catch (e) {
      error = e.message;
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  /// IPv4-адреса этого устройства в локальной сети (сначала частные).
  Future<List<String>> localAddresses() async {
    final result = <String>[];
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in all) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.address.startsWith('169.254.')) continue;
          result.add(a.address);
        }
      }
    } on Object {
      // без адресов QR бесполезен, но интерфейс покажет это сам
    }
    bool isPrivate(String a) {
      if (a.startsWith('192.168.') || a.startsWith('10.')) return true;
      final m = RegExp(r'^172\.(\d+)\.').firstMatch(a);
      final n = m == null ? 0 : int.parse(m.group(1)!);
      return n >= 16 && n <= 31;
    }

    final priv = result.where(isPrivate).toList();
    return priv.isNotEmpty ? priv : result;
  }

  /// Создаёт одноразовое предложение сопряжения (действует 3 минуты).
  Future<PairLink> createOffer() async {
    await start();
    final o = await Core.call('net_pair_offer') as Map<String, dynamic>;
    return PairLink(
      deviceId: o['device_id'] as String,
      name: o['name'] as String,
      publicKey: o['public_key'] as String,
      secret: o['secret'] as String,
      port: (o['port'] as num).toInt(),
      addrs: await localAddresses(),
    );
  }

  Future<void> cancelOffer() async {
    try {
      await Core.call('net_pair_cancel');
    } on CoreException {
      // предложение само истечёт через 3 минуты
    }
  }

  /// Подключается к устройству, показавшему QR, и сразу синхронизируется с ним.
  Future<void> pairWith(PairLink link) async {
    await start();
    await _keepAwake(true, 'Сопряжение');
    try {
      await Core.call('net_pair_connect', {
        'addrs': [for (final a in link.addrs) '$a:${link.port}'],
        'public_key': link.publicKey,
        'secret': link.secret,
      });
      error = '';
    } on CoreException catch (e) {
      error = e.message;
      _serviceStarted = DateTime.fromMillisecondsSinceEpoch(0);
      await _keepAwake(false);
    }
    notifyListeners();
    _schedule();
    unawaited(_poll());
  }

  Future<void> sync(DeviceInfo d) async {
    await _keepAwake(true, 'Синхронизация с «${d.name}»');
    try {
      await Core.call('net_sync', {'device_id': d.id});
      error = '';
    } on CoreException catch (e) {
      error = e.message;
      _serviceStarted = DateTime.fromMillisecondsSinceEpoch(0);
      await _keepAwake(false);
    }
    notifyListeners();
    _schedule();
    unawaited(_poll());
  }

  Future<void> forget(DeviceInfo d) async {
    try {
      await Core.call('net_forget', {'device_id': d.id});
    } on CoreException catch (e) {
      error = e.message;
    }
    await _poll();
  }
}

final hydraNet = NetService();
