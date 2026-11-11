/// Web 版没有本地文件管理器，直接返回失败。
Future<bool> openFolder(String path) async => false;
