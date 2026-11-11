import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/proxy_config.dart';
import '../../models/proxy_node.dart';
import '../local_store.dart';

/// 免费代理池：每天自动拉一次列表，支持手动刷新、手动添加、测速与切换。
///
/// 选中某个节点后走 [applyProxy]（即 `AppState.setProxy`），把单条节点套进
/// 现有的内置代理桥；取消选中就是直连。这样 HTTP / SOCKS5 的转发逻辑
/// 一份都不用改。
class ProxyPoolService extends ChangeNotifier {
  ProxyPoolService({required this.store, required this.applyProxy});

  static const sourceUrl =
      'https://raw.githubusercontent.com/watchttvv/free-proxy-list/refs/heads/main/proxy.txt';

  /// 自动刷新间隔：一天一次。
  static const refreshInterval = Duration(hours: 24);

  /// 自动节点上限：再多也测不过来，还会拖慢设置页首屏。
  static const maxNodes = 120;

  final LocalStore store;
  final Future<void> Function(ProxyConfig config) applyProxy;

  List<ProxyNode> nodes = const [];
  String selectedId = '';
  int fetchedAt = 0;
  bool refreshing = false;
  bool testing = false;
  String error = '';

  /// 存档是否已读入：读完之前不要用网络代理配置反推选中项。
  bool _loaded = false;

  bool get enabled => selectedId.isNotEmpty;

  ProxyNode? get selected => _find(selectedId);

  String get selectedLabel => selected?.address ?? '直连';

  /// 失败后的冷却：网络被墙时不要每次启动都连打好几次。
  static const retryCooldown = Duration(minutes: 10);

  int _lastAttempt = 0;

  /// 距离上次拉取是否已超过 24 小时（从没拉过也算到期）。
  bool get due {
    if (fetchedAt <= 0) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
    return DateTime.now().difference(last) >= refreshInterval;
  }

  void load() {
    _loaded = true;
    final raw = store.proxyPoolJson;
    if (raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final list = decoded['nodes'];
      if (list is List) {
        nodes = [
          for (final item in list)
            if (item is Map)
              ProxyNode.fromJson(Map<String, Object?>.from(item)),
        ].where((node) => node.valid).toList();
      }
      selectedId = (decoded['selected'] ?? '').toString();
      fetchedAt = decoded['fetchedAt'] is num
          ? (decoded['fetchedAt'] as num).toInt()
          : 0;
    } catch (_) {
      // 存档损坏就当空池，下次刷新会重建。
    }
  }

  /// 启动时把上次选中的节点重新套进代理桥（不重新落盘）。
  Future<void> restoreSelection() async {
    final node = selected;
    if (node == null) return;
    await applyProxy(_configOf(node));
  }

  Future<void> autoRefreshIfDue() async {
    if (!due || refreshing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAttempt > 0 && now - _lastAttempt < retryCooldown.inMilliseconds) {
      // 上一次刚失败过：冷却期内不再自动重试，手动刷新不受影响。
      return;
    }
    _lastAttempt = now;
    await refresh();
  }

