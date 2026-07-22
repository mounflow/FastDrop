import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple value object holding session state loaded from storage.
///
/// Retained for compatibility with screens that consume a single active
/// session (transfer_screen, history_screen). New code should use [Device]
/// and [DeviceStore] directly.
@immutable
class SessionData {
  const SessionData({
    required this.sessionId,
    required this.accessToken,
    required this.serverBaseUrl,
    this.serverName,
    this.deviceName,
    this.expiresAt,
  });

  final String sessionId;
  final String accessToken;
  final String serverBaseUrl;
  final String? serverName;
  final String? deviceName;
  final DateTime? expiresAt;

  bool get isExpired {
    if (expiresAt == null) return false;
    return expiresAt!.isBefore(DateTime.now());
  }

  /// Returns true if the session exists and has not expired.
  bool get isSessionValid => !isExpired;
}

/// A paired PC persisted on the phone.
///
/// Multiple devices can be stored at once (see [DeviceStore]). Only one
/// device is "active" (connected via WebSocket) at a time — the others are
/// kept on disk so the user can switch between PCs without re-pairing.
@immutable
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.serverBaseUrl,
    required this.sessionId,
    required this.accessToken,
    required this.lastSeen,
    this.expiresAt,
  });

  /// Stable unique key. Uses [serverBaseUrl] so re-pairing the same PC
  /// overwrites the previous entry instead of producing duplicates.
  final String id;
  final String name;
  final String serverBaseUrl;
  final String sessionId;
  final String accessToken;
  final DateTime lastSeen;
  final DateTime? expiresAt;

  bool get isExpired {
    if (expiresAt == null) return false;
    return expiresAt!.isBefore(DateTime.now());
  }

  SessionData toSessionData() => SessionData(
        sessionId: sessionId,
        accessToken: accessToken,
        serverBaseUrl: serverBaseUrl,
        serverName: name,
        deviceName: null,
        expiresAt: expiresAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serverBaseUrl': serverBaseUrl,
        'sessionId': sessionId,
        'accessToken': accessToken,
        'lastSeen': lastSeen.toIso8601String(),
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      };

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'PC',
      serverBaseUrl: json['serverBaseUrl'] as String,
      sessionId: json['sessionId'] as String,
      accessToken: json['accessToken'] as String,
      lastSeen:
          DateTime.tryParse(json['lastSeen'] as String? ?? '') ??
              DateTime.now(),
      expiresAt: (json['expiresAt'] as String?) == null
          ? null
          : DateTime.tryParse(json['expiresAt'] as String),
    );
  }

  Device copyWith({
    String? name,
    DateTime? lastSeen,
    DateTime? expiresAt,
    String? sessionId,
    String? accessToken,
  }) {
    return Device(
      id: id,
      name: name ?? this.name,
      serverBaseUrl: serverBaseUrl,
      sessionId: sessionId ?? this.sessionId,
      accessToken: accessToken ?? this.accessToken,
      lastSeen: lastSeen ?? this.lastSeen,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

/// Persists the list of paired devices in [SharedPreferences] as a single
/// JSON array under `fastdrop.devices`.
class DeviceStore {
  DeviceStore();

  static const _key = 'fastdrop.devices';

  Future<List<Device>> loadDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Device.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Inserts or updates (matched by [Device.id]).
  Future<void> saveDevice(Device device) async {
    final devices = await loadDevices();
    final idx = devices.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      devices[idx] = device;
    } else {
      devices.add(device);
    }
    await _write(devices);
  }

  Future<void> removeDevice(String id) async {
    final devices = await loadDevices();
    devices.removeWhere((d) => d.id == id);
    await _write(devices);
  }

  /// Returns the most-recently-used device, or null if none.
  Future<Device?> getActiveDevice() async {
    final devices = await loadDevices();
    if (devices.isEmpty) return null;
    devices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return devices.first;
  }

  Future<void> _write(List<Device> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
  }
}

/// Deprecated thin wrapper around [DeviceStore] that exposes the legacy
/// single-session API. Screens still using `SessionStore()` (transfer,
/// history) keep working — they transparently operate on the active device.
@Deprecated('Use DeviceStore directly.')
class SessionStore {
  SessionStore();

  final DeviceStore _delegate = DeviceStore();

  Future<SessionData?> loadSession() async {
    final device = await _delegate.getActiveDevice();
    if (device == null) return null;
    if (device.isExpired) {
      await _delegate.removeDevice(device.id);
      return null;
    }
    return device.toSessionData();
  }

  Future<void> clearSession() async {
    final device = await _delegate.getActiveDevice();
    if (device != null) {
      await _delegate.removeDevice(device.id);
    }
  }
}
