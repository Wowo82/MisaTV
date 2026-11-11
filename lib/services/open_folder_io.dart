import 'dart:io';

/// 用系统文件管理器打开目录；失败返回 false。
///
/// `url_launcher` 在 Windows 上对 `file://` 目录经常没反应（ShellExecute 会
/// 交给默认程序，而目录没有关联程序），所以桌面端直接调 explorer / open /
/// xdg-open。
Future<bool> openFolder(String path) async {
  final target = path.trim();
  if (target.isEmpty) return false;
  try {
    if (!await Directory(target).exists()) {
      // 目录可能刚被删：退一步打开它的上级，至少别什么都不发生。
      final parent = File(target).parent.path;
      if (!await Directory(parent).exists()) return false;
      return await _launch(parent);
    }
    return await _launch(target);
  } catch (_) {
    return false;
  }
}

Future<bool> _launch(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [path], mode: ProcessStartMode.detached);
      return true;
    }
    await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  }
}
