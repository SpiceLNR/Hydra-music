import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'build_info.dart';
import 'core_bridge.dart';

/// Этапы обновления. Плашка на главном экране показывает каждый по-своему.
enum UpdateState { idle, available, downloading, paused, preparing, ready, installing, error }

/// Итог проверки: есть новее, установлена последняя, не удалось связаться,
/// обновление уже идёт (качается или готово), проверка не нужна (локальная сборка).
enum CheckResult { newer, upToDate, failed, busy, skipped }

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

/// Автообновление (Windows и Android).
///
/// Проверка при запуске и раз в 6 часов: `version-windows.json` или
/// `version-android.json` из релиза `latest`.
///
/// Android: APK качается с докачкой в папку данных приложения (`update/`), сверяется
/// SHA-256, «Установить» передаёт файл системному установщику (сеанс PackageInstaller,
/// канал `hydra/update` в MainActivity). Android спрашивает подтверждение, а в первый раз
/// разрешение «Установка неизвестных приложений». После установки приложение закрывается.
///
/// Windows:
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
  static const checkEvery = Duration(hours: 6);
  static const MethodChannel _android = MethodChannel('hydra/update');

  static String get _manifest => Platform.isAndroid ? 'version-android.json' : 'version-windows.json';
  static String get _ext => Platform.isAndroid ? 'apk' : 'zip';

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
  bool get supported => (Platform.isWindows || Platform.isAndroid) && kBuild != 'локальная';

  static String get _sep => Platform.pathSeparator;
  Directory get _appDir => File(Platform.resolvedExecutable).parent;
  String get _exeName => Platform.resolvedExecutable.split(_sep).last;
  String get _newPath => '${_appDir.path}.new';
  String get _prevPath => '${_appDir.path}.prev';

  /// Windows: `<папка программы>.update`; Android: `update/` в данных приложения.
  Directory? _dir;
  Directory get _updateDir => _dir!;
  String _partPath(UpdateInfo i) => '${_updateDir.path}$_sep${i.version}.$_ext.part';
  String _zipPath(UpdateInfo i) => '${_updateDir.path}$_sep${i.version}.$_ext';

  void start() {
    if (_started || !supported) return;
    _started = true;
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      if (Platform.isAndroid) {
        final support = await getApplicationSupportDirectory();
        _dir = Directory('${support.path}${_sep}update');
        _android.setMethodCallHandler((call) async {
          if (call.method == 'installFailed' && state == UpdateState.installing) {
            _set(UpdateState.ready, err: '${call.arguments ?? 'неизвестная ошибка'}');
          }
        });
      } else {
        _dir = Directory('${_appDir.path}.update');
      }
    } catch (_) {
      return; // без папки обновлений проверка не нужна
    }
    await _cleanup();
    await check();
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
      if (Platform.isWindows) {
        final nd = Directory(_newPath);
        if (await nd.exists()) await nd.delete(recursive: true);
      }
      final ud = _updateDir;
      if (!await ud.exists()) return;
      await for (final e in ud.list()) {
        final name = e.path.split(_sep).last;
        if (name == 'install.log') continue;
        final ver = name.split('.$_ext').first;
        if (!name.contains('.$_ext') || compareVersions(ver, kVersion) <= 0) {
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
      if (name == 'install.log' || name.startsWith('$keep.$_ext')) continue;
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

  /// Когда последний раз удалось прочитать описание версии (для экрана настроек).
  DateTime? lastChecked;

  /// Проверка новой версии. Без сети молчит: плашка просто не появляется.
  Future<CheckResult> check() async {
    if (!supported || _dir == null) return CheckResult.skipped;
    if (state != UpdateState.idle && state != UpdateState.available) return CheckResult.busy;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final res = await _open(c, '$_baseUrl$_manifest').timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return CheckResult.failed;
      }
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final i = UpdateInfo.parse(jsonDecode(body));
      if (i == null) return CheckResult.failed;
      lastChecked = DateTime.now();
      if (state != UpdateState.idle && state != UpdateState.available) return CheckResult.busy;
      if (compareVersions(i.version, kVersion) <= 0) {
        info = null;
        _set(UpdateState.idle);
        return CheckResult.upToDate;
      }
      if (info?.version == i.version && info?.sha256 == i.sha256) {
        notifyListeners();
        return CheckResult.newer;
      }
      info = i;
      final part = File(_partPath(i));
      final whole = File(_zipPath(i));
      received = await part.exists()
          ? await part.length()
          : await whole.exists()
              ? await whole.length()
              : 0;
      _set(UpdateState.available);
      return CheckResult.newer;
    } catch (_) {
      // нет сети или GitHub недоступен: проверим позже
      return CheckResult.failed;
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
      // архив уже скачан (например, прошлая установка не удалась): проверим и его
      final whole = File(_zipPath(i));
      if (!await part.exists() && await whole.exists()) await whole.rename(part.path);
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
      // на Android APK ставится как есть, на Windows архив распаковывается заранее
      if (Platform.isWindows) await _extract(zip.path);
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

  /// «Установить». Windows: запускает скрипт замены и закрывает программу.
  /// Android: передаёт APK системному установщику.
  Future<void> install() async {
    if (state != UpdateState.ready) return;
    if (Platform.isAndroid) return _installAndroid();
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
      // Текущая папка - app.update: унаследованная папка программы была бы занята
      // самим скриптом, и переименовать её не получилось бы.
      await Core.call('spawn_hidden', {
        'program': 'powershell.exe',
        'args': ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        'cwd': _updateDir.path,
      });
      exit(0);
    } catch (e) {
      _set(UpdateState.ready, err: _short(e));
    }
  }

  Future<void> _installAndroid() async {
    final i = info;
    if (i == null) return;
    try {
      final can = await _android.invokeMethod<bool>('canInstall') ?? false;
      if (!can) {
        await _android.invokeMethod<bool>('openInstallSettings');
        _set(UpdateState.ready,
            err: 'разрешите Hydra Music устанавливать приложения и нажмите «Установить» ещё раз');
        return;
      }
      _set(UpdateState.installing);
      await _android.invokeMethod<bool>('install', {'path': _zipPath(i)});
      // дальше системный диалог; при отмене или ошибке придёт installFailed
    } on PlatformException catch (e) {
      _set(UpdateState.ready, err: e.message ?? e.code);
    } catch (e) {
      _set(UpdateState.ready, err: _short(e));
    }
  }

  String _script() {
    final app = _appDir.path;
    final appLeaf = app.split(_sep).last;
    final prevLeaf = _prevPath.split(_sep).last;
    final oldLeaf = '$prevLeaf.old';
    return '''
\$ErrorActionPreference = 'Stop'
\$app  = ${_psQuote(app)}
\$new  = ${_psQuote(_newPath)}
\$prev = ${_psQuote(_prevPath)}
\$old  = ${_psQuote('$_prevPath.old')}
\$home_ = ${_psQuote(_appDir.parent.path)}
\$exe  = ${_psQuote(_exeName)}
\$log  = ${_psQuote('${_updateDir.path}${_sep}install.log')}
function Log(\$m) {
  try { Add-Content -LiteralPath \$log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), \$m) -Encoding UTF8 } catch { }
}
# своя текущая папка не должна быть внутри app: иначе её нельзя переименовать
try { [System.IO.Directory]::SetCurrentDirectory(\$env:TEMP); Set-Location -LiteralPath \$env:TEMP } catch { }
Log 'Обновление $kVersion -> ${info?.version ?? '?'}: жду закрытия программы ($pid)'
try { Wait-Process -Id $pid -Timeout 30 -ErrorAction Stop } catch { }
Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
\$ok = \$false
for (\$i = 1; \$i -le 10 -and -not \$ok; \$i++) {
  try {
    # прошлая попытка могла оставить app только в виде app.prev: вернуть на место
    if (-not (Test-Path -LiteralPath \$app) -and (Test-Path -LiteralPath \$prev)) {
      Rename-Item -LiteralPath \$prev -NewName ${_psQuote(appLeaf)}
    }
    if (-not (Test-Path -LiteralPath \$app)) { throw 'нет папки программы' }
    if (-not (Test-Path -LiteralPath \$new)) { throw 'нет распакованной новой версии' }
    if (Test-Path -LiteralPath \$old) { Remove-Item -LiteralPath \$old -Recurse -Force }
    # прежняя резервная копия убирается только после удачной замены
    if (Test-Path -LiteralPath \$prev) { Rename-Item -LiteralPath \$prev -NewName ${_psQuote(oldLeaf)} }
    try {
      Rename-Item -LiteralPath \$app -NewName ${_psQuote(prevLeaf)}
    } catch {
      if (Test-Path -LiteralPath \$old) { Rename-Item -LiteralPath \$old -NewName ${_psQuote(prevLeaf)} }
      throw
    }
    try {
      Rename-Item -LiteralPath \$new -NewName ${_psQuote(appLeaf)}
      \$ok = \$true
    } catch {
      Rename-Item -LiteralPath \$prev -NewName ${_psQuote(appLeaf)}
      if (Test-Path -LiteralPath \$old) { Rename-Item -LiteralPath \$old -NewName ${_psQuote(prevLeaf)} }
      throw
    }
  } catch {
    Log ("Попытка {0}: {1}" -f \$i, \$_.Exception.Message)
    if (\$i -eq 1) {
      # кто держит папку: процессы, запущенные из неё
      try {
        Get-CimInstance Win32_Process | Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith(\$app, 'OrdinalIgnoreCase') } |
          ForEach-Object { Log ("  занято: {0} ({1})" -f \$_.Name, \$_.ProcessId) }
      } catch { }
    }
    Start-Sleep -Seconds 1
  }
}
if (\$ok) {
  if (Test-Path -LiteralPath \$old) { try { Remove-Item -LiteralPath \$old -Recurse -Force } catch { } }
  Log 'Новая версия на месте'
} else {
  Log 'Не удалось заменить папку: запускаю прежнюю версию'
}
# текущая папка программы - на уровень выше app, чтобы не мешать следующему обновлению
Start-Process -FilePath (Join-Path \$app \$exe) -WorkingDirectory \$home_
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
