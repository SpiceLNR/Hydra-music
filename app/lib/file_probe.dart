import 'dart:io';

/// Короткая справка о файле для сообщения об ошибке воспроизведения:
/// есть ли файл, его размер и начало (по нему видно настоящий формат и обрыв загрузки).
Future<String> probeFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) {
      final parent = file.parent;
      var hint = '';
      if (await parent.exists()) {
        // файла нет по этому пути, хотя трек в списке: покажем, что реально лежит рядом
        final name = file.uri.pathSegments.last;
        final head = name.length > 6 ? name.substring(0, 6) : name;
        final similar = <String>[];
        await for (final e in parent.list()) {
          final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (Uri.decodeComponent(n).startsWith(Uri.decodeComponent(head))) similar.add(n);
          if (similar.length >= 3) break;
        }
        if (similar.isNotEmpty) hint = '; рядом: ${similar.join(' | ')}';
      }
      return 'файла нет по пути «$path»$hint';
    }
    final size = await file.length();
    if (size == 0) return 'файл пустой (0 байт)';
    final raf = await file.open();
    try {
      final head = await raf.read(16);
      final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = String.fromCharCodes(head.map((b) => (b >= 32 && b < 127) ? b : 46));
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      return 'файл $mb МБ, начало: $ascii ($hex)';
    } finally {
      await raf.close();
    }
  } catch (e) {
    return 'файл не прочитался: $e';
  }
}
