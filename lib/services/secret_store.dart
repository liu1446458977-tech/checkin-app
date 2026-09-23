/// API Key 的安全存储。
///
/// 优先走 Android Keystore（AES/GCM，密钥由系统密钥库托管、明文永不落盘），
/// 通过 MethodChannel 调用原生实现；若 Keystore 不可用（极老设备 / 异常），
/// 自动降级到应用私有 SharedPreferences，并在设置页明确告知用户。
/// 之所以不用 flutter_secure_storage 插件，是为了不动 AGP9 那套脆弱的构建配置。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecretStore {
  SecretStore._();

  static const MethodChannel _channel =
      MethodChannel('dev.yuzi.checkin_app/secure');

  /// 降级存储时的键前缀，避免和普通设置混淆
  static const String _fallbackPrefix = 'insecure_secret_';

  static bool? _keystoreOk;

  /// Android Keystore 是否可用（结果缓存）
  static Future<bool> keystoreAvailable() async {
    if (_keystoreOk != null) return _keystoreOk!;
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      _keystoreOk = ok ?? false;
    } catch (e) {
      debugPrint('[secret] Keystore 不可用，降级到私有存储: $e');
      _keystoreOk = false;
    }
    return _keystoreOk!;
  }

  /// 给设置页展示当前用的是哪种后端
  static Future<String> backendLabel() async =>
      (await keystoreAvailable()) ? '系统密钥库加密（Android Keystore）' : '应用私有存储（降级模式）';

  static Future<void> put(String key, String value) async {
    if (await keystoreAvailable()) {
      await _channel.invokeMethod<bool>(
          'put', <String, String>{'key': key, 'value': value});
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_fallbackPrefix$key', value);
  }

  static Future<String?> get(String key) async {
    if (await keystoreAvailable()) {
      try {
        return await _channel
            .invokeMethod<String>('get', <String, String>{'key': key});
      } catch (e) {
        debugPrint('[secret] 读取失败（按未设置处理）: $e');
        return null;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_fallbackPrefix$key');
  }

  static Future<void> delete(String key) async {
    if (await keystoreAvailable()) {
      await _channel
          .invokeMethod<bool>('delete', <String, String>{'key': key});
    }
    // 降级存储里的残留也一并清掉，避免切换后端后读到旧值
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_fallbackPrefix$key');
  }

  static Future<bool> has(String key) async {
    final v = await get(key);
    return v != null && v.trim().isNotEmpty;
  }
}
