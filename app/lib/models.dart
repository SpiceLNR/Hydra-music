/// Временные модели для каркаса. На следующем этапе заменяются данными из Rust-ядра.
class Track {
  Track({required this.id, required this.title, required this.fileName, this.artist});

  final String id;
  String title;
  final String fileName;
  final String? artist;

  bool get isVideoContainer {
    final e = fileName.split('.').last.toLowerCase();
    return const ['mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v'].contains(e);
  }
}

class Playlist {
  Playlist({required this.id, required this.name, List<Track>? tracks})
      : tracks = tracks ?? [];

  final String id;
  String name;
  final List<Track> tracks;
}

class DeviceInfo {
  DeviceInfo({required this.name, required this.online, required this.lastSync});

  final String name;
  final bool online;
  final String lastSync;
}
