/// Represents a device known to the FastDrop network (PC or phone).
///
/// Matches the Go backend's `devices` table (§22).
class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.appVersion,
  });

  /// Unique device identifier (assigned by the backend).
  final String deviceId;

  /// Human-readable device name.
  final String deviceName;

  /// Platform identifier, e.g. `"windows"` or `"android"`.
  final String platform;

  /// Application version string (optional).
  final String? appVersion;

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      platform: json['platform'] as String,
      appVersion: json['appVersion'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'platform': platform,
      if (appVersion != null) 'appVersion': appVersion,
    };
  }

  @override
  String toString() => 'DeviceInfo($deviceName, $platform)';
}
