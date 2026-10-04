import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Ошибка, пришедшая из Rust-ядра (или при загрузке библиотеки).
class CoreException implements Exception {
  CoreException(this.message);
  final String message;

  @override
  String toString() => message;
}

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

DynamicLibrary _openLibrary() {
  if (Platform.isAndroid) return DynamicLibrary.open('libhydra_ffi.so');
  if (Platform.isWindows) return DynamicLibrary.open('hydra_ffi.dll');
  throw UnsupportedError('Платформа не поддерживается: ${Platform.operatingSystem}');
}

/// Один синхронный вызов ядра. Выполняется в отдельном изоляте (см. [Core.call]).
/// Библиотека загружается один раз на процесс, поэтому состояние ядра
/// (открытая библиотека) общее для всех изолятов.
String _callSync(String request) {
  final lib = _openLibrary();
  final call = lib.lookupFunction<_CallNative, _CallNative>('hydra_call');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('hydra_free');
  final req = request.toNativeUtf8();
  try {
    final resPtr = call(req);
    try {
      return resPtr.toDartString();
    } finally {
      free(resPtr);
    }
  } finally {
    malloc.free(req);
  }
}

/// Доступ к Rust-ядру: `await Core.call('playlists')`.
class Core {
  static Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) async {
    final request = jsonEncode({'method': method, 'args': args});
    final String response;
    try {
      response = await Isolate.run(() => _callSync(request));
    } catch (e) {
      throw CoreException('Не удалось загрузить ядро: $e');
    }
    final json = jsonDecode(response) as Map<String, dynamic>;
    if (json['ok'] == true) return json['result'];
    throw CoreException((json['error'] as String?) ?? 'неизвестная ошибка ядра');
  }
}
