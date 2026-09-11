/// Per-install device identity sent to subscription panels (Remnawave, Marzban)
/// that enforce a device limit. Without these headers such panels answer with a
/// stub "App not supported" server instead of the real list.
class DeviceIdentity {
  const DeviceIdentity({required this.hwid, required this.os, required this.osVersion, required this.model});

  /// Stable random id generated once per installation.
  final String hwid;
  final String os;
  final String osVersion;
  final String model;

  static const String hwidHeader = 'x-hwid';
  static const String osHeader = 'x-device-os';
  static const String osVersionHeader = 'x-ver-os';
  static const String modelHeader = 'x-device-model';

  Map<String, String> toSubscriptionHeaders() => {
    hwidHeader: hwid,
    osHeader: os,
    osVersionHeader: osVersion,
    modelHeader: model,
  };

  static String osNameFor(String operatingSystem) => switch (operatingSystem) {
    'android' => 'Android',
    'ios' => 'iOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'macOS',
    _ => operatingSystem,
  };
}
