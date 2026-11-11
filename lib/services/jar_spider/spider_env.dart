import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 把已绑定的网盘凭据同步成 jar 系蜘蛛**期望的落盘格式**。
///
/// 为什么必须有这一层：加固壳 / jar 系蜘蛛（wex、AiNew* 等家族）**不读** ext 里的
/// cookie，而是各自去固定位置取。桌面端不替它们写文件就会：
///   · 详情里拿不到网盘资源（播放列表为空）；
///   · `playerContent` 直接回「还没有配置夸克 Cookie，请先去配置中心登录夸克」。
/// （2026-10-27 实测：写齐后同一次调用立刻返回可播的取流地址。）
///
/// 四条通道（对齐旧版 Electron 项目对同名 jar 的反编译实证）：
///  1. **wex 文件通道**：`<spiderCache>/files/TV/.quarkcookie`（裸 cookie 串）、`.ucpancookie`；
///  2. **wex SharedPreferences 种子**：`<spiderCache>/shared_prefs/seed.txt`，
///     行格式 `表名 \t 键 \t 值`（内置 prefs-shim 读取；表 `NewWexFnw_preferences`）；
///  3. **Pizazz/太太太硬了 通道**：`<java.io.tmpdir>/tvbox-ext/TVBox/{quark_cookie,uc_cookie,baidu}.txt`，
///     JSON `{"cookie":…}`（quark / uc 另补 `nickname` / `member_type` 占位，否则该族判「未登录」）；
///  4. **fty Cloud-drive 通道**：`<数据目录>/tvfan/Cloud-drive.txt`（或源 ext 里
///     `Cloud-drive` 指向的 JSON 文件），键 `quarkCookie` / `ucCookie`——fty 系在 init 时读它。
///
/// 每次调用都重写（不再按签名跳过）：jar 可能自行清掉/改写这些文件，跳过写盘会让
/// 「已登录」在常驻进程里变成「未配置」。
class SpiderEnv {
  SpiderEnv._();

  /// wex 文件通道：provider → 文件名（裸 cookie）。
  static const _wexFiles = <String, String>{
    'quark': '.quarkcookie',
    'uc': '.ucpancookie',
  };

  /// wex SharedPreferences 键：provider → `Wex_*` 键名。
  static const _wexPrefKeys = <String, String>{
    'quark': 'Wex_quark_cookie',
    'uc': 'Wex_ucpan_cookie',
    'baidu': 'Wex_baidu_cookie',
  };

  static const _wexPrefsName = 'NewWexFnw_preferences';

  /// Pizazz 通道：provider → 文件名。
  static const _pizazzFiles = <String, String>{
    'quark': 'quark_cookie.txt',
    'uc': 'uc_cookie.txt',
    'baidu': 'baidu.txt',
  };

  /// 同步一次（文件都很小，每次调用都重写；内容未变时写入是幂等的）。
  ///
  /// [spiderCacheDir] = 传给 JVM 的 `-Dtvbox.spiderCacheDir`；
  /// [cookies] = provider → cookie（小写键，通常来自设置里的网盘账户）；
  /// [seed] = 额外 prefs 键（如 UC TV Token 的 `Wex_ucpan_token` / `Wex_ucpan_device_id`）；
  /// [dataDir] = 应用数据目录（Cloud-drive 默认落点 `<dataDir>/tvfan/Cloud-drive.txt`）；
  /// [ext] = 当前站点 ext（用于定位它声明的 `Cloud-drive` 文件）。
  static Future<void> sync({
    required String spiderCacheDir,
    required Map<String, String> cookies,
    Map<String, String> seed = const {},
    String? tmpDir,
    String? dataDir,
    String ext = '',
  }) async {
    final normalized = <String, String>{};
    cookies.forEach((key, value) {
      final k = key.trim().toLowerCase();
      final v = value.trim();
      if (k.isNotEmpty && v.isNotEmpty) normalized[k] = v;
    });
    final extra = <String, String>{};
    seed.forEach((key, value) {
      final k = key.trim();
      final v = value.trim();
      if (k.isNotEmpty && v.isNotEmpty) extra[k] = v;
    });

    // 各通道互相隔离：某一个文件被 JVM 占用时，不能让其余通道也不写。
    await _guard(() => _syncWexFiles(spiderCacheDir, normalized));
    await _guard(() => _syncWexSeed(spiderCacheDir, normalized, extra));
    await _guard(
      () => _syncPizazzFiles(tmpDir ?? Directory.systemTemp.path, normalized),
    );
    if (dataDir != null && dataDir.trim().isNotEmpty) {
      await _guard(() => _syncCloudDrive(dataDir, normalized, ext));
    }
  }

  static Future<void> _guard(Future<void> Function() task) async {
    try {
      await task();
    } catch (_) {
      // 单个通道失败不阻断其它通道：下次调用会再试
    }
  }

  /// 通道 1：`<spiderCache>/files/TV/.quarkcookie`（裸 cookie，jar 里直接 trim 当 Cookie 用）。
  static Future<void> _syncWexFiles(
    String spiderCacheDir,
    Map<String, String> cookies,
  ) async {
    final dir = Directory(p.join(spiderCacheDir, 'files', 'TV'));
    _wexFiles.forEach((provider, name) {
      final file = File(p.join(dir.path, name));
      final value = cookies[provider] ?? '';
      if (value.isEmpty) {
        _delete(file);
        return;
      }
      dir.createSync(recursive: true);
      file.writeAsStringSync(value, flush: true);
    });
  }

