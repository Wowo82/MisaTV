import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../local_store.dart';
import 'download_task.dart';

/// 视频下载：串行队列 + 单文件断点续传 + HLS 逐片合并。
///
/// 只做「把地址落到本地文件」：直链 MP4 直接写盘；m3u8 按清单顺序拉分片
/// 拼成 `.ts`。带 AES-128 的加密流不处理 —— 宁可明确报错，也不产出坏文件。
class DownloadService extends ChangeNotifier {
  DownloadService({this.store});

  /// 任务存档用的本地存储；为空时纯内存（Web / 测试）。
  final LocalStore? store;

  final List<DownloadTask> _tasks = [];
  final Map<String, _Control> _controls = {};
  final Map<String, (int bytes, DateTime at)> _speedMarks = {};
  HttpClient? _client;
  String _defaultDir = '';
  String Function() _customDir = () => '';
  bool _pumping = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// 任务存档的落盘节流：进度回调很密，没必要每次都写 shared_preferences。
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 注入目录：`defaultDir` 是应用数据目录下的 downloads，
  /// `customDir` 由设置页的「下载目录」实时提供，非空时优先。
  void configure({required String defaultDir, String Function()? customDir}) {
    _defaultDir = defaultDir;
    _customDir = customDir ?? () => '';
  }

