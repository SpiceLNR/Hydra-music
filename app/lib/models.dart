// Модели данных, приходящих из Rust-ядра (JSON), и временная модель устройства.

/// Массовое удаление вне приложения, ждущее решения пользователя.
class HeldDeletion {
  HeldDeletion({
    required this.playlistId,
    required this.name,
    required this.count,
    required this.folderMissing,
  });

  final String playlistId;
  final String name;
  final int count;

  /// Пропала папка плейлиста целиком (иначе пропали только файлы).
  final bool folderMissing;

  factory HeldDeletion.fromJson(Map<String, dynamic> j) => HeldDeletion(
        playlistId: j['playlist_id'] as String,
        name: j['name'] as String,
        count: (j['count'] as num).toInt(),
        folderMissing: j['folder_missing'] as bool,
      );
}

class PlaylistInfo {
  PlaylistInfo({
    required this.id,
    required this.name,
    required this.trackCount,
    this.sortMode = 'manual',
  });

  final String id;
  final String name;
  final int trackCount;

  /// Правило порядка треков: manual (как попало), artist, title.
  final String sortMode;

  factory PlaylistInfo.fromJson(Map<String, dynamic> j) => PlaylistInfo(
        id: j['playlist_id'] as String,
        name: j['name'] as String,
        trackCount: (j['track_count'] as num).toInt(),
        sortMode: (j['sort_mode'] as String?) ?? 'manual',
      );
}

class TrackInfo {
  TrackInfo({
    required this.id,
    required this.playlistId,
    required this.title,
    required this.fileName,
    required this.path,
    required this.isVideo,
    this.artist,
  });

  final String id;
  final String playlistId;
  final String title;
  final String? artist;
  final String fileName;
  final String path;
  final bool isVideo;

  /// Копия с новым названием и/или исполнителем (после правки в окне плеера).
  TrackInfo copyWith({String? title, String? artist, bool clearArtist = false}) => TrackInfo(
        id: id,
        playlistId: playlistId,
        title: title ?? this.title,
        artist: clearArtist ? null : (artist ?? this.artist),
        fileName: fileName,
        path: path,
        isVideo: isVideo,
      );

  factory TrackInfo.fromJson(Map<String, dynamic> j) => TrackInfo(
        id: j['track_id'] as String,
        playlistId: j['playlist_id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String?,
        fileName: j['file_name'] as String,
        path: j['path'] as String,
        isVideo: j['is_video'] as bool,
      );
}

class TrashItem {
  TrashItem({required this.id, required this.title, required this.fileName, required this.deletedMs});

  final String id;
  final String title;
  final String fileName;
  final int deletedMs;

  factory TrashItem.fromJson(Map<String, dynamic> j) => TrashItem(
        id: j['track_id'] as String,
        title: j['title'] as String,
        fileName: j['file_name'] as String,
        deletedMs: (j['deleted_ms'] as num).toInt(),
      );
}

/// Устройство из «семьи» (список на экране «Устройства»).
class DeviceInfo {
  DeviceInfo({
    required this.id,
    required this.name,
    required this.online,
    required this.lastSyncMs,
    this.internet = false,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: j['device_id'] as String,
        name: j['name'] as String,
        online: j['online'] as bool,
        lastSyncMs: (j['last_sync_ms'] as num).toInt(),
        internet: (j['internet'] as bool?) ?? false,
      );

  final String id;
  final String name;
  final bool online;
  final int lastSyncMs;

  /// Известен адрес для связи через интернет.
  final bool internet;

  /// Когда последний раз синхронизировались, в понятном виде.
  String get lastSyncLabel {
    if (lastSyncMs <= 0) return 'ещё не синхронизировались';
    final t = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}