  /// 通道 2：SharedPreferences 种子（内置 prefs-shim 读 `<base>/shared_prefs/seed.txt`）。
  static Future<void> _syncWexSeed(
    String spiderCacheDir,
    Map<String, String> cookies,
    Map<String, String> seed,
  ) async {
    final file = File(p.join(spiderCacheDir, 'shared_prefs', 'seed.txt'));
    final lines = <String>[
      for (final entry in _wexPrefKeys.entries)
        if ((cookies[entry.key] ?? '').isNotEmpty)
          '$_wexPrefsName\t${entry.value}\t${_clean(cookies[entry.key]!)}',
      for (final entry in seed.entries)
        '$_wexPrefsName\t${entry.key}\t${_clean(entry.value)}',
      // 桌面端没有 Go 代理（ARM32 + Android root 场景），强制 Java 多线程取流；
      // 否则原画线路必报「Go多线程启动失败」。
      '$_wexPrefsName\tpan.thread_proxy_mode\tjava',
    ];
    if (lines.isEmpty) {
      _delete(file);
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${lines.join('\n')}\n', flush: true);
  }

  /// 通道 3：`<java.io.tmpdir>/tvbox-ext/TVBox/*.txt`（JSON 对象，键 `cookie`）。
  static Future<void> _syncPizazzFiles(
    String tmpDir,
    Map<String, String> cookies,
  ) async {
    final dir = Directory(p.join(tmpDir, 'tvbox-ext', 'TVBox'));
    for (final entry in _pizazzFiles.entries) {
      final file = File(p.join(dir.path, entry.value));
      final value = cookies[entry.key] ?? '';
      if (value.isEmpty) {
        _delete(file);
        continue;
      }
      // quark / uc 的登录判定是「三字段均非空」→ 保留旧文件里的真实昵称/会员态，缺省占位。
      var nickname = 'MisaTV';
      var memberType = '1';
      if (entry.key == 'quark' || entry.key == 'uc') {
        try {
          final old = jsonDecode(file.readAsStringSync());
          if (old is Map) {
            final n = '${old['nickname'] ?? ''}'.trim();
            final t = '${old['member_type'] ?? ''}'.trim();
            if (n.isNotEmpty) nickname = n;
            if (t.isNotEmpty) memberType = t;
          }
        } catch (_) {
          // 无旧文件 / 内容损坏 → 用占位
        }
      }
      final body = <String, dynamic>{'cookie': value};
      if (entry.key == 'quark' || entry.key == 'uc') {
        body['nickname'] = nickname;
        body['member_type'] = memberType;
      }
      dir.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(body), flush: true);
    }
  }

  /// 通道 4：fty 系 `Cloud-drive` 配置（源在 init 时读取 quarkCookie / ucCookie）。
  ///
  /// 默认落点 `<数据目录>/tvfan/Cloud-drive.txt`；源 ext 里声明了相对路径时一并写入
  /// 该文件（绝对 http 地址属于远端配置，不碰）。
  static Future<void> _syncCloudDrive(
    String dataDir,
    Map<String, String> cookies,
    String ext,
  ) async {
    final targets = <String>{p.join(dataDir, 'tvfan', 'Cloud-drive.txt')};
    final rel = _cloudDriveRelPath(ext);
    if (rel.isNotEmpty) targets.add(p.join(dataDir, rel));
    for (final path in targets) {
      final file = File(path);
      var obj = <String, dynamic>{};
      try {
        if (file.existsSync()) {
          final old = jsonDecode(file.readAsStringSync());
          if (old is Map) obj = Map<String, dynamic>.from(old);
        }
      } catch (_) {
        // 首次/损坏 → 重建
      }
      // 凭据键必须完全由当前绑定状态决定：解绑后不能留着旧 Cookie。
      obj.remove('quarkCookie');
      obj.remove('ucCookie');
      // 移动云盘已移除：清掉旧版本写进去的残留键。
      obj.remove('mobileCookie');
      obj.remove('pan139Cookie');
      obj.remove('139Cookie');
      obj.remove('mobile');
      final quark = cookies['quark'] ?? '';
      final uc = cookies['uc'] ?? '';
      if (quark.isNotEmpty) obj['quarkCookie'] = quark;
      if (uc.isNotEmpty) obj['ucCookie'] = uc;
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(jsonEncode(obj), flush: true);
      } catch (_) {
        // 写入失败不阻断调用
      }
    }
  }

  /// 源 ext 的 `Cloud-drive` 若是本地相对路径 → 相对数据目录的规范路径。
  static String _cloudDriveRelPath(String ext) {
    final trimmed = ext.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return '';
      final value = '${decoded['Cloud-drive'] ?? ''}'.trim();
      if (value.isEmpty ||
          RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
        return '';
      }
      return value.replaceFirst(RegExp(r'^\.{0,2}/+'), '');
    } catch (_) {
      return '';
    }
  }

  /// 种子是「按行/按制表符切分」的纯文本，值里不能出现换行或制表符。
  static String _clean(String value) =>
      value.replaceAll(RegExp(r'[\r\n\t]'), '').trim();

  static void _delete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 文件被占用时忽略：下次同步会再试
    }
  }
}
