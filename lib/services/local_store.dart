import 'dart:convert';
import 'dart:ui' show Size;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dav.dart';
import '../models/drive_account.dart';
import '../models/site_config.dart';
import '../models/user_data.dart';
import '../models/xunlei_account.dart';
import 'player/skip_segments.dart';

class LocalStore {
  LocalStore(this._prefs);
  final SharedPreferences _prefs;

  static const kProfiles = 'kniephos.profiles';
  static const kKazumiRules = 'kniephos.kazumiRules';
  static const kActiveProfile = 'kniephos.activeProfile';
  static const kActiveSite = 'kniephos.activeSite';
  static const kActiveLive = 'kniephos.activeLive';
  static const kActiveLiveProfile = 'kniephos.activeLiveProfile';
  static const kThemeMode = 'kniephos.themeMode';
  static const kAccentIndex = 'kniephos.accentIndex';
  static const kNavBarSize = 'kniephos.navBarSize';
  static const kNavBarAutoHide = 'kniephos.navBarAutoHide';
  static const kHomeColumns = 'kniephos.homeColumns';
  static const kHomeBrowseMode = 'kniephos.homeBrowseMode';
  static const kFavorites = 'kniephos.favorites';
  static const kHistory = 'kniephos.history';
  static const kSearchHistory = 'kniephos.searchHistory';
  static const kPlayerSettings = 'kniephos.playerSettings';
  static const kDriveAccounts = 'kniephos.driveAccounts';
  static const kXunleiAccount = 'kniephos.xunleiAccount';
  static const kLocalLives = 'kniephos.localLives';
  static const kAssrtToken = 'kniephos.assrtToken';
  static const kCustomSubtitleApis = 'kniephos.customSubtitleApis';
  static const kDanmakuSettings = 'kniephos.danmakuSettings';
  static const kContentFilter = 'kniephos.contentFilter';
  static const kMovieQuotes = 'kniephos.movieQuotes';
  static const kEulaAccepted = 'kniephos.eulaAccepted';
  static const kSkipSegments = 'kniephos.skipSegments';
  static const kDavServers = 'kniephos.davServers';
  static const kProxy = 'kniephos.proxy';
  static const kProxyPool = 'kniephos.proxyPool';
  static const kProxyPoolUnlocked = 'kniephos.proxyPoolUnlocked';
  static const kWindowSize = 'kniephos.windowSize';

