import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tunnel_config.dart';

typedef RunState = ({bool running, int pid, String url});

class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  static const _kConfig = 'config_v1';
  static const _kToken = 'tunnel_token';
  static const _kRunning = 'tunnel_is_running';
  static const _kPid = 'tunnel_pid';
  static const _kUrl = 'tunnel_url';
  static const _kLog = 'tunnel_log_lines';

  static Future<SettingsStore> open() async =>
      SettingsStore(await SharedPreferences.getInstance());

  // ---- config ----
  TunnelConfig loadConfig() {
    final raw = _prefs.getString(_kConfig);
    if (raw == null) return const TunnelConfig();
    try {
      return TunnelConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const TunnelConfig();
    }
  }

  Future<void> saveConfig(TunnelConfig c) =>
      _prefs.setString(_kConfig, jsonEncode(c.toJson()));

  // ---- token (encrypted) ----
  Future<String> readToken() async {
    try {
      return await _secure.read(key: _kToken) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> writeToken(String token) async {
    try {
      await _secure.write(key: _kToken, value: token);
    } catch (_) {}
  }

  Future<void> deleteToken() async {
    try {
      await _secure.delete(key: _kToken);
    } catch (_) {}
  }

  // ---- run state ----
  RunState loadRunState() => (
        running: _prefs.getBool(_kRunning) ?? false,
        pid: _prefs.getInt(_kPid) ?? -1,
        url: _prefs.getString(_kUrl) ?? '',
      );

  Future<void> saveRunState({
    required bool running,
    int? pid,
    String url = '',
  }) async {
    await _prefs.setBool(_kRunning, running);
    await _prefs.setInt(_kPid, pid ?? -1);
    await _prefs.setString(_kUrl, url);
  }

  Future<void> clearRunState() async {
    await _prefs.remove(_kPid);
    await _prefs.remove(_kUrl);
    await _prefs.setBool(_kRunning, false);
  }

  // ---- log tail ----
  List<String> loadLog() => _prefs.getStringList(_kLog) ?? const [];
  Future<void> saveLog(List<String> lines) => _prefs.setStringList(_kLog, lines);
}
