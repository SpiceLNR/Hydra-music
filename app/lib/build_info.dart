/// Версия приложения. Хронику изменений см. в CHANGELOG.md.
const String kVersion = '0.21.0';

const String _raw = String.fromEnvironment('HYDRA_BUILD', defaultValue: 'локальная');

/// Номер сборки (первые 7 знаков коммита). CI подставляет его через --dart-define,
/// по нему видно, какая именно версия установлена.
final String kBuild = _raw.length > 7 && !_raw.contains(' ') ? _raw.substring(0, 7) : _raw;
