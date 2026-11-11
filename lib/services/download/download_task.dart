/// 视频下载的纯逻辑：任务状态、文件名清洗、HLS 清单解析。
///
/// 这里不碰 `dart:io`，既方便单测，也能被 Web 桩原样复用。
library;

enum DownloadStatus { queued, running, paused, done, failed }

/// 一个下载任务。进度字段可变：下载线程高频更新，再由服务统一节流 notify。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.episode,
    required this.url,
    required this.headers,
    required this.savePath,
    required this.isHls,
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.status = DownloadStatus.queued,
    this.error = '',
  });

  final String id;

  /// 影片名。
  final String title;

  /// 集名；空串表示单集影片。
  final String episode;

  /// 原始播放地址（不是 127.0.0.1 的中继地址）。
  final String url;

  /// 请求头：UA / Referer / Cookie。
  final Map<String, String> headers;

  /// 目标文件绝对路径。下载前探测出真实类型是 HLS 时会换成 `.ts`。
  String savePath;

  /// 是否按 HLS 清单逐片下载后合并。
  final bool isHls;

  int totalBytes;
  int receivedBytes;
  DownloadStatus status;
  String error;

  /// HLS 的分片进度提示（`12/340 片`）；单文件下载时为空。
  String detail = '';

  /// 最近一次测得的速度（字节/秒）。
  double speedBps = 0;

  String get displayName =>
      episode.trim().isEmpty ? title : '$title · $episode';

  double get progress {
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  bool get busy =>
      status == DownloadStatus.queued || status == DownloadStatus.running;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'episode': episode,
    'url': url,
    'headers': headers,
    'savePath': savePath,
    'isHls': isHls,
    'totalBytes': totalBytes,
    'receivedBytes': receivedBytes,
    'status': status.name,
    'error': error,
    'detail': detail,
  };

  /// 从存档恢复。未知状态按「已暂停」处理，避免一启动就当成在跑。
  factory DownloadTask.fromJson(Map<String, Object?> json) {
    final rawStatus = (json['status'] ?? '').toString();
    final status = DownloadStatus.values.firstWhere(
      (value) => value.name == rawStatus,
      orElse: () => DownloadStatus.paused,
    );
    final rawHeaders = json['headers'];
    return DownloadTask(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      episode: (json['episode'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      headers: rawHeaders is Map
          ? {
              for (final entry in rawHeaders.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      savePath: (json['savePath'] ?? '').toString(),
      isHls: json['isHls'] == true,
      totalBytes: json['totalBytes'] is num
          ? (json['totalBytes'] as num).toInt()
          : 0,
      receivedBytes: json['receivedBytes'] is num
          ? (json['receivedBytes'] as num).toInt()
          : 0,
      status: status,
      error: (json['error'] ?? '').toString(),
    )..detail = (json['detail'] ?? '').toString();
  }
}

/// Windows 不允许的字符 + 控制字符。`/` 与 `\` 一并换掉，避免拼出多级目录。
final RegExp _badNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

/// Windows 保留设备名：即便带扩展名也不能用。
const Set<String> _reservedNames = {
  'con',
  'prn',
  'aux',
  'nul',
  'com1',
  'com2',
  'com3',
  'com4',
  'com5',
  'com6',
  'com7',
  'com8',
  'com9',
  'lpt1',
  'lpt2',
  'lpt3',
  'lpt4',
  'lpt5',
  'lpt6',
  'lpt7',
  'lpt8',
  'lpt9',
};

/// 清洗成安全的文件名（不含扩展名）。
///
/// 只做「能不能落盘」这一件事：非法字符换成下划线、压掉多余空白、
/// 截断到 80 字，并躲开 Windows 的保留设备名。
String sanitizeFileName(String raw, {String fallback = 'video'}) {
  var name = raw.replaceAll(_badNameChars, '_');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 结尾的点和空格在 Windows 上会被静默吃掉，提前去掉。
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = fallback;
  final base = name.split('.').first.toLowerCase();
  if (_reservedNames.contains(base)) name = '${name}_';
  if (name.length > 80) name = name.substring(0, 80).trim();
  if (name.isEmpty) name = fallback;
  return name;
}

/// 从地址 / content-type 猜扩展名；猜不到按 mp4 处理。
String guessMediaExtension(String url, {String contentType = ''}) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  const known = [
    '.mp4',
    '.mkv',
    '.m4v',
    '.mov',
    '.webm',
    '.flv',
    '.avi',
    '.wmv',
    '.ts',
    '.mp3',
    '.m4a',
    '.flac',
  ];
  for (final ext in known) {
    if (path.endsWith(ext)) return ext;
  }
  final type = contentType.toLowerCase();
  if (type.contains('mpegurl') || path.endsWith('.m3u8')) return '.ts';
  if (type.contains('matroska')) return '.mkv';
  if (type.contains('webm')) return '.webm';
  if (type.contains('mp2t')) return '.ts';
  if (type.contains('audio/')) return '.m4a';
  return '.mp4';
}

/// 地址看起来是不是 HLS 清单。
bool looksLikeHls(String url, {String contentType = ''}) {
  if (contentType.toLowerCase().contains('mpegurl')) return true;
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.m3u8');
}

/// 人类可读的字节数。
String formatBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// 解析后的 HLS 清单。
class HlsPlaylist {
  const HlsPlaylist({
    this.segments = const [],
    this.initSegment = '',
    this.encrypted = false,
    this.variantUrl = '',
  });

  /// 分片地址（已按 base 解析成绝对地址）。
  final List<String> segments;

  /// fMP4 的初始化段（`#EXT-X-MAP`），合并时要排在最前。
  final String initSegment;

  /// 是否带 `#EXT-X-KEY`（AES-128 等），当前不支持解密。
  final bool encrypted;

  /// 非空表示这是主清单，应改拉这个子清单再解析。
  final String variantUrl;

  bool get isEmpty => segments.isEmpty && variantUrl.isEmpty;
}

/// 解析 m3u8 文本。
///
/// 主清单（带 `#EXT-X-STREAM-INF`）按 BANDWIDTH 选最高码率的那一路，
/// 交给调用方递归再拉一次；媒体清单则取出所有分片与 `EXT-X-MAP`。
HlsPlaylist parseHlsPlaylist(String text, {required String baseUrl}) {
  final base = Uri.tryParse(baseUrl);
  String resolve(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.hasScheme) return uri.toString();
    return base?.resolveUri(uri).toString() ?? raw;
  }

  final segments = <String>[];
  String initSegment = '';
  var encrypted = false;
  var pendingBandwidth = -1;
  var bestBandwidth = -1;
  var bestVariant = '';

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-KEY')) {
      // METHOD=NONE 是显式声明不加密，不能算加密流。
      if (!line.toUpperCase().contains('METHOD=NONE')) encrypted = true;
      continue;
    }
    if (line.startsWith('#EXT-X-MAP')) {
      final uri = _uriAttribute(line);
      if (uri.isNotEmpty) initSegment = resolve(uri);
      continue;
    }
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      pendingBandwidth = _bandwidthAttribute(line);
      continue;
    }
    if (line.startsWith('#')) continue;
    if (pendingBandwidth >= 0) {
      if (pendingBandwidth > bestBandwidth) {
        bestBandwidth = pendingBandwidth;
        bestVariant = resolve(line);
      }
      pendingBandwidth = -1;
      continue;
    }
    segments.add(resolve(line));
  }

  return HlsPlaylist(
    segments: segments,
    initSegment: initSegment,
    encrypted: encrypted,
    variantUrl: segments.isEmpty ? bestVariant : '',
  );
}

String _uriAttribute(String line) {
  final match = RegExp(r'URI="([^"]*)"', caseSensitive: false).firstMatch(line);
  return match?.group(1)?.trim() ?? '';
}

int _bandwidthAttribute(String line) {
  final match = RegExp(
    r'BANDWIDTH=(\d+)',
    caseSensitive: false,
  ).firstMatch(line);
  return int.tryParse(match?.group(1) ?? '') ?? 0;
}
