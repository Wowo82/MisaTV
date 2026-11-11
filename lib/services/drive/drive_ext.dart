import 'dart:convert';

import '../relay/local_relay.dart';

/// 把已登录网盘 Cookie 并入蜘蛛 ext（对齐 TVBox 生态：provider 名即 ext 键名）。
/// ext 为空或非 JSON 对象时原样返回（避免改变源作者预期的格式）。
///
/// 同时把 ext 里的 `Cloud-drive` 相对路径归一为本地 `/file` 地址：fty 系 jar
/// 只认 `http…` 或 `./…` 两种形态，裸相对路径不会 fetch（cookie 被置空）。
String enrichSpiderExt(String ext, Map<String, String> tokens) {
  final trimmed = ext.trim();
  if (trimmed.isEmpty) return ext;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return ext;
    var changed = false;
    for (final entry in tokens.entries) {
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      decoded[entry.key] = value;
      changed = true;
    }
    if (_normalizeCloudDrive(decoded)) changed = true;
    return changed ? jsonEncode(decoded) : ext;
  } catch (_) {
    return ext;
  }
}

/// `Cloud-drive: "tvfan/Cloud-drive.txt"` → `http://127.0.0.1:<relay>/file/tvfan/Cloud-drive.txt`。
bool _normalizeCloudDrive(Map decoded) {
  final raw = '${decoded['Cloud-drive'] ?? ''}'.trim();
  if (raw.isEmpty ||
      RegExp(r'^https?://', caseSensitive: false).hasMatch(raw)) {
    return false;
  }
  if (!LocalRelay.instance.running) return false;
  final rel = raw.replaceFirst(RegExp(r'^\.{0,2}/+'), '');
  if (rel.isEmpty) return false;
  decoded['Cloud-drive'] = '${LocalRelay.instance.baseUrl}/file/$rel';
  return true;
}
