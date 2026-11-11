/// 网盘手动 Cookie 输入的清洗与校验（纯函数，便于测试）。
library;

/// 各网盘视为「登录态」的 Cookie 名；命中任意一个即可。
const Map<String, List<String>> driveAuthCookieNames = {
  'quark': ['__puus', '__pus', '__puuk', '__pusd'],
  'uc': ['PUVID', '__puus', '__pus', 'drive_uc'],
  'baidu': ['BDUSS'],
  // 移动云盘（139）：a_k 是设备标识，skey / auth_token 才是登录态。
  'mobile': ['a_k', 'skey', 'auth_token'],
};

/// Cookie 应该来自的域名，用于输入提示。
const Map<String, String> driveCookieDomains = {
  'quark': 'pan.quark.cn',
  'uc': 'drive.uc.cn',
  'baidu': 'pan.baidu.com',
  'mobile': 'yun.139.com',
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
  if (prefix >= 0) text = text.substring(prefix + 7);
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