  static Future<LocalStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalStore(prefs);
  }

  List<ConfigProfile> loadProfiles() {
    final raw = _prefs.getString(kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ConfigProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ConfigProfile> profiles) => _prefs.setString(
    kProfiles,
    jsonEncode(profiles.map((e) => e.toJson()).toList()),
  );

  /// 本地导入的 Kazumi 规则（原始 JSON 数组，便于版本升级后重新解析）。
  List<Map<String, dynamic>> loadKazumiRules() {
    final raw = _prefs.getString(kKazumiRules);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveKazumiRules(List<Map<String, dynamic>> rules) =>
      _prefs.setString(kKazumiRules, jsonEncode(rules));

  Map<String, DriveAccount> loadDriveAccounts() {
    final raw = _prefs.getString(kDriveAccounts);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      final map = <String, DriveAccount>{};
      for (final item in decoded.whereType<Map>()) {
        final account = DriveAccount.fromJson(Map<String, dynamic>.from(item));
        if (account.provider.isEmpty) continue;
        map[account.provider] = account;
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveDriveAccounts(Map<String, DriveAccount> accounts) =>
      _prefs.setString(
        kDriveAccounts,
        jsonEncode(accounts.values.map((e) => e.toJson()).toList()),
      );

  XunleiAccount loadXunleiAccount() =>
      XunleiAccount.fromJsonString(_prefs.getString(kXunleiAccount) ?? '');

  Future<void> saveXunleiAccount(XunleiAccount account) =>
      _prefs.setString(kXunleiAccount, account.toJsonString());

  Future<void> clearXunleiAccount() => _prefs.remove(kXunleiAccount);

  String? get activeProfileId => _prefs.getString(kActiveProfile);
  Future<void> setActiveProfileId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(kActiveProfile);
    } else {
      await _prefs.setString(kActiveProfile, id);
    }
  }

  String? get activeSiteKey => _prefs.getString(kActiveSite);
  Future<void> setActiveSiteKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _prefs.remove(kActiveSite);
    } else {
      await _prefs.setString(kActiveSite, key);
    }
  }

  /// 本地导入的直播线路（独立于订阅，切档案/刷新订阅都不丢）。
  List<LiveBean> loadLocalLives() {
    final raw = _prefs.getString(kLocalLives);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => LiveBean.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLocalLives(List<LiveBean> lives) => _prefs.setString(
    kLocalLives,
    jsonEncode(lives.map((e) => e.toJson()).toList()),
  );

  /// 弹幕显示偏好（JSON 字符串；由 DanmakuSettings 负责宽容解析）。
  String get danmakuSettingsJson => _prefs.getString(kDanmakuSettings) ?? '';
  Future<void> saveDanmakuSettingsJson(String json) =>
      _prefs.setString(kDanmakuSettings, json);

  /// 内容过滤（JSON 字符串；由 ContentFilterSettings 负责宽容解析）。
  String get contentFilterJson => _prefs.getString(kContentFilter) ?? '';
  Future<void> saveContentFilterJson(String json) =>
      _prefs.setString(kContentFilter, json);

  /// 在线影视台词缓存（JSON：`fetchedAt` + 台词数组）。
  String get movieQuotesCacheJson => _prefs.getString(kMovieQuotes) ?? '';
  Future<void> saveMovieQuotesCacheJson(String json) =>
      _prefs.setString(kMovieQuotes, json);

  /// assrt.net 字幕接口 token（可空；空时只用免 token 的 SubtitleCat）。
  String get assrtToken => _prefs.getString(kAssrtToken) ?? '';
  Future<void> setAssrtToken(String token) =>
      _prefs.setString(kAssrtToken, token.trim());

  /// 用户自定义字幕 API 配置（每行 名称@URL模板）。
  String get customSubtitleApis => _prefs.getString(kCustomSubtitleApis) ?? '';
  Future<void> setCustomSubtitleApis(String text) =>
      _prefs.setString(kCustomSubtitleApis, text.trim());

  /// 当前直播订阅（独立于点播档案）。
  String? get activeLiveProfileId => _prefs.getString(kActiveLiveProfile);
  Future<void> setActiveLiveProfileId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(kActiveLiveProfile);
    } else {
      await _prefs.setString(kActiveLiveProfile, id);
    }
  }

  String? get activeLiveKey => _prefs.getString(kActiveLive);
  Future<void> setActiveLiveKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _prefs.remove(kActiveLive);
    } else {
      await _prefs.setString(kActiveLive, key);
    }
  }

  /// 首次启动的用户协议是否已同意。
  bool get eulaAccepted => _prefs.getBool(kEulaAccepted) ?? false;
  Future<void> setEulaAccepted(bool value) =>
      _prefs.setBool(kEulaAccepted, value);

  String get themeMode => _prefs.getString(kThemeMode) ?? 'system';
  Future<void> setThemeMode(String mode) => _prefs.setString(kThemeMode, mode);

  int get accentIndex => _prefs.getInt(kAccentIndex) ?? 0;
  Future<void> setAccentIndex(int index) => _prefs.setInt(kAccentIndex, index);

  /// 底部导航栏尺寸：0 紧凑 / 1 标准 / 2 较大 / 3 超大。
  int get navBarSize => _prefs.getInt(kNavBarSize) ?? 1;
  Future<void> setNavBarSize(int value) => _prefs.setInt(kNavBarSize, value);

  /// 底部导航栏是否自动隐藏（只在鼠标靠近窗口底部时滑出）。
  bool get navBarAutoHide => _prefs.getBool(kNavBarAutoHide) ?? false;
  Future<void> setNavBarAutoHide(bool value) =>
      _prefs.setBool(kNavBarAutoHide, value);

  /// 首页每行封面数：0 = 自动（按窗口宽度），4-8 = 固定列数。
  int get homeColumns => _prefs.getInt(kHomeColumns) ?? 0;
  Future<void> setHomeColumns(int value) => _prefs.setInt(kHomeColumns, value);

  /// 首页分类浏览方式：0 = 换页（上一页 / 下一页），1 = 瀑布（滑到底自动加载）。
  int get homeBrowseMode => _prefs.getInt(kHomeBrowseMode) ?? 0;
  Future<void> setHomeBrowseMode(int value) =>
      _prefs.setInt(kHomeBrowseMode, value);

  /// 内置代理配置（JSON：enabled/type/host/port/username/password）。
  String get proxyJson => _prefs.getString(kProxy) ?? '';
  Future<void> setProxyJson(String json) async {
    if (json.trim().isEmpty) {
      await _prefs.remove(kProxy);
    } else {
      await _prefs.setString(kProxy, json);
    }
  }

  /// 代理池（JSON：nodes / selected / fetchedAt）。
  String get proxyPoolJson => _prefs.getString(kProxyPool) ?? '';
  Future<void> setProxyPoolJson(String json) async {
    if (json.trim().isEmpty) {
      await _prefs.remove(kProxyPool);
    } else {
      await _prefs.setString(kProxyPool, json);
    }
  }

  /// 代理池入口是否已解锁（设置页连点 5 次）。
  bool get proxyPoolUnlocked => _prefs.getBool(kProxyPoolUnlocked) ?? false;
  Future<void> setProxyPoolUnlocked(bool value) =>
      _prefs.setBool(kProxyPoolUnlocked, value);

  /// 记忆的启动窗口大小（`宽x高`，逻辑像素）；null = 未记忆。
  Size? loadWindowSize() {
    final raw = _prefs.getString(kWindowSize);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.toLowerCase().split('x');
    if (parts.length != 2) return null;
    final width = double.tryParse(parts[0].trim());
    final height = double.tryParse(parts[1].trim());
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  Future<void> saveWindowSize(Size? size) async {
    if (size == null) {
      await _prefs.remove(kWindowSize);
      return;
    }
    await _prefs.setString(
      kWindowSize,
      '${size.width.round()}x${size.height.round()}',
    );
  }

  List<FavoriteItem> loadFavorites() {
    final raw = _prefs.getString(kFavorites);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => FavoriteItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFavorites(List<FavoriteItem> items) => _prefs.setString(
    kFavorites,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );

  List<HistoryItem> loadHistory() {
    final raw = _prefs.getString(kHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => HistoryItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<HistoryItem> items) => _prefs.setString(
    kHistory,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );

  List<String> loadSearchHistory() {
    final raw = _prefs.getString(kSearchHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.map((e) => e.toString()).toList() : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSearchHistory(List<String> items) =>
      _prefs.setString(kSearchHistory, jsonEncode(items));

  PlayerSettings loadPlayerSettings() {
    final raw = _prefs.getString(kPlayerSettings);
    if (raw == null || raw.isEmpty) return const PlayerSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return PlayerSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return const PlayerSettings();
  }

  Future<void> savePlayerSettings(PlayerSettings settings) =>
      _prefs.setString(kPlayerSettings, jsonEncode(settings.toJson()));

  Map<String, SkipRecord> loadSkipSegments() {
    final raw = _prefs.getString(kSkipSegments);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, SkipRecord>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        if (key.isEmpty) continue;
        final record = normalizeSkipRecord(entry.value);
        if (record != null) out[key] = record;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSkipSegments(Map<String, SkipRecord> records) =>
      _prefs.setString(
        kSkipSegments,
        jsonEncode(records.map((key, value) => MapEntry(key, value.toJson()))),
      );

  /// WebDAV 服务器（只读直连；密码明文，与网盘 Cookie 同口径）。
  List<DavServer> loadDavServers() {
    final raw = _prefs.getString(kDavServers);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => DavServer.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.id.isNotEmpty && s.url.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDavServers(List<DavServer> servers) => _prefs.setString(
    kDavServers,
    jsonEncode(servers.map((e) => e.toJson()).toList()),
  );
}
