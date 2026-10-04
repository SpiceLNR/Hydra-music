import 'models.dart';

/// Демо-список устройств для экрана «Устройства» (реальный появится на этапе сети).
List<DeviceInfo> demoDevices() => [
      DeviceInfo(name: 'Этот телефон', online: true, lastSync: 'только что'),
      DeviceInfo(name: 'Рабочий ПК', online: false, lastSync: 'вчера, 21:40'),
    ];
