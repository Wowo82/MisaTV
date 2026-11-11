/// 网盘手动 Cookie 输入的清洗与校验（纯函数，便于测试）。
library;

import 'dart:convert';

/// 各网盘视为「登录态」的 Cookie 名；命中任意一个即可。
const Map<String, List<String>> driveAuthCookieNames = {
  'quark': ['__puus', '__pus', '__puuk', '__pusd'],
  'uc': ['PUVID', '__puus', '__pus', 'drive_uc'],
  'baidu': ['BDUSS'],
};

/// Cookie 应该来自的域名，用于输入提示。
const Map<String, String> driveCookieDomains = {
  'quark': 'pan.quark.cn',
  'uc': 'drive.uc.cn',
  'baidu': 'pan.baidu.com',
};

const Set<String> _cookieAttributes = {
  'path',
  'domain',
  'expires',
  'max-age',
  'secure',
  'httponly',
  'samesite',
  'priority',
  'partitioned',
};

/// 把用户粘贴的内容清洗成 `a=b; c=d`。
///
/// 支持：
///   · 请求头里的原始 Cookie 串；
///   · 带 `Cookie:` 前缀的整段请求头；
///   · 从 cURL 里复制的 `-H 'Cookie: ...'`（只取 Cookie 这一段）；
///   · 每行一个 `a=b` 的列表；
///   · `Set-Cookie` 形式（会丢掉 Path / Domain / Expires 等属性）。
String normalizeDriveCookieInput(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  final prefix = text.toLowerCase().indexOf('cookie:');
  if (prefix >= 0) text = text.substring(prefix + 7).trim();
  // 浏览器插件 / DevTools 导出的 JSON：[{"name":"a_k","value":"…"}, …]
  final fromJson = _cookieFromJson(text);
  if (fromJson != null) return fromJson;
  // cURL 里 Cookie 值后面通常跟着引号，取到引号之前即可。
  final quote = text.indexOf(RegExp("['\"]"));
  if (quote >= 0) text = text.substring(0, quote);
  text = text
      .replaceAll('\\\r\n', ' ')
      .replaceAll('\\\n', ' ')
      .replaceAll('\r', '\n');
  final jar = <String, String>{};
  for (final part in text.split(RegExp(r'[;\n]'))) {
    final segment = part.trim();
    if (segment.isEmpty) continue;
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    final name = segment.substring(0, eq).trim();
    final value = segment.substring(eq + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (name.contains(RegExp(r'[=;,\s]'))) continue;
    if (_cookieAttributes.contains(name.toLowerCase())) continue;
    jar[name] = value;
  }
  return jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}

/// 解析 `[{"name":…,"value":…}]` 形式的 Cookie 导出；不是 JSON 返回 null。
String? _cookieFromJson(String text) {
  if (!text.startsWith('[') && !text.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(text);
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['cookies'] is List
              ? decoded['cookies'] as List
              : null);
    if (list == null) return null;
    final jar = <String, String>{};
    for (final item in list) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString().trim();
      final value = (item['value'] ?? '').toString();
      if (name.isEmpty || value.isEmpty) continue;
      if (_cookieAttributes.contains(name.toLowerCase())) continue;
      jar[name] = value;
    }
    if (jar.isEmpty) return null;
    return jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  } catch (_) {
    return null;
  }
}

/// 已清洗 Cookie 里出现的字段名。
Set<String> driveCookieNames(String cookie) {
  final names = <String>{};
  for (final part in cookie.split(';')) {
    final segment = part.trim();
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    names.add(segment.substring(0, eq).trim());
  }
  return names;
}

/// 是否包含该网盘的登录态字段（只做粗筛，最终以在线校验为准）。
bool driveCookieHasAuth(String provider, String cookie) {
  final required = driveAuthCookieNames[provider] ?? const [];
  if (required.isEmpty) return cookie.trim().isNotEmpty;
  final names = driveCookieNames(cookie);
  return required.any(names.contains);
}

/// 缺少登录态字段时给用户看的提示。
String driveCookieMissingHint(String provider) {
  final names = driveAuthCookieNames[provider] ?? const [];
  if (names.isEmpty) return 'Cookie 为空';
  return 'Cookie 里没有找到登录态字段（${names.join(' / ')}），'
      '请确认复制的是已登录状态下的完整 Cookie';
}
