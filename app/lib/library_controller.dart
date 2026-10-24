import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'net_service.dart';

enum LibraryStatus { idle, loading, needPermission, ready, error }

/// Состояние библиотеки для интерфейса: открывает ядро, сканирует папку Hydra,
/// хранит список плейлистов и передаёт действия пользователя в Rust.
class LibraryController extends ChangeNotifier {
  LibraryStatus status = LibraryStatus.idle;

  /// Фатальная ошибка открытия библиотеки.
  String? error;

  /// Нефатальное сообщение (например, отказ сканирования).
  String? notice;

  List<PlaylistInfo> playlists = const [];

  /// Массовые удаления вне приложения: ждут решения (удалить везде или вернуть).
  List<HeldDeletion> held = const [];
  String? rootPath;
  bool scanning = false;

  final Map<String, String?> _covers = {};

  /// Растёт, когда у трека изменились название, исполнитель или обложка:
  /// открытые списки по нему понимают, что их надо перечитать.
  int tracksRevision = 0;

  void _setStatus(LibraryStatus s) {
    status = s;
    notifyListeners();
  }

  Future<void> init() async {
    error = null;
    _setStatus(LibraryStatus.loading);
    try {
      if (Platform.isAndroid && !await Permission.manageExternalStorage.isGranted) {
        _setStatus(LibraryStatus.needPermission);
        return;
      }
      await _open();
    } catch (e) {
      error = '$e';
      _setStatus(LibraryStatus.error);
    }
  }

  /// Открывает системную страницу «Доступ ко всем файлам».
  Future<void> requestPermission() async {
    final result = await Permission.manageExternalStorage.request();
    if (result.isGranted) await init();
  }

  /// Возврат в приложение: допроверяем права или подхватываем новые файлы.
  Future<void> onResume() async {
    if (status == LibraryStatus.needPermission) {
      await init();
    } else if (status == LibraryStatus.ready) {
      await refresh();
    }
  }

