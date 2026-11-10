import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 播放中继的磁盘缓存。
///
/// 「边播边缓存」把播放器已经下行的分片顺手写到本地：重新拖回看过的位置、
/// 或者第二天重看同一集时，直接读盘不再回源。
///
/// 只缓存**整段 GET 的小文件**（HLS 分片、封面图之类）：
/// 带 Range 的请求、m3u8 清单、gzip 响应、以及超过 [maxEntryBytes] 的响应
/// 都不进缓存 —— 大文件交给播放器自己的内存缓冲，免得一轮播放就把盘塞满。
class StreamDiskCache {
  StreamDiskCache({
    required this.dir,
    required this.enabled,
    required this.limitMb,
  });

  /// 缓存根目录（`<应用数据>/cache/stream`）。
  final String dir;

  /// 是否启用；由设置页的开关实时决定，不重启也能生效。
  final bool Function() enabled;

  /// 容量上限（MB），超出按「最久未使用」淘汰。
  final int Function() limitMb;

  /// 单条上限：分片一般 2–8MB，超过 64MB 的多半是整片 MP4，不缓存。
  static const int maxEntryBytes = 64 * 1024 * 1024;

  final Map<String, int> _sizes = {};

  /// 最近一次命中的时间：淘汰按它排序，避免每次都 stat 整个目录。
  final Map<String, DateTime> _touched = {};
  int _bytes = 0;
  bool _indexed = false;
  String _indexedDir = '';

  /// 缓存键：地址的 sha1。分片地址通常自带签名、随清单变化，直接哈希即可。
  static String keyOf(String url) => sha1.convert(utf8.encode(url)).toString();

  static String _sep() => Platform.pathSeparator;

  File _entry(String key) {
    final shard = key.length >= 2 ? key.substring(0, 2) : '00';
    return File('$dir${_sep()}$shard${_sep()}$key');
  }

  File _meta(String key) => File('${_entry(key).path}.json');

  Future<void> _ensureIndex() async {
    if (_indexed && _indexedDir == dir) return;
    _indexed = true;
    _indexedDir = dir;
    _sizes.clear();
    _touched.clear();
    _bytes = 0;
    if (dir.isEmpty) return;
    final root = Directory(dir);
    if (!await root.exists()) return;
    try {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (path.endsWith('.tmp')) {
          // 上次进程被杀留下的半截文件
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        if (path.endsWith('.json')) continue;
        try {
          final stat = await entity.stat();
          if (stat.size <= 0) continue;
          _sizes[path] = stat.size;
          _touched[path] = stat.modified;
          _bytes += stat.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 命中则返回可读条目，并把 mtime 刷新（LRU 不误删仍在用的分片）。
  Future<StreamCacheEntry?> lookup(String key) async {
    if (dir.isEmpty || !enabled()) return null;
    await _ensureIndex();
    final file = _entry(key);
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (stat.size <= 0) {
        await _drop(file);
        return null;
      }
      var contentType = 'application/octet-stream';
      try {
        final metaFile = _meta(key);
        if (await metaFile.exists()) {
          final decoded = jsonDecode(await metaFile.readAsString());
          if (decoded is Map && decoded['type'] is String) {
            final type = (decoded['type'] as String).trim();
            if (type.isNotEmpty) contentType = type;
          }
        }
      } catch (_) {}
      // 只更新内存里的访问时间：命中是高频路径，不该每次都写盘。
      _touched[file.path] = DateTime.now();
      return StreamCacheEntry(
        file: file,
        contentType: contentType,
        length: stat.size,
      );
    } catch (_) {
      return null;
    }
  }

  /// 未命中时开一个写入口；返回 null 表示这次响应不进缓存。
  Future<StreamCacheWriter?> open(
    String key, {
    required String contentType,
    required int length,
  }) async {
    if (dir.isEmpty || !enabled()) return null;
    if (length <= 0 || length > maxEntryBytes) return null;
    await _ensureIndex();
    await _evictFor(length);
    final entry = _entry(key);
    try {
      await entry.parent.create(recursive: true);
      final tmp = File('${entry.path}.tmp');
      if (await tmp.exists()) await tmp.delete();
      return StreamCacheWriter._(
        cache: this,
        key: key,
        entry: entry,
        tmp: tmp,
        sink: tmp.openWrite(),
        contentType: contentType,
        length: length,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _evictFor(int incoming) async {
    final limit = limitMb() * 1024 * 1024;
    if (limit <= 0 || _bytes + incoming <= limit) return;
    // 按内存里记录的访问时间排序，不再逐个 stat 文件 —— 这一步在每个分片
    // 落盘前都会跑，全量磁盘 IO 会把边播缓存本身变成新的卡顿源。
    final paths = _sizes.keys.toList()
      ..sort((a, b) {
        final ta = _touched[a];
        final tb = _touched[b];
        if (ta == null && tb == null) return 0;
        if (ta == null) return -1;
        if (tb == null) return 1;
        return ta.compareTo(tb);
      });
    for (final path in paths) {
      if (_bytes + incoming <= limit) break;
      await _drop(File(path));
    }
  }

  Future<void> _drop(File file) async {
    final size = _sizes[file.path];
    _sizes.remove(file.path);
    _touched.remove(file.path);
    if (size != null) _bytes -= size;
    try {
      await file.delete();
    } catch (_) {}
    try {
      await File('${file.path}.json').delete();
    } catch (_) {}
  }

  void _put(String path, int length) {
    final old = _sizes[path];
    if (old != null) _bytes -= old;
    _sizes[path] = length;
    _touched[path] = DateTime.now();
    _bytes += length;
  }

  /// 清空缓存目录（设置页的「清空缓存」）。
  Future<void> clear() async {
    if (dir.isEmpty) return;
    final root = Directory(dir);
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
    _sizes.clear();
    _touched.clear();
    _bytes = 0;
    _indexed = true;
    _indexedDir = dir;
  }

  /// 当前占用字节数（设置页展示用）。
  Future<int> totalBytes() async {
    if (dir.isEmpty) return 0;
    await _ensureIndex();
    return _bytes;
  }
}

class StreamCacheEntry {
  const StreamCacheEntry({
    required this.file,
    required this.contentType,
    required this.length,
  });

  final File file;
  final String contentType;
  final int length;
}

/// 写入器：一边转发给播放器，一边把同样的字节写进 `<key>.tmp`，
/// 流正常结束后 rename 成正式条目并记录 content-type。
class StreamCacheWriter {
  StreamCacheWriter._({
    required this.cache,
    required this.key,
    required this.entry,
    required this.tmp,
    required this.sink,
    required this.contentType,
    required this.length,
  });

  final StreamDiskCache cache;
  final String key;
  final File entry;
  final File tmp;
  final String contentType;
  final int length;
  final IOSink sink;
  bool _done = false;

  void add(List<int> chunk) {
    if (_done) return;
    try {
      sink.add(chunk);
    } catch (_) {
      _done = true;
    }
  }

  Future<void> commit() async {
    if (_done) return;
    _done = true;
    try {
      await sink.close();
      if (await entry.exists()) {
        try {
          await entry.delete();
        } catch (_) {}
      }
      await tmp.rename(entry.path);
      try {
        await File('${entry.path}.json')
            .writeAsString(jsonEncode({'type': contentType}));
      } catch (_) {}
      cache._put(entry.path, length);
    } catch (_) {
      await abort();
    }
  }

  Future<void> abort() async {
    _done = true;
    try {
      await sink.close();
    } catch (_) {}
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}