  /// 从存档恢复任务。
  ///
  /// 上次退出时处于「排队 / 下载中」的条目改回排队并自动续跑；用户主动暂停的
  /// 保持暂停；已完成 / 失败只保留最近若干条，防止列表越积越长。
  void load() {
    final raw = store?.downloadTasksJson ?? '';
    if (raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final restored = <DownloadTask>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final task = DownloadTask.fromJson(Map<String, Object?>.from(item));
        if (task.id.isEmpty || task.url.isEmpty || task.savePath.isEmpty) {
          continue;
        }
        if (task.status == DownloadStatus.running) {
          task.status = DownloadStatus.queued;
        }
        restored.add(task);
      }
      final unfinished = restored
          .where(
            (task) =>
                task.status == DownloadStatus.queued ||
                task.status == DownloadStatus.paused ||
                task.status == DownloadStatus.running,
          )
          .toList();
      final failed = restored
          .where((task) => task.status == DownloadStatus.failed)
          .take(20)
          .toList();
      final done = restored
          .where((task) => task.status == DownloadStatus.done)
          .take(30)
          .toList();
      _tasks
        ..clear()
        ..addAll([...unfinished, ...failed, ...done]);
      _lastPersist = DateTime.now();
      notifyListeners();
      if (_tasks.any((task) => task.status == DownloadStatus.queued)) {
        unawaited(_pump());
      }
    } catch (_) {
      // 存档损坏就当没有任务，不能拖累启动。
    }
  }

  /// 任务列表落盘：默认 2 秒节流，`force` 立即写。
  Future<void> _persist({bool force = false}) async {
    final target = store;
    if (target == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPersist).inMilliseconds < 2000) return;
    _lastPersist = now;
    try {
      await target.setDownloadTasksJson(
        jsonEncode([for (final task in _tasks.take(200)) task.toJson()]),
      );
    } catch (_) {}
  }

  String get downloadDir {
    final custom = _customDir().trim();
    return custom.isEmpty ? _defaultDir : custom;
  }

  DownloadTask? taskOf(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 加入队列；返回 null 表示没有可用目录 / 地址为空。
  ///
  /// [isHls] 由调用方按**原始**地址判定：需要 Cookie 的源会被换成
  /// `127.0.0.1/play?...` 中继地址，从那里看不出是不是 m3u8。
  Future<DownloadTask?> enqueue({
    required String title,
    required String episode,
    required String url,
    Map<String, String> headers = const {},
    String contentType = '',
    bool? isHls,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return null;
    final dir = downloadDir;
    if (dir.isEmpty) return null;
    final hls = isHls ?? looksLikeHls(target, contentType: contentType);
    final ext = hls
        ? '.ts'
        : guessMediaExtension(target, contentType: contentType);
    // 按剧名建子目录：下载目录/剧名/集名.ext，多部剧不会混在一起。
    final folder = sanitizeFileName(title);
    final base = sanitizeFileName(
      episode.trim().isEmpty ? '正片' : episode.trim(),
    );
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title.trim().isEmpty ? '未命名' : title.trim(),
      episode: episode.trim(),
      url: target,
      headers: Map<String, String>.from(headers),
      savePath: _uniquePath(dir, folder, base, ext),
      isHls: hls,
    );
    _tasks.insert(0, task);
    _notify(force: true);
    unawaited(_pump());
    return task;
  }

  String _uniquePath(String dir, String folder, String base, String ext) {
    final targetDir = folder.trim().isEmpty ? dir : p.join(dir, folder);
    var candidate = p.join(targetDir, '$base$ext');
    var index = 1;
    while (File(candidate).existsSync() ||
        _tasks.any((t) => t.savePath == candidate)) {
      candidate = p.join(targetDir, '$base ($index)$ext');
      index++;
    }
    return candidate;
  }

  void pause(String id) {
    final task = taskOf(id);
    if (task == null || !task.busy) return;
    _controls.putIfAbsent(id, _Control.new).paused = true;
    if (task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      _notify(force: true);
    }
  }

  void resume(String id) {
    final task = taskOf(id);
    if (task == null) return;
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    task.status = DownloadStatus.queued;
    task.error = '';
    _notify(force: true);
    unawaited(_pump());
  }

  Future<void> cancel(String id) async {
    final task = taskOf(id);
    if (task == null) return;
    final control = _controls.putIfAbsent(id, _Control.new);
    control.canceled = true;
    if (task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.paused) {
      task.status = DownloadStatus.failed;
      task.error = '已取消';
      await _deletePart(task);
      _notify(force: true);
    }
  }

  /// 从列表移除（下载中的任务要先暂停 / 取消）。
  void remove(String id) {
    final task = taskOf(id);
    if (task == null || task.busy) return;
    _tasks.remove(task);
    _controls.remove(id);
    _speedMarks.remove(id);
    _notify(force: true);
  }

  Future<void> _deletePart(DownloadTask task) async {
    try {
      final part = File('${task.savePath}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {}
    try {
      final parts = Directory('${task.savePath}.parts');
      if (await parts.exists()) await parts.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        DownloadTask? next;
        for (final task in _tasks) {
          if (task.status == DownloadStatus.queued) {
            next = task;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(DownloadTask task) async {
    final control = _controls.putIfAbsent(task.id, _Control.new)
      ..paused = false
      ..canceled = false;
    task.status = DownloadStatus.running;
    task.error = '';
    task.detail = '';
    task.speedBps = 0;
    _speedMarks.remove(task.id);
    _notify(force: true);
    try {
      var hls = task.isHls;
      if (!hls) {
        // URL 后缀不可靠：`/m3u8/109302?auth_key=...` 这类地址只有响应头
        // 或首行内容能说明它是清单，探测到就改走分片合并。
        hls = await _probeIsHls(task.url, task.headers);
        if (hls) {
          final dir = p.dirname(task.savePath);
          final base = p.basenameWithoutExtension(task.savePath);
          task.savePath = _uniquePath(dir, '', base, '.ts');
          task.detail = '识别为 HLS';
          _notify(force: true);
        }
      }
      await Directory(p.dirname(task.savePath)).create(recursive: true);
      if (hls) {
        await _runHls(task, control);
      } else {
        await _runFile(task, control);
      }
      if (control.canceled) {
        await _deletePart(task);
        task.status = DownloadStatus.failed;
        task.error = '已取消';
      } else if (control.paused) {
        task.status = DownloadStatus.paused;
      } else {
        final part = File('${task.savePath}.part');
        if (await part.exists()) await part.rename(task.savePath);
        task.status = DownloadStatus.done;
        task.detail = '';
        task.speedBps = 0;
        // 以磁盘上的最终文件为准：HLS 分片是边下边合并，只有这时才知道总大小。
        try {
          final size = await File(task.savePath).length();
          if (size > 0) {
            task.receivedBytes = size;
            task.totalBytes = size;
          }
        } catch (_) {}
        AppLog.i('download', '下载完成 ${p.basename(task.savePath)}');
      }
    } catch (error) {
      if (control.canceled) {
        await _deletePart(task);
        task.status = DownloadStatus.failed;
        task.error = '已取消';
      } else if (control.paused) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.error = '$error';
        AppLog.w('download', '下载失败 ${_hostOf(task.url)} | $error');
      }
    } finally {
      _speedMarks.remove(task.id);
      if (!task.busy) _controls.remove(task.id);
      _notify(force: true);
    }
  }

  /// 探测地址是不是 HLS 清单。
  ///
  /// 很多源的播放地址长这样：`https://host/m3u8/109302?auth_key=...`，
  /// 路径里没有 `.m3u8`，只看后缀会把清单文本当视频存下来。这里读响应头
  /// 和前 32 字节（`#EXTM3U`）判断；探测失败一律按普通文件处理，不阻断下载。
  Future<bool> _probeIsHls(String url, Map<String, String> headers) async {
    try {
      final response = await _get(url, headers, range: 'bytes=0-1023');
      final type = (response.headers.contentType?.mimeType ?? '').toLowerCase();
      if (type.contains('mpegurl')) {
        await response.drain<void>();
        return true;
      }
      final bytes = <int>[];
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = response.listen(
        (chunk) {
          bytes.addAll(chunk);
          if (bytes.length >= 32) {
            unawaited(sub.cancel());
            if (!done.isCompleted) done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future.timeout(const Duration(seconds: 8), onTimeout: () {});
      try {
        await sub.cancel();
      } catch (_) {}
      final head = utf8.decode(bytes.take(32).toList(), allowMalformed: true);
      return head.trimLeft().startsWith('#EXTM3U');
    } catch (_) {
      return false;
    }
  }

  /// 单文件：`<目标>.part` 写盘，下次从这里续传。
  Future<void> _runFile(DownloadTask task, _Control control) async {
    final part = File('${task.savePath}.part');
    var offset = 0;
    if (await part.exists()) {
      offset = await part.length();
    }
    if (offset > 0 && task.totalBytes > 0 && offset >= task.totalBytes) {
      return; // 上一轮其实已经写完，只差 rename。
    }
    final response = await _get(
      task.url,
      task.headers,
      range: offset > 0 ? 'bytes=$offset-' : null,
    );
    var append = offset > 0;
    if (offset > 0 && response.statusCode == 200) {
      // 服务端不认 Range：只能从头写，别把两份拼在一起。明确告诉用户，
      // 免得以为「续传又失败了」。
      append = false;
      offset = 0;
      task.detail = '服务器不支持续传，已从头开始';
      _notify(force: true);
    } else if (offset > 0 && response.statusCode != 206) {
      await response.drain<void>();
      throw '续传失败（HTTP ${response.statusCode}）';
    }
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw '下载失败（HTTP ${response.statusCode}）';
    }
    final length = response.contentLength;
    if (length > 0) task.totalBytes = length + offset;
    task.receivedBytes = offset;
    final sink = part.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var written = offset;
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        if (control.canceled || control.paused) {
          unawaited(sub.cancel());
          if (!done.isCompleted) done.complete();
          return;
        }
        try {
          sink.add(chunk);
        } catch (_) {
          unawaited(sub.cancel());
          if (!done.isCompleted) done.completeError('写入本地文件失败');
          return;
        }
        written += chunk.length;
        task.receivedBytes = written;
        _notify();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (control.canceled) throw const _CanceledException();
  }

  /// HLS：解析清单 → 逐片下载 → 顺序写进同一个 `.ts`。
  ///
  /// 不做分片级续传：恢复时删掉半截文件从头拼，避免片序错乱。
  Future<void> _runHls(DownloadTask task, _Control control) async {
    var playlistUrl = task.url;
    HlsPlaylist? playlist;
    for (var depth = 0; depth < 4; depth++) {
      final text = await _fetchText(playlistUrl, task.headers);
      final parsed = parseHlsPlaylist(text, baseUrl: playlistUrl);
      if (parsed.variantUrl.isEmpty) {
        playlist = parsed;
        break;
      }
      playlistUrl = parsed.variantUrl;
    }
    if (playlist == null || playlist.segments.isEmpty) {
      throw '清单里没有可下载的分片';
    }
    if (playlist.encrypted) {
      throw '该 HLS 带 AES-128 加密，暂不支持下载';
    }
    final urls = <String>[
      if (playlist.initSegment.isNotEmpty) playlist.initSegment,
      ...playlist.segments,
    ];
    task.totalBytes = 0;
    task.receivedBytes = 0;
    task.detail = '0/${urls.length} 片';
    // 分片先落在 `<目标>.parts/` 下，一片一个文件：中断或重启后只看哪些片
    // 已经存在，跳过不重下，这才是真正的断点续传。
    final partsDir = Directory('${task.savePath}.parts');
    await partsDir.create(recursive: true);
    var index = 0;
    try {
      for (var i = 0; i < urls.length; i++) {
        if (control.canceled) throw const _CanceledException();
        if (control.paused) return;
        final segment = File('${partsDir.path}${p.separator}$i.seg');
        if (await segment.exists()) {
          final length = await segment.length();
          if (length > 0) {
            task.receivedBytes += length;
            index = i + 1;
            task.detail = '$index/${urls.length} 片（续）';
            _notify();
            continue;
          }
          // 上次留下的空片，删掉重下。
          try {
            await segment.delete();
          } catch (_) {}
        }
        final response = await _get(urls[i], task.headers);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          throw '分片 ${i + 1} 下载失败（HTTP ${response.statusCode}）';
        }
        final sink = segment.openWrite();
        try {
          final done = Completer<void>();
          late StreamSubscription<List<int>> sub;
          sub = response.listen(
            (chunk) {
              if (control.canceled || control.paused) {
                unawaited(sub.cancel());
                if (!done.isCompleted) done.complete();
                return;
              }
              sink.add(chunk);
              task.receivedBytes += chunk.length;
              _notify();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (!done.isCompleted) done.completeError(error, stack);
            },
            cancelOnError: true,
          );
          await done.future;
        } catch (_) {
          // 半截分片不能留，否则下次会被误认为已下完。
          try {
            await sink.close();
          } catch (_) {}
          try {
            if (await segment.exists()) await segment.delete();
          } catch (_) {}
          rethrow;
        }
        await sink.close();
        index = i + 1;
        task.detail = '$index/${urls.length} 片';
        _notify(force: true);
      }
      if (control.canceled) throw const _CanceledException();
      if (control.paused) return;
      // 全部分片就绪：按顺序合并成一个文件。
      final part = File('${task.savePath}.part');
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      final out = part.openWrite();
      try {
        for (var i = 0; i < urls.length; i++) {
          final segment = File('${partsDir.path}${p.separator}$i.seg');
          if (!await segment.exists()) throw '第 ${i + 1} 片缺失，无法合并';
          await out.addStream(segment.openRead());
        }
      } finally {
        await out.close();
      }
      try {
        await partsDir.delete(recursive: true);
      } catch (_) {}
    } finally {
      // 暂停 / 失败保留分片目录，下次从断点继续；取消才清干净。
      if (control.canceled) {
        try {
          await partsDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<String> _fetchText(String url, Map<String, String> headers) async {
    final response = await _get(url, headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw '清单请求失败（HTTP ${response.statusCode}）';
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024 * 1024) break; // 清单不该这么大
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return const Latin1Codec(allowInvalid: true).decode(bytes);
    }
  }

  Future<HttpClientResponse> _get(
    String url,
    Map<String, String> headers, {
    String? range,
  }) async {
    final client = _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = false;
    final request = await client.openUrl('GET', Uri.parse(url));
    request.followRedirects = true;
    request.maxRedirects = 8;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    headers.forEach((key, value) {
      if (value.trim().isEmpty) return;
      try {
        request.headers.set(key, value);
      } catch (_) {}
    });
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  /// 进度通知按 200ms 节流：分片回调可能一秒几百次，逐次 notify 会拖垮 UI。
  void _notify({bool force = false}) {
    if (!force) {
      final now = DateTime.now();
      if (now.difference(_lastNotify).inMilliseconds < 200) return;
      _lastNotify = now;
    }
    _updateSpeeds();
    notifyListeners();
    // 进度、状态变化都顺手存一份，进程被强杀也能恢复。
    unawaited(_persist(force: force));
  }

  void _updateSpeeds() {
    final now = DateTime.now();
    for (final task in _tasks) {
      if (task.status != DownloadStatus.running) {
        task.speedBps = 0;
        continue;
      }
      final mark = _speedMarks[task.id];
      if (mark == null) {
        _speedMarks[task.id] = (task.receivedBytes, now);
        continue;
      }
      final ms = now.difference(mark.$2).inMilliseconds;
      if (ms < 500) continue;
      task.speedBps = (task.receivedBytes - mark.$1) * 1000 / ms;
      _speedMarks[task.id] = (task.receivedBytes, now);
    }
  }

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? '';

  @override
  void dispose() {
    for (final control in _controls.values) {
      control.canceled = true;
    }
    unawaited(_persist(force: true));
    _client?.close(force: true);
    _client = null;
    super.dispose();
  }
}

class _Control {
  bool paused = false;
  bool canceled = false;
}

class _CanceledException implements Exception {
  const _CanceledException();

  @override
  String toString() => '已取消';
}
