import 'dart:convert';

import '../relay/local_relay.dart';

/// 把已登录网盘 Cookie 并入蜘蛛 ext（对齐 TVBox 生态：provider 名即 ext 键名）。
///
/// ext 为空但有网盘凭据时，构造一个最小配置：把 tokens 直接放进去，并补一个
/// 指向本地 `tvfan/Cloud-drive.txt` 的 `Cloud-drive`。否则 `pan139` 这类
/// 蜘蛛的 Config 是空的，永远报「请先在配置中心登录移动云盘」。
/// ext 非 JSON 对象时原样返回（避免改变源作者预期的格式）。
String enrichSpiderExt(String ext, Map<String, String> tokens) {
  final trimmed = ext.trim();
  final usable = {
    for (final entry in tokens.entries)
      if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
  };
  if (trimmed.isEmpty) {
    if (usable.isEmpty) return ext;
    final decoded = <String, dynamic>{...usable};
    if (LocalRelay.instance.running) {
      decoded['Cloud-drive'] =
          '${LocalRelay.instance.baseUrl}/file/tvfan/Cloud-drive.txt';
    }
    return jsonEncode(decoded);
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return ext;
    var changed = false;
    for (final entry in usable.entries) {
      decoded[entry.key] = entry.value;
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
