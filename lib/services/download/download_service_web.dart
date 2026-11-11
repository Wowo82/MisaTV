import 'package:flutter/foundation.dart';

import 'download_task.dart';

/// Web 版下载桩：浏览器里没有可写的本地目录，只保留接口形态。
class DownloadService extends ChangeNotifier {
  DownloadService({Object? store});

  List<DownloadTask> get tasks => const [];

  /// 浏览器没有任务存档，恢复是空操作。
  void load() {}

  void configure({
    required String defaultDir,
    String Function()? customDir,
    String Function()? downloader,
  }) {}

  String get downloadDir => '';

  DownloadTask? taskOf(String id) => null;

  Future<DownloadTask?> enqueue({
    required String title,
    required String episode,
    required String url,
    Map<String, String> headers = const {},
    String contentType = '',
    bool? isHls,
  }) async => null;

  void pause(String id) {}

  void resume(String id) {}

  Future<void> cancel(String id) async {}

  void remove(String id) {}
}
