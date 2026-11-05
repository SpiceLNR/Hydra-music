import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'build_info.dart';
import 'core_bridge.dart';

/// Этапы обновления. Плашка на главном экране показывает каждый по-своему.
enum UpdateState { idle, available, downloading, paused, preparing, ready, installing, error }

/// Описание сборки из `version-windows.json` в релизе `latest`.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.file,
    required this.size,
    required this.sha256,
  });

  final String version;
  final String build;
  final String file;
  final int size;
  final String sha256;

  /// null, если описание неполное или имя файла подозрительное.
  static UpdateInfo? parse(Object? json) {
    if (json is! Map) return null;
    final v = json['version'];
    final f = json['file'];
    final s = json['size'];
    final h = json['sha256'];
    if (v is! String || f is! String || s is! int || h is! String) return null;
    if (f.isEmpty || f.contains('/') || f.contains('\\') || f.contains('..')) return null;
    if (s <= 0 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(h)) return null;
    final b = json['build'];
    return UpdateInfo(version: v, build: b is String ? b : '', file: f, size: s, sha256: h.toLowerCase());
  }
}

/// Сравнение версий вида `0.N.M`: больше нуля, если [a] новее [b].
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split('+').first.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Автообновление на Windows.
///
/// Проверка при запуске и раз в 6 часов: `version-windows.json` из релиза `latest`.
/// Архив качается с докачкой в `<папка программы>.update`, сверяется SHA-256 и
/// распаковывается в `<папка программы>.new`, пока программа работает. «Установить»
/// запускает скрипт PowerShell и закрывает программу; скрипт дожидается выхода,
/// переименовывает `app` в `app.prev` и `app.new` в `app` и запускает новую версию.
/// Если замена не удалась, запускается прежняя версия. Данные (база, ключ устройства,
/// музыка) лежат не в папке программы и не затрагиваются.
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const _baseUrl = 'https://github.com/SpiceLNR/Hydra-music/releases/download/latest/';
  static const _manifest = 'version-windows.json';
  static const checkEvery = Duration(hours: 6);

  UpdateState state = UpdateState.idle;
  UpdateInfo? info;

  /// Сколько байт уже скачано.
  int received = 0;
  String? error;

  bool _started = false;
  Timer? _timer;
  StreamSubscription<List<int>>? _sub;
  Completer<void>? _done;
  UpdateState? _interruptTo;
  bool _dropPart = false;

  /// Обновляются только сборки из CI: у локальных нет номера коммита.
  bool get supported => Platform.isWindows && kBuild != 'локальная';

  static String get _sep => Platform.pathSeparator;
  Directory get _appDir => File(Platform.resolvedExecutable).parent;
  String get _exeName => Platform.resolvedExecutable.split(_sep).last;
  String get _newPath => '${_appDir.path}.new';
  String get _prevPath => '${_appDir.path}.prev';
  Directory get _updateDir => Directory('${_appDir.path}.update');
  String _partPath(UpdateInfo i) => '${_updateDir.path}$_sep${i.version}.zip.part';
  String _zipPath(UpdateInfo i) => '${_updateDir.path}$_sep${i.version}.zip';

  void start() {
    if (_started || !supported) return;
    _started = true;
    unawaited(_cleanup().whenComplete(check));
    _timer = Timer.periodic(checkEvery, (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _set(UpdateState s, {String? err}) {
    state = s;
    error = err;
    notifyListeners();
  }

  /// После запуска: убрать остатки прошлых обновлений (распакованную копию, скрипт,
  /// архивы версий не новее текущей). Недокачанный архив более новой версии остаётся.
  Future<void> _cleanup() async {
    try {
      final nd = Directory(_newPath);
      if (await nd.exists()) await nd.delete(recursive: true);
      final ud = _updateDir;
      if (!await ud.exists()) return;
      await for (final e in ud.list()) {
        final name = e.path.split(_sep).last;
        if (name == 'install.log') continue;
        final ver = name.split('.zip').first;
        if (!name.contains('.zip') || compareVersions(ver, kVersion) <= 0) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {
      // не мешает работе: попробуем в следующий раз
    }
  }

  Future<void> _dropOtherVersions(String keep) async {
    await for (final e in _updateDir.list()) {
      final name = e.path.split(_sep).last;
      if (name == 'install.log' || name.startsWith('$keep.zip')) continue;
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// GET с ручными перенаправлениями: заголовок Range должен дойти до конечного адреса
  /// (GitHub отдаёт файлы релиза через перенаправление на CDN).
  Future<HttpClientResponse> _open(HttpClient c, String url, {int from = 0}) async {
    var uri = Uri.parse(url);
    for (var hop = 0; hop < 6; hop++) {
      final req = await c.getUrl(uri);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'HydraMusic/$kVersion');
      if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final res = await req.close();
      if (!res.isRedirect) return res;
      final loc = res.headers.value(HttpHeaders.locationHeader);
      await res.drain<void>();
      if (loc == null) break;
      uri = uri.resolve(loc);
    }
    throw const HttpException('слишком много перенаправлений');
  }

  /// Проверка новой версии. Без сети молчит: плашка просто не появляется.
  Future<void> check() async {
    if (!supported) return;
    if (state != UpdateState.idle && state != UpdateState.available) return;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final res = await _open(c, '$_baseUrl$_manifest').timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return;
      }
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final i = UpdateInfo.parse(jsonDecode(body));
      if (state != UpdateState.idle && state != UpdateState.available) return;
      if (i == null || compareVersions(i.version, kVersion) <= 0) {
        if (state != UpdateState.idle) {
          info = null;
          _set(UpdateState.idle);
        }
        return;
      }
      if (info?.version == i.version && info?.sha256 == i.sha256) return;
      info = i;
      final part = File(_partPath(i));
      received = await part.exists() ? await part.length() : 0;
      _set(UpdateState.available);
    } catch (_) {
      // нет сети или GitHub недоступен: проверим позже
    } finally {
      c.close(force: true);
    }
  }

  /// «Скачать», «Продолжить», «Повторить».
  Future<void> download() async {
    final i = info;
    if (i == null) return;
    if (state != UpdateState.available && state != UpdateState.paused && state != UpdateState.error) return;
    _interruptTo = null;
    _dropPart = false;
    _set(UpdateState.downloading);
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      await _updateDir.create(recursive: true);
      await _dropOtherVersions(i.version);
      final part = File(_partPath(i));
      var from = await part.exists() ? await part.length() : 0;
      if (from > i.size) {
        await part.delete();
        from = 0;
      }
      received = from;
      if (from < i.size) {
        final res = await _open(c, '$_baseUrl${i.file}', from: from).timeout(const Duration(seconds: 30));
        if (res.statusCode == 200) {
          from = 0; // сервер не умеет докачку: начинаем сначала
        } else if (res.statusCode != 206) {
          await res.drain<void>();
          throw HttpException('сервер ответил ${res.statusCode}');
        }
        received = from;
        final out = part.openWrite(mode: from == 0 ? FileMode.write : FileMode.append);
        sink = out;
        final done = Completer<void>();
        _done = done;
        var lastNotify = DateTime.now();
        _sub = res.listen(
          (chunk) {
            out.add(chunk);
            received += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastNotify).inMilliseconds >= 250) {
              lastNotify = now;
              notifyListeners();
            }
          },
          onError: (Object e) {
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        _sub = null;
        _done = null;
        await out.flush();
        await out.close();
        sink = null;

        final to = _interruptTo;
        if (to != null) {
          _interruptTo = null;
          if (_dropPart) {
            if (await part.exists()) await part.delete();
            received = 0;
          }
          _set(to);
          return;
        }
      }

      final got = await part.length();
      if (got < i.size) throw const HttpException('загрузка прервалась');
      _set(UpdateState.preparing);
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != i.sha256) {
        await part.delete();
        received = 0;
        throw const FileSystemException('файл повреждён, скачайте заново');
      }
      final zip = File(_zipPath(i));
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
      await _extract(zip.path);
      _set(UpdateState.ready);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      _sub = null;
      _done = null;
      final to = _interruptTo;
      _interruptTo = null;
      if (to != null) {
        _set(to);
      } else {
        _set(UpdateState.error, err: _short(e));
      }
    } finally {
      c.close(force: true);
    }
  }

  void _interrupt(UpdateState to, {bool drop = false}) {
    if (state != UpdateState.downloading) return;
    _interruptTo = to;
    _dropPart = drop;
    unawaited(_sub?.cancel());
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  void pause() => _interrupt(UpdateState.paused);

  /// «Стоп»: недокачанное удаляется, плашка возвращается к «Скачать».
  Future<void> stop() async {
    if (state == UpdateState.downloading) {
      _interrupt(UpdateState.available, drop: true);
      return;
    }
    if (state != UpdateState.paused && state != UpdateState.error) return;
    final i = info;
    if (i != null) {
      try {
        final part = File(_partPath(i));
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    received = 0;
    _set(UpdateState.available);
  }

  Future<void> _extract(String zip) async {
    final nd = Directory(_newPath);
    if (await nd.exists()) await nd.delete(recursive: true);
    await nd.create(recursive: true);
    final exe = File('${nd.path}$_sep$_exeName');
    // tar.exe есть в Windows 10 1803 и новее; если не сработал - PowerShell
    final tar = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe';
    var ok = false;
    try {
      final r = await Process.run(tar, ['-xf', zip, '-C', nd.path]);
      ok = r.exitCode == 0 && await exe.exists();
    } catch (_) {}
    if (!ok) {
      await nd.delete(recursive: true);
      await nd.create(recursive: true);
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -LiteralPath ${_psQuote(zip)} -DestinationPath ${_psQuote(nd.path)} -Force',
      ]);
      ok = r.exitCode == 0 && await exe.exists();
    }
    if (!ok) {
      try {
        await nd.delete(recursive: true);
      } catch (_) {}
      throw const FileSystemException('не удалось распаковать архив');
    }
  }

  /// Можно ли заменить папку программы (нужна запись в родительскую папку).
  Future<bool> _canWrite() async {
    try {
      final probe = File('${_appDir.parent.path}$_sep.hydra-write-test');
      await probe.writeAsString('1');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// «Установить»: запускает скрипт замены и закрывает программу.
  Future<void> install() async {
    if (state != UpdateState.ready) return;
    _set(UpdateState.installing);
    try {
      if (!await _canWrite()) {
        throw const FileSystemException('нет прав на запись в папку программы');
      }
      final script = File('${_updateDir.path}${_sep}install.ps1');
      // PowerShell 5 читает файл без BOM в кодировке ANSI: пути с кириллицей сломались бы
      await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script())]);
      // Запуск через ядро (CREATE_NO_WINDOW): Process.start(mode: detached) даёт
      // DETACHED_PROCESS, и PowerShell 5.1 с ним молча завершается, не выполнив скрипт.
      await Core.call('spawn_hidden', {
        'program': 'powershell.exe',
        'args': ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path],
      });
      exit(0);
    } catch (e) {
      _set(UpdateState.ready, err: _short(e));
    }
  }

  String _script() {
    final app = _appDir.path;
    final appLeaf = app.split(_sep).last;
    final prevLeaf = _prevPath.split(_sep).last;
    return '''
\$ErrorActionPreference = 'Stop'
\$app  = ${_psQuote(app)}
\$new  = ${_psQuote(_newPath)}
\$prev = ${_psQuote(_prevPath)}
\$exe  = ${_psQuote(_exeName)}
\$log  = ${_psQuote('${_updateDir.path}${_sep}install.log')}
function Log(\$m) {
  try { Add-Content -LiteralPath \$log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), \$m) -Encoding UTF8 } catch { }
}
Log 'Обновление $kVersion -> ${info?.version ?? '?'}: жду закрытия программы ($pid)'
try { Wait-Process -Id $pid -Timeout 30 -ErrorAction Stop } catch { }
Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
\$ok = \$false
for (\$i = 1; \$i -le 10 -and -not \$ok; \$i++) {
  try {
    # прошлая попытка могла оставить только app.prev: сначала вернуть его на место
    if (-not (Test-Path -LiteralPath \$app) -and (Test-Path -LiteralPath \$prev)) {
      Rename-Item -LiteralPath \$prev -NewName ${_psQuote(appLeaf)}
    }
    if (Test-Path -LiteralPath \$prev) { Remove-Item -LiteralPath \$prev -Recurse -Force }
    Rename-Item -LiteralPath \$app -NewName ${_psQuote(prevLeaf)}
    try {
      Rename-Item -LiteralPath \$new -NewName ${_psQuote(appLeaf)}
      \$ok = \$true
    } catch {
      Rename-Item -LiteralPath \$prev -NewName ${_psQuote(appLeaf)}
      throw
    }
  } catch {
    Log ("Попытка {0}: {1}" -f \$i, \$_.Exception.Message)
    Start-Sleep -Seconds 1
  }
}
if (\$ok) { Log 'Новая версия на месте' } else { Log 'Не удалось заменить папку: запускаю прежнюю версию' }
Start-Process -FilePath (Join-Path \$app \$exe) -WorkingDirectory \$app
''';
  }

  static String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

  static String _short(Object e) {
    var s = e is FileSystemException
        ? e.message
        : e is HttpException
            ? e.message
            : e is SocketException
                ? 'нет связи с GitHub'
                : e is TimeoutException
                    ? 'GitHub не отвечает'
                    : '$e';
    if (s.length > 120) s = '${s.substring(0, 120)}…';
    return s;
  }
}
