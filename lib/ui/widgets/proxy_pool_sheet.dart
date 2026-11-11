import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/proxy_node.dart';
import '../../state/app_state.dart';

/// 代理池弹层：列节点、显示延时、切换、刷新、手动添加。
Future<void> showProxyPoolSheet(BuildContext context, AppState app) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ProxyPoolSheet(app: app),
  );
}

class _ProxyPoolSheet extends StatelessWidget {
  const _ProxyPoolSheet({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final pool = app.proxyPool;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: ListenableBuilder(
          listenable: pool,
          builder: (context, _) {
            final theme = Theme.of(context);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('代理池', style: theme.textTheme.titleLarge),
                            Text(
                              _subtitle(pool.nodes.length, pool.fetchedAt),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新列表（每天自动一次）',
                        onPressed: pool.refreshing ? null : pool.refresh,
                        icon: pool.refreshing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                      ),
                      IconButton(
                        tooltip: '全部测速',
                        onPressed: pool.testing || pool.nodes.isEmpty
                            ? null
                            : pool.testAll,
                        icon: pool.testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.speed_rounded),
                      ),
                      IconButton(
                        tooltip: '手动添加',
                        onPressed: () => _addManual(context),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
                ),
                if (pool.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            pool.error,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _DirectTile(
                        selected: !app.proxy.enabled,
                        onTap: pool.selectDirect,
                      ),
                      for (final node in pool.nodes)
                        _NodeTile(node: node, app: app),
                      if (pool.nodes.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                          child: Text(
                            pool.refreshing
                                ? '正在获取代理列表…'
                                : '还没有代理节点。点右上角刷新从公开列表获取，'
                                      '或手动添加一个。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                              height: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  child: Text(
                    '公开免费代理稳定性有限，测速只代表 TCP 能连上；'
                    '选中后会立即替换「网络代理」里的配置。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _subtitle(int count, int fetchedAt) {
    if (fetchedAt <= 0) return '$count 个节点 · 还没拉取过';
    final at = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return '$count 个节点 · 上次更新 '
        '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}

class _DirectTile extends StatelessWidget {
  const _DirectTile({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      onTap: onTap,
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.link_off_rounded,
        color: selected ? theme.colorScheme.primary : null,
      ),
      title: const Text('直连（不使用代理）'),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node, required this.app});

  final ProxyNode node;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pool = app.proxyPool;
    // 选中状态直接读「网络代理」的当前配置：用户在那边关掉代理后，
    // 这里会立刻回到「直连」，两边不会各说各话。
    final selected =
        app.proxy.enabled &&
        app.proxy.type == node.type &&
        app.proxy.host == node.host &&
        app.proxy.port == node.port;
    return ListTile(
      dense: true,
      selected: selected,
      onTap: () => pool.select(node.id),
      leading: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          node.typeLabel,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(node.address, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: node.label.isEmpty
          ? null
          : Text(
              node.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _latencyText(node),
            style: theme.textTheme.labelSmall?.copyWith(
              color: _latencyColor(context, node),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '测速',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: () => pool.testNode(node.id),
            icon: const Icon(Icons.network_ping_rounded),
          ),
          if (node.manual)
            IconButton(
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => pool.remove(node.id),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
    );
  }

  static String _latencyText(ProxyNode node) {
    if (node.latencyMs >= 0) return '${node.latencyMs} ms';
    return node.testedAt > 0 ? '超时' : '未测';
  }

  static Color _latencyColor(BuildContext context, ProxyNode node) {
    final scheme = Theme.of(context).colorScheme;
    if (node.latencyMs < 0) return Theme.of(context).disabledColor;
    if (node.latencyMs < 300) return scheme.primary;
    if (node.latencyMs < 800) return scheme.tertiary;
    return scheme.error;
  }
}

Future<void> _addManual(BuildContext context) async {
  // 添加成功后 addManual 自己会 notify，列表随弹层一起刷新。
  await showDialog<bool>(
    context: context,
    builder: (ctx) => const _AddProxyDialog(),
  );
}

class _AddProxyDialog extends StatefulWidget {
  const _AddProxyDialog();

  @override
  State<_AddProxyDialog> createState() => _AddProxyDialogState();
}

class _AddProxyDialogState extends State<_AddProxyDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _label = TextEditingController();
  String _type = 'socks5';
  String _error = '';

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) {
      setState(() => _error = '请填写有效的地址和端口（1-65535）');
      return;
    }
    final app = AppScope.of(context);
    final ok = await app.proxyPool.addManual(
      type: _type,
      host: host,
      port: port,
      username: _username.text,
      password: _password.text,
      label: _label.text,
    );
    if (!mounted) return;
    if (!ok) {
      setState(
        () =>
            _error = app.proxyPool.error.isEmpty ? '添加失败' : app.proxyPool.error,
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动添加代理'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                ButtonSegment(value: 'http', label: Text('HTTP')),
              ],
              selected: {_type},
              onSelectionChanged: (value) =>
                  setState(() => _type = value.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: '1.2.3.4',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '1080',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '用户名（可选）'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: '密码（可选）'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: '备注（可选）'),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _error,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
