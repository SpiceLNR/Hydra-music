import 'models.dart';

/// Демо-данные для каркаса интерфейса.
List<Playlist> demoPlaylists() => [
      Playlist(id: 'rock', name: 'Rock', tracks: [
        Track(id: 't1', title: 'Thunder Road', fileName: 'thunder_road.flac', artist: 'Demo'),
        Track(id: 't2', title: 'Night Drive', fileName: 'night_drive.mp3', artist: 'Demo'),
      ]),
      Playlist(id: 'jazz', name: 'Jazz', tracks: [
        Track(id: 't3', title: 'Blue Hour', fileName: 'blue_hour.m4a', artist: 'Demo'),
        Track(id: 't4', title: 'Live Session', fileName: 'live_session.mp4', artist: 'Demo'),
      ]),
      Playlist(id: 'misc', name: 'Misc'),
    ];

List<DeviceInfo> demoDevices() => [
      DeviceInfo(name: 'Этот телефон', online: true, lastSync: 'только что'),
      DeviceInfo(name: 'Рабочий ПК', online: false, lastSync: 'вчера, 21:40'),
    ];
