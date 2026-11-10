/// 代理池节点：从免费代理列表拉回来的单条代理。
///
/// 只保留 host / port / 协议这些能直接喂给 [ProxyConfig] 的字段；
/// 地区、ISP 之类的描述放在 [label] 里只做展示，不参与逻辑。
class ProxyNode {
  const ProxyNode({
    required this.type,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.label = '',
    this.manual = false,
    this.latencyMs = -1,
    this.testedAt = 0,
  });

  /// `http` 或 `socks5`（`https://` 的代理按 http 处理）。
  final String type;
  final String host;
  final int port;
  final String username;
  final String password;

  /// 列表里附带的地区 / 机房描述，或手动添加时填的备注。
  final String label;

  /// 是否手动添加：自动刷新时不会覆盖或删除手动节点。
  final bool manual;

  /// 最近一次 TCP 连接耗时（毫秒）；-1 表示还没测过或超时。
  final int latencyMs;
  final int testedAt;

  String get id => '$type://$host:$port';

  bool get isSocks5 => type == 'socks5';

  String get typeLabel => isSocks5 ? 'SOCKS5' : 'HTTP';

  String get address => '$host:$port';

  bool get valid => host.trim().isNotEmpty && port > 0 && port <= 65535;

  bool get reachable => latencyMs >= 0;

  ProxyNode copyWith({
    String? type,
    String? host,
    int? port,
    String? username,
    String? password,
    String? label,
    bool? manual,
    int? latencyMs,
    int? testedAt,
  }) {
    return ProxyNode(
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      label: label ?? this.label,
      manual: manual ?? this.manual,
      latencyMs: latencyMs ?? this.latencyMs,
      testedAt: testedAt ?? this.testedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'host': host,
    'port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
    if (label.isNotEmpty) 'label': label,
    if (manual) 'manual': true,
    if (latencyMs >= 0) 'latencyMs': latencyMs,
    if (testedAt > 0) 'testedAt': testedAt,
  };

  factory ProxyNode.fromJson(Map<String, Object?> json) {
    final rawPort = json['port'];
    final port = rawPort is num
        ? rawPort.toInt()
        : int.tryParse(rawPort?.toString() ?? '') ?? 0;
    final type = (json['type'] ?? 'http').toString().toLowerCase();
    return ProxyNode(
      type: type == 'socks5' ? 'socks5' : 'http',
      host: (json['host'] ?? '').toString().trim(),
      port: port,
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      manual: json['manual'] == true,
      latencyMs: json['latencyMs'] is num
          ? (json['latencyMs'] as num).toInt()
          : -1,
      testedAt: json['testedAt'] is num ? (json['testedAt'] as num).toInt() : 0,
    );
  }
}

/// `socks5://1.2.3.4:1080`、`http://1.2.3.4:8080` 这类行。
final RegExp _nodeLine = RegExp(
  r'^(socks5|socks4|https?|socks)://([^\s/]+)',
  caseSensitive: false,
);

/// 列表里的脱敏占位：`27.77.X.92` 这种地址连不通，直接丢掉。
final RegExp _masked = RegExp(r'[xX]');

/// 行尾的「入库时间：11-10 14:26」不是有用信息，去掉只留地区 / 机房。
final RegExp _ingestTime = RegExp(r'入库时间[：:]\s*\S+\s*');

/// 解析 proxy.txt。
///
/// 支持 `socks5://`、`http://`、`https://` 三种前缀（https 代理归为 http），
/// 跳过注释、脱敏地址（host 含 `X`）和端口非法的行；同一地址只保留第一条。
List<ProxyNode> parseProxyList(String text) {
  final seen = <String>{};
  final out = <ProxyNode>[];
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = _nodeLine.firstMatch(line);
    if (match == null) continue;
    final scheme = match.group(1)!.toLowerCase();
    final hostPort = match.group(2)!.trim();
    final split = hostPort.lastIndexOf(':');
    if (split <= 0) continue;
    final host = hostPort.substring(0, split).trim();
    final port = int.tryParse(hostPort.substring(split + 1).trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) continue;
    if (_masked.hasMatch(host)) continue;
    final type = scheme == 'socks5' ? 'socks5' : 'http';
    final id = '$type://$host:$port';
    if (!seen.add(id)) continue;
    final label = line
        .substring(match.end)
        .replaceFirst(_ingestTime, '')
        .trim();
    out.add(
      ProxyNode(
        type: type,
        host: host,
        port: port,
        label: label.length > 60 ? label.substring(0, 60) : label,
      ),
    );
  }
  return out;
}