  /// 拉取并解析列表。手动节点保留，自动节点整体替换；已测延时按地址复用。
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    error = '';
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(sourceUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'MisaTV-proxy-pool');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) break;
      }
      final parsed = parseProxyList(utf8.decode(bytes, allowMalformed: true));
      if (parsed.isEmpty) throw '列表里没有可用代理';
      final old = {for (final node in nodes) node.id: node};
      final manual = nodes.where((node) => node.manual).toList();
      final auto = <ProxyNode>[
        for (final node in parsed.take(maxNodes))
          node.copyWith(
            latencyMs: old[node.id]?.latencyMs ?? -1,
            testedAt: old[node.id]?.testedAt ?? 0,
          ),
      ];
      nodes = _dedupe([...manual, ...auto]);
      fetchedAt = DateTime.now().millisecondsSinceEpoch;
      // 选中的自动节点在新列表里消失了：退回直连，避免代理指向死地址。
      if (selectedId.isNotEmpty && selected == null) {
        selectedId = '';
        await applyProxy(const ProxyConfig(enabled: false));
      }
      await _save();
      AppLog.i('proxy', '代理池已更新：${nodes.length} 个节点');
    } catch (e) {
      error = '$e';
      AppLog.w('proxy', '代理池拉取失败：$e');
    } finally {
      client.close(force: true);
      refreshing = false;
      notifyListeners();
    }
  }

  /// 单个节点测速：TCP 握手耗时，超时/失败记为 -1。
  Future<void> testNode(String id) async {
    final node = _find(id);
    if (node == null) return;
    final latency = await _probe(node.host, node.port);
    _replace(
      node.id,
      node.copyWith(
        latencyMs: latency,
        testedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _save();
    notifyListeners();
  }

  /// 全部测速：4 路并发，避免一次开上百个 socket 把系统打满。
  Future<void> testAll() async {
    if (testing || nodes.isEmpty) return;
    testing = true;
    notifyListeners();
    try {
      var index = 0;
      Future<void> worker() async {
        while (index < nodes.length) {
          final node = nodes[index++];
          if (!node.valid) continue;
          final latency = await _probe(node.host, node.port);
          _replace(
            node.id,
            node.copyWith(
              latencyMs: latency,
              testedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          notifyListeners();
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      await _save();
    } finally {
      testing = false;
      notifyListeners();
    }
  }

  Future<void> select(String id) async {
    final node = _find(id);
    if (node == null) return;
    selectedId = node.id;
    await _save();
    await applyProxy(_configOf(node));
    notifyListeners();
  }

  /// 取消代理，恢复直连。
  Future<void> selectDirect() async {
    selectedId = '';
    await _save();
    await applyProxy(const ProxyConfig(enabled: false));
    notifyListeners();
  }

  Future<bool> addManual({
    required String type,
    required String host,
    required int port,
    String username = '',
    String password = '',
    String label = '',
  }) async {
    final node = ProxyNode(
      type: type == 'socks5' ? 'socks5' : 'http',
      host: host.trim(),
      port: port,
      username: username.trim(),
      password: password.trim(),
      label: label.trim(),
      manual: true,
    );
    if (!node.valid) return false;
    if (_find(node.id) != null) {
      error = '这个代理已经在列表里';
      notifyListeners();
      return false;
    }
    nodes = [node, ...nodes];
    await _save();
    notifyListeners();
    return true;
  }

  Future<void> remove(String id) async {
    nodes = nodes.where((node) => node.id != id).toList();
    if (selectedId == id) {
      selectedId = '';
      await applyProxy(const ProxyConfig(enabled: false));
    }
    await _save();
    notifyListeners();
  }

  /// 网络代理设置变化时同步池内选中状态：关掉代理就回到直连。
  ///
  /// 只改选中标记与存档，不再回调 `applyProxy`，避免和 [select] 互相递归。
  void syncFromConfig(ProxyConfig config) {
    if (!_loaded) return;
    final next = config.enabled ? _matchId(config) : '';
    if (next == selectedId) return;
    selectedId = next;
    unawaited(_save());
    notifyListeners();
  }

  String _matchId(ProxyConfig config) {
    final host = config.host.trim();
    for (final node in nodes) {
      if (node.type == config.type &&
          node.host == host &&
          node.port == config.port) {
        return node.id;
      }
    }
    return '';
  }

  Future<int> _probe(String host, int port) async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 6),
      );
      watch.stop();
      return watch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      socket?.destroy();
    }
  }

  ProxyConfig _configOf(ProxyNode node) => ProxyConfig(
    enabled: true,
    type: node.type,
    host: node.host,
    port: node.port,
    username: node.username,
    password: node.password,
  );

  ProxyNode? _find(String id) {
    if (id.isEmpty) return null;
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  void _replace(String id, ProxyNode node) {
    nodes = [
      for (final item in nodes)
        if (item.id == id) node else item,
    ];
  }

  List<ProxyNode> _dedupe(List<ProxyNode> input) {
    final seen = <String>{};
    final out = <ProxyNode>[];
    for (final node in input) {
      if (!node.valid || !seen.add(node.id)) continue;
      out.add(node);
    }
    return out;
  }

  Future<void> _save() => store.setProxyPoolJson(
    jsonEncode({
      'nodes': [for (final node in nodes) node.toJson()],
      'selected': selectedId,
      'fetchedAt': fetchedAt,
    }),
  );
}
