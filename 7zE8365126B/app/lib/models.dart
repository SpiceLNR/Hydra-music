// Модели данных, приходящих из Rust-ядра (JSON), и временная модель устройства.

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

/// Устройство в списке «Устройства». Пока демо-данные; настоящие приходят на этапе сети.
class DeviceInfo {
  DeviceInfo({required this.name, required this.online, required this.lastSync});

  final String name;
  final bool online;
  final String lastSync;
}
