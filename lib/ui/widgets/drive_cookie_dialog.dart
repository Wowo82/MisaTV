import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/logging/app_log.dart';
import '../../services/drive/baidu_session.dart';
import '../../services/drive/drive_cookie_input.dart';
import '../../services/drive/drive_login_types.dart';
import '../../services/drive/quark_session.dart';
import '../../services/drive/uc_session.dart';

/// 手动粘贴网盘 Cookie 的输入框；保存成功后返回 true。
Future<bool?> showDriveCookieDialog(BuildContext context, String provider) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _DriveCookieDialog(provider: provider),
  );
}

class _DriveCookieDialog extends StatefulWidget {
  const _DriveCookieDialog({required this.provider});
  final String provider;

  @override
  State<_DriveCookieDialog> createState() => _DriveCookieDialogState();
}

class _DriveCookieDialogState extends State<_DriveCookieDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  String _error = '';

  String get _provider => widget.provider;
  String get _name => driveProviderNames[_provider] ?? _provider;
  String get _domain => driveCookieDomains[_provider] ?? '网盘官网';
  String get _authFields =>
      (driveAuthCookieNames[_provider] ?? const []).join(' / ');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 一鍵從剪貼板取全文：手動複製長 Cookie 很容易只選到其中一段。
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _controller.text = text;
    setState(() => _error = '');
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    final cookie = normalizeDriveCookieInput(_controller.text);
    if (cookie.isEmpty) {
      setState(() => _error = '请粘贴 Cookie，格式形如 a=b; c=d');
      return;
    }
    if (!driveCookieHasAuth(_provider, cookie)) {
      setState(() => _error = driveCookieMissingHint(_provider));
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final result = switch (_provider) {
        'quark' => await refreshQuarkSession(cookie),
        'uc' => await refreshUcSession(cookie),
        'baidu' => await refreshBaiduSession(cookie),
        // 移动云盘没有公开的会话刷新接口：不联网校验，按原样保存，
        // 免得拿它的 Cookie 去问百度接口、必然判成失效。
        'mobile' => const QuarkSessionResult(
          cookie: '',
          changed: false,
          valid: null,
        ),
        _ => await refreshBaiduSession(cookie),
      };
      if (!mounted) return;
      if (result.valid == false) {
        setState(() {
          _saving = false;
          _error = 'Cookie 未通过登录校验（可能是访客态或已过期），请重新复制';
        });
        return;
      }
      if (result.valid == null) {
        AppLog.w('drive', '手动 Cookie 无法联网校验 provider=$_provider，按原样保存');
      }
      // 校验响应可能补发了新的 __puus，优先保存刷新后的 Cookie。
      final finalCookie = result.cookie.trim().isEmpty
          ? cookie
          : result.cookie.trim();
      await app.saveDriveAccount(_provider, finalCookie);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
      height: 1.6,
    );
    return AlertDialog(
      title: Text('手动输入 Cookie · $_name'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '在浏览器登录 $_domain 后，打开开发者工具（F12）→ 应用 / 存储 → '
                'Cookies，复制该域名下的全部 Cookie；也可以从「网络」请求头里'
                '复制 Cookie 一段。粘贴时支持 a=b; c=d、每行一个 a=b 或带 Cookie: 前缀。',
                style: hint,
              ),
              const SizedBox(height: 8),
              Text(
                _authFields.isEmpty
                    ? 'Cookie 等同于账号密码，只会保存在本机。'
                    : '必须包含登录态字段：$_authFields；'
                          'Cookie 等同于账号密码，只会保存在本机。',
                style: hint,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 5,
                maxLines: 10,
                enabled: !_saving,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
                decoration: InputDecoration(
                  hintText: '例如：__puus=xxxx; __pus=yyyy; ...',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _error.isEmpty ? null : _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _saving ? null : _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  label: const Text('从剪贴板粘贴'),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _provider == 'mobile'
                          ? '移动云盘只做本地格式校验，保存后会同步给订阅里的蜘蛛源。'
                          : '保存前会联网校验登录态；校验通过后 Cookie 会同步给订阅里的蜘蛛源。',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.50,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('校验并保存'),
        ),
      ],
    );
  }
}