  Future<String> _rootPath() async {
    if (Platform.isAndroid) return '/storage/emulated/0/Music/Hydra';
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      return '$home\\Music\\Hydra';
    }
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/Hydra';
  }

  Future<void> _open() async {
    final root = await _rootPath();
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    final info = await Core.call('open', {
      'root': root,
      'data_dir': support.path,
      'cache_dir': cache.path,
    }) as Map<String, dynamic>;
    rootPath = info['root'] as String?;
    try {
      await Core.call('purge_trash');
    } on CoreException {
      // очистка корзины не критична
    }
    await refresh();
    unawaited(hydraNet.start()); // сеть не должна задерживать открытие библиотеки
  }

  /// Сканирует папку Hydra и обновляет список плейлистов.
  Future<void> refresh() async {
    if (scanning) return;
    scanning = true;
    notice = null;
    notifyListeners();
    try {
      try {
        await Core.call('scan');
      } on CoreException catch (e) {
        notice = e.message;
      }
      await reloadPlaylists();
      await _loadHeld();
      error = null;
      status = LibraryStatus.ready;
    } on CoreException catch (e) {
      error = e.message;
      status = LibraryStatus.error;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> _loadHeld() async {
    try {
      held = _maps(await Core.call('held_deletions')).map(HeldDeletion.fromJson).toList();
    } on CoreException {
      held = const [];
    }
  }

  /// Решение по пропавшему плейлисту: [delete] - удалить на всех устройствах,
  /// иначе оставить и получить файлы с других устройств при синхронизации.
  Future<void> resolveHeld(String playlistId, {required bool delete}) async {
    try {
      await Core.call('resolve_held', {'playlist_id': playlistId, 'delete': delete});
    } on CoreException catch (e) {
      notice = e.message;
    }
    await reloadPlaylists();
    await _loadHeld();
    tracksRevision++;
    notifyListeners();
  }

  List<Map<String, dynamic>> _maps(dynamic v) => (v as List).cast<Map<String, dynamic>>();

  Future<void> reloadPlaylists() async {
    final raw = await Core.call('playlists');
    playlists = _maps(raw).map(PlaylistInfo.fromJson).toList();
    notifyListeners();
  }

  Future<List<TrackInfo>> tracks(String playlistId) async {
    final raw = await Core.call('tracks', {'playlist_id': playlistId});
    return _maps(raw).map(TrackInfo.fromJson).toList();
  }

  Future<List<TrashItem>> trashItems() async {
    final raw = await Core.call('trash_items');
    return _maps(raw).map(TrashItem.fromJson).toList();
  }

  Future<void> createPlaylist(String name) async {
    await Core.call('create_playlist', {'name': name});
    await reloadPlaylists();
  }

  /// Переименовывает плейлист (папка на диске тоже переименовывается).
  Future<void> renamePlaylist(String playlistId, String name) async {
    await Core.call('rename_playlist', {'playlist_id': playlistId, 'name': name});
    await reloadPlaylists();
  }

  /// Удаляет пустой плейлист; ядро откажет, если в нём есть треки.
  Future<void> deletePlaylist(String playlistId) async {
    await Core.call('delete_playlist', {'playlist_id': playlistId});
    await reloadPlaylists();
  }

  Future<void> reorderPlaylist(String playlistId, int index) async {
    await Core.call('reorder_playlist', {'playlist_id': playlistId, 'index': index});
    await reloadPlaylists();
  }

  /// Меняет название трека. Возвращает true, если оно записано и в теги файла.
  Future<bool> renameTrack(String trackId, String title) async {
    final r = await Core.call('rename_track', {'track_id': trackId, 'title': title});
    return r is Map<String, dynamic> && r['tag_written'] == true;
  }

  /// Меняет название и исполнителя одной правкой (пустой исполнитель убирает его).
  /// Возвращает true, если значения записаны и в теги файла.
  Future<bool> editTrack(String trackId, String title, String artist) async {
    final r = await Core.call(
        'edit_track', {'track_id': trackId, 'title': title, 'artist': artist});
    tracksRevision++;
    notifyListeners();
    return r is Map<String, dynamic> && r['tag_written'] == true;
  }

  /// Заменяет обложку: картинка встраивается в сам аудиофайл.
  Future<void> setCover(String trackId, String imagePath) async {
    await Core.call('set_cover', {'track_id': trackId, 'image_path': imagePath});
    _covers.remove(trackId);
    tracksRevision++;
    notifyListeners();
  }

  /// Стирает всё из корзины. Возвращает число стёртых треков.
  Future<int> emptyTrash() async {
    final r = await Core.call('empty_trash');
    return (r as num).toInt();
  }

  Future<void> moveTrack(String trackId, String toPlaylistId) async {
    await Core.call('move_track', {'track_id': trackId, 'to_playlist_id': toPlaylistId});
    await reloadPlaylists();
  }

  Future<void> deleteTrack(String trackId) async {
    await Core.call('delete_track', {'track_id': trackId});
    await reloadPlaylists();
  }

  Future<void> restoreTrack(String trackId) async {
    await Core.call('restore_track', {'track_id': trackId});
    await reloadPlaylists();
  }

  /// Окончательное удаление из корзины (файл стирается, плейлисты не меняются).
  Future<void> purgeTrack(String trackId) async {
    await Core.call('purge_track', {'track_id': trackId});
  }

  Future<void> reorder(String trackId, int index) async {
    await Core.call('reorder', {'track_id': trackId, 'index': index});
  }

  /// Правило порядка треков плейлиста: manual, artist или title.
  Future<void> setPlaylistSort(String playlistId, String mode) async {
    await Core.call('set_playlist_sort', {'playlist_id': playlistId, 'mode': mode});
    await reloadPlaylists();
  }

  /// Расставляет треки плейлиста в указанном порядке (сортировка).
  Future<void> sortTracks(String playlistId, List<String> orderedIds) async {
    await Core.call('sort_tracks', {'playlist_id': playlistId, 'ids': orderedIds});
  }

  /// Путь к файлу обложки из тегов трека или null, если обложки нет.
  Future<String?> coverPath(String trackId) async {
    if (_covers.containsKey(trackId)) return _covers[trackId];
    String? path;
    try {
      final r = await Core.call('cover', {'track_id': trackId});
      if (r is Map<String, dynamic>) path = r['path'] as String?;
    } on CoreException {
      path = null;
    }
    _covers[trackId] = path;
    return path;
  }
}

/// Единая библиотека приложения.
final hydraLibrary = LibraryController();
