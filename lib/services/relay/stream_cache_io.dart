import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 播放中继的磁盘缓存。
///
/// 「边播边缓存」把播放器已经下行的分片顺手写到本地：重新拖回看过的位置、
/// 或者第二天重看同一集时，直接读盘不再回源。
///
/// 仿夸克的做法：**播放优先，缓存尽力而为**。三条约束保证它不会把内存吃掉：
///   · **写入不挡转发**：落盘走旁路队列，[StreamCacheWriter.enqueue] 只入队，
///     转发链路从不等磁盘 —— 播放器永远按网络速度走；
///   · **队列有硬上限**：每个分片最多在内存里排 512KB，磁盘吞吐低于网络就
///     整条放弃缓存，内存不会随播放时长或磁盘状态失控；
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

/// 写入器：把转发给播放器的字节顺手写进 `<key>.tmp`，
/// 流正常结束后 rename 成正式条目并记录 content-type。
///
/// 仿夸克的关键点：**转发路径不等磁盘**。
/// 数据以文件为唯一载体，内存里只排着还没落盘的那几块 —— 队列满了就整个
/// 分片放弃缓存，播放继续。这样磁盘再慢，内存也有确定的上界。
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

  /// 每个写入器在内存里最多排 512KB。
  ///
  /// 磁盘吞吐低于网络（机械盘、杀软实时扫描、SMB 挂载）时，多出来的分片
  /// 直接放弃缓存 —— 播放照常，内存也不会跟着磁盘状态失控。
  /// 想更激进地省内存可以调到 128KB，代价是慢盘上更容易放弃。
  static const int maxQueuedBytes = 512 * 1024;

  final Queue<List<int>> _queue = Queue<List<int>>();
  int _queued = 0;
  int _written = 0;
  bool _done = false;
  bool _dropped = false;
  bool _pumping = false;
  bool _released = false;
  Completer<void>? _idle;

  /// 入队一块字节，**立即返回**。
  ///
  /// 刻意做成同步方法：调用方在转发循环里直接调，绝不让播放器等磁盘。
  void enqueue(List<int> chunk) {
    if (_done || _dropped) return;
    if (_queued + chunk.length > maxQueuedBytes) {
      // 队列满：这个分片不缓存了。已排队的数据一并丢掉，
      // 免得留下一个不完整的文件被当成完整缓存命中。
      _dropped = true;
      _queue.clear();
      _queued = 0;
      return;
    }
    _queue.add(chunk);
    _queued += chunk.length;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_dropped) {
        final chunk = _queue.removeFirst();
        _queued -= chunk.length;
        await file.writeFrom(chunk);
        _written += chunk.length;
      }
    } catch (_) {
      // 磁盘满 / 文件被占用：放弃缓存，不影响已经在播的流。
      _dropped = true;
      _queue.clear();
      _queued = 0;
    } finally {
      _pumping = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
      // 退出循环的瞬间可能刚好有新块入队，这里补一次。
      if (_queue.isNotEmpty && !_dropped) unawaited(_pump());
    }
  }

  /// 等队列写空。只有收尾（commit）需要，转发路径从不调用。
  Future<void> _drain() async {
    while (_pumping) {
      final idle = _idle ??= Completer<void>();
      await idle.future;
    }
    if (_queue.isNotEmpty && !_dropped) await _pump();
  }

  Future<void> commit() async {
    if (_done) return;
    await _drain();
    _done = true;
    if (_dropped) {
      // 已经放弃这个分片：先关句柄再删，Windows 上删一个还开着的文件会失败，
      // 留下删不掉的 .tmp（还会连带泄漏一个句柄）。
      try {
        await file.close();
      } catch (_) {}
      await _dropTmp();
      _release();
      return;
    }
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
    _dropped = true;
    _queue.clear();
    _queued = 0;
    // 等在途那次 writeFrom 落完再关句柄：Windows 上删一个正被写入的
    // 文件会失败，留一堆删不掉的 .tmp 比不缓存更糟。
    while (_pumping) {
      final idle = _idle ??= Completer<void>();
      await idle.future;
    }
    try {
      await file.close();
    } catch (_) {}
    await _dropTmp();
    _release();
  }

  Future<void> _dropTmp() async {
    _queue.clear();
    _queued = 0;
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
