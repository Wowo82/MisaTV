import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 播放中继的磁盘缓存。
///
/// 「边播边缓存」把播放器已经下行的分片顺手写到本地：重新拖回看过的位置、
/// 或者第二天重看同一集时，直接读盘不再回源。
///
/// 三条约束保证它不会把内存吃掉：
///   · **写入带背压**：落盘走 `RandomAccessFile.writeFrom` 逐块 await，磁盘慢时
///     上游会被暂停，内存占用恒定在一块 chunk，不随分片大小增长；
///   · **并发有上限**：同时落盘的分片最多 [maxConcurrentWriters] 个，其余请求
///     只转发不缓存，HLS 一次拉七八个分片也不会叠出七八份整段缓冲；
///   · **只缓存整段 GET 的小文件**（HLS 分片、封面图之类）：带 Range 的请求、
///     m3u8 清单、gzip 响应、以及超过 [maxEntryBytes] 的响应都不进缓存。
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

  /// 容量上限（MB），超出按「最久未使用」淘汰。0 表示不限制。
  final int Function() limitMb;

  /// 单条上限：分片一般 2–8MB，超过 64MB 的多半是整片 MP4，不缓存。
  static const int maxEntryBytes = 64 * 1024 * 1024;

  /// 同时落盘的分片数。播放器起播瞬间会并发拉 4–8 个分片，
  /// 不设上限时每条都各自持有一份写入缓冲，是内存峰值的主要来源。
  static const int maxConcurrentWriters = 4;

  final Map<String, int> _sizes = {};

  /// 最近一次命中的顺序号：淘汰按它排序，避免每次都 stat 整个目录。
  /// 用单调递增的 int 而不是 DateTime —— 几十万条目时能省下可观的对象开销。
  final Map<String, int> _touched = {};
  int _clock = 0;
  int _bytes = 0;
  bool _indexed = false;
  String _indexedDir = '';
  Future<void>? _indexing;

  /// 正在写的 key：同一分片被两个请求同时拉时不重复写同一个 `.tmp`。
  final Set<String> _inflight = {};
  int _writers = 0;

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
    // 首次请求可能和播放器的并发分片请求一起到：只允许扫一次目录，
    // 否则几路请求各扫一遍，索引互相覆盖、容量统计就全错了。
    final running = _indexing;
    if (running != null) {
      await running;
      return;
    }
    final future = _scanIndex();
    _indexing = future;
    try {
      await future;
    } finally {
      _indexing = null;
    }
  }

  Future<void> _scanIndex() async {
    final target = dir;
    _indexed = true;
    _indexedDir = target;
    _sizes.clear();
    _touched.clear();
    _bytes = 0;
    if (target.isEmpty) return;
    final root = Directory(target);
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
          final stamp = stat.modified.millisecondsSinceEpoch;
          _touched[path] = stamp;
          if (stamp > _clock) _clock = stamp;
          _bytes += stat.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  int _tick() => ++_clock;

  /// 命中则返回可读条目，并把访问顺序刷新（LRU 不误删仍在用的分片）。
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
      // 只更新内存里的访问顺序：命中是高频路径，不该每次都写盘。
      _touched[file.path] = _tick();
      return StreamCacheEntry(
        file: file,
        contentType: contentType,
        length: stat.size,
      );
    } catch (_) {
      return null;
    }
  }

  /// 未命中时开一个写入口；返回 null 表示这次响应不进缓存（照常转发）。
  Future<StreamCacheWriter?> open(
    String key, {
    required String contentType,
    required int length,
  }) async {
    if (dir.isEmpty || !enabled()) return null;
    if (length <= 0 || length > maxEntryBytes) return null;
    if (_writers >= maxConcurrentWriters) return null;
    if (_inflight.contains(key)) return null;
    final limit = limitMb() * 1024 * 1024;
    // 单条就吃掉八分之一以上容量时，写进去会把整库挤掉一轮（缓存抖动），
    // 不如直接不缓存，让播放器自己缓冲。
    if (limit > 0 && length > limit ~/ 8) return null;
    _inflight.add(key);
    var handedOff = false;
    try {
      await _ensureIndex();
      await _evictFor(length);
      final entry = _entry(key);
      await entry.parent.create(recursive: true);
      var tmp = File('${entry.path}.tmp');
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // 残留文件被占用（杀软扫描 / 上一轮还没退干净）：换个名字绕开，
          // 仍然以 .tmp 结尾，下次启动的索引扫描会把它清掉。
          tmp = File(
            '${entry.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
          );
        }
      }
      final file = await tmp.open(mode: FileMode.write);
      _writers++;
      handedOff = true;
      return StreamCacheWriter._(
        cache: this,
        key: key,
        entry: entry,
        tmp: tmp,
        file: file,
        contentType: contentType,
        expectedLength: length,
      );
    } catch (_) {
      return null;
    } finally {
      if (!handedOff) _inflight.remove(key);
    }
  }

  Future<void> _evictFor(int incoming) async {
    final limit = limitMb() * 1024 * 1024;
    if (limit <= 0 || _bytes + incoming <= limit) return;
    // 一次淘汰到上限的 85%，而不是刚好压线。每个分片落盘前都排一次全量索引
    // 会把边播缓存本身变成新的卡顿源；留出余量后排序频率降到原来的 1/10。
    final target = (limit * 0.85).round();
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
      if (_bytes + incoming <= target) break;
      await _drop(File(path));
    }
  }

  Future<void> _drop(File file) async {
    var gone = false;
    try {
      await file.delete();
      gone = true;
    } catch (_) {
      // 正被另一个请求读着（Windows 上句柄没释放时删不掉）：
      // 留在索引里等下一轮淘汰，别把容量统计减成负数。
      gone = !await file.exists();
    }
    if (!gone) return;
    final size = _sizes.remove(file.path);
    _touched.remove(file.path);
    if (size != null) _bytes -= size;
    try {
      await File('${file.path}.json').delete();
    } catch (_) {}
  }

  void _put(String path, int length) {
    final old = _sizes[path];
    if (old != null) _bytes -= old;
    _sizes[path] = length;
    _touched[path] = _tick();
    _bytes += length;
  }

  void _releaseWriter(String key) {
    _inflight.remove(key);
    if (_writers > 0) _writers--;
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
    _clock = 0;
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
///
/// 关键是 [write] **真的会等磁盘**：调用方必须 `await` 它，
/// 这样磁盘跟不上时会反压到上游，内存里永远只压着一块 chunk。
class StreamCacheWriter {
  StreamCacheWriter._({
    required this.cache,
    required this.key,
    required this.entry,
    required this.tmp,
    required this.file,
    required this.contentType,
    required this.expectedLength,
  });

  final StreamDiskCache cache;
  final String key;
  final File entry;
  final File tmp;
  final RandomAccessFile file;
  final String contentType;
  final int expectedLength;

  /// 攒到 128KB 再落一次盘：8KB 一块直接 writeFrom 会产生上千次跨 isolate
  /// 往返，攒批后 syscall 数量降一个量级，而缓冲本身仍然很小。
  static const int _flushAt = 128 * 1024;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _written = 0;
  bool _done = false;
  bool _released = false;

  /// 追加一块字节。返回时数据已经交给操作系统（或已放弃缓存）。
  ///
  /// 缓存失败不影响播放：磁盘满 / 文件被占用时只是不再缓存，
  /// 转发继续走 —— 不能因为写盘失败把正在看的片掐掉。
  Future<void> write(List<int> chunk) async {
    if (_done) return;
    _pending.add(chunk);
    if (_pending.length < _flushAt) return;
    await _flush();
  }

  Future<void> _flush() async {
    if (_pending.isEmpty || _done) return;
    final bytes = _pending.takeBytes();
    try {
      await file.writeFrom(bytes);
      _written += bytes.length;
    } catch (_) {
      await abort();
    }
  }

  Future<void> commit() async {
    if (_done) return;
    await _flush();
    if (_done) return;
    _done = true;
    try {
      await file.close();
      // 声明了长度却少写：上游中途断了。半截分片当完整缓存用，
      // 下次拖回这里会直接花屏 / 卡死，宁可丢掉重下。
      if (expectedLength > 0 && _written != expectedLength) {
        await _dropTmp();
        return;
      }
      if (await entry.exists()) {
        try {
          await entry.delete();
        } catch (_) {}
      }
      await tmp.rename(entry.path);
      try {
        await File(
          '${entry.path}.json',
        ).writeAsString(jsonEncode({'type': contentType}));
      } catch (_) {}
      cache._put(entry.path, _written);
    } catch (_) {
      await _dropTmp();
    } finally {
      _release();
    }
  }

  Future<void> abort() async {
    _done = true;
    try {
      await file.close();
    } catch (_) {}
    _pending.clear();
    await _dropTmp();
    _release();
  }

  Future<void> _dropTmp() async {
    _pending.clear();
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  void _release() {
    if (_released) return;
    _released = true;
    cache._releaseWriter(key);
  }
}
