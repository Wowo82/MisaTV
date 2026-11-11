import 'package:flutter/material.dart';

import '../../app.dart';
import '../../services/download/download_service.dart';
import '../../services/file_dialog_service.dart';
import '../../services/open_folder.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';

/// 下载管理：任务列表、进度、暂停 / 继续 / 取消、打开目录。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AppScope.of(context).downloadService;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            tooltip: '下载设置',
            onPressed: () => _showDownloadSettings(context),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '打开下载目录',
            onPressed: service.downloadDir.isEmpty
                ? null
                : () => _openFolder(context, service.downloadDir),
            icon: const Icon(Icons.folder_open_rounded),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final tasks = service.tasks;
          if (tasks.isEmpty) {
            return const EmptyState(
              icon: Icons.download_rounded,
              title: '还没有下载任务',
              message:
                  '在影片详情页点右上角的下载按钮，选中剧集即可加入队列：'
                  '直链 MP4 支持断点续传，m3u8 会按清单顺序合并成一个 .ts 文件。',
            );
          }
          return ListView.separated(
            // 底部多留一段：提示条浮在导航上方，滚到底时不会盖住最后一条的操作。
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            itemCount: tasks.length + 1,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _DirHint(path: service.downloadDir);
              }
              final task = tasks[index - 1];
              return _TaskCard(task: task, service: service);
            },
          );
        },
      ),
    );
  }
}

Future<void> _openFolder(BuildContext context, String path) async {
  if (path.trim().isEmpty) return;
  final ok = await openFolder(path);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('打不开目录，请手动前往：$path')));
  }
}

/// 下载设置：目前只有下载目录。
Future<void> _showDownloadSettings(BuildContext context) async {
  final app = AppScope.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: app,
        builder: (ctx, _) {
          final theme = Theme.of(ctx);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text('下载设置', style: theme.textTheme.titleLarge),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('下载目录'),
                subtitle: Text(
                  app.playerSettings.downloadDir.trim().isEmpty
                      ? '默认：应用数据目录下的 downloads'
                      : app.playerSettings.downloadDir,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickDownloadDir(ctx, app),
              ),
              const SizedBox(height: 10),
            ],
          );
        },
      ),
    ),
  );
}

Future<void> _pickDownloadDir(BuildContext context, AppState app) async {
  final current = app.playerSettings.downloadDir.trim();
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('下载目录'),
      content: Text(
        current.isEmpty
            ? '当前使用默认目录：应用数据目录/downloads。\n\n'
                  '只影响之后加入队列的任务，已开始的任务不会换目录。'
            : '当前目录：\n$current\n\n'
                  '只影响之后加入队列的任务，已开始的任务不会换目录。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('reset'),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop('pick'),
          child: const Text('选择文件夹'),
        ),
      ],
    ),
  );
  if (action == 'reset') {
    await app.setPlayerSettings(app.playerSettings.copyWith(downloadDir: ''));
    return;
  }
  if (action != 'pick') return;
  final path = await FileDialogService.pickDirectory(
    confirmButtonText: '选择下载目录',
  );
  if (path == null || path.trim().isEmpty) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(downloadDir: path.trim()),
  );
}

class _DirHint extends StatelessWidget {
  const _DirHint({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            Icons.sd_storage_outlined,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              path.isEmpty ? '下载目录未设置' : path,
              maxLines: 2,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.service});

  final DownloadTask task;
  final DownloadService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = _statusOf(theme);
    final showProgress =
        task.status == DownloadStatus.done ||
        task.status == DownloadStatus.running ||
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.paused;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.status == DownloadStatus.done
                    ? 1
                    : (task.totalBytes > 0 ? task.progress : null),
                minHeight: 4,
                backgroundColor: theme.colorScheme.onSurface.withValues(
                  alpha: 0.08,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _metaText(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                  ),
                ),
              ),
              ..._actions(context),
            ],
          ),
        ],
      ),
    );
  }

  (String, Color) _statusOf(ThemeData theme) {
    switch (task.status) {
      case DownloadStatus.queued:
        return ('等待中', theme.colorScheme.onSurfaceVariant);
      case DownloadStatus.running:
        return (
          task.detail.isEmpty ? '下载中' : '下载中 · ${task.detail}',
          theme.colorScheme.primary,
        );
      case DownloadStatus.paused:
        return ('已暂停', theme.colorScheme.tertiary);
      case DownloadStatus.done:
        return ('已完成', theme.colorScheme.primary);
      case DownloadStatus.failed:
        return (
          task.error.isEmpty ? '失败' : task.error,
          theme.colorScheme.error,
        );
    }
  }

  String _metaText() {
    if (task.status == DownloadStatus.failed && task.error.isNotEmpty) {
      return task.error;
    }
    final parts = <String>[_sizeText()];
    if (task.status == DownloadStatus.running && task.speedBps > 0) {
      parts.add('${formatBytes(task.speedBps.round())}/s');
    }
    return parts.join(' · ');
  }

  String _sizeText() {
    final received = formatBytes(task.receivedBytes);
    if (task.totalBytes <= 0) return received;
    return '$received / ${formatBytes(task.totalBytes)}';
  }

  List<Widget> _actions(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback onTap) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        icon: Icon(icon),
      );
    }

    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.running:
        return [
          button(Icons.pause_rounded, '暂停', () => service.pause(task.id)),
          button(Icons.close_rounded, '取消', () => _confirmCancel(context)),
        ];
      case DownloadStatus.paused:
        return [
          button(Icons.play_arrow_rounded, '继续', () => service.resume(task.id)),
          button(Icons.close_rounded, '取消', () => _confirmCancel(context)),
        ];
      case DownloadStatus.failed:
        return [
          button(Icons.refresh_rounded, '重试', () => service.resume(task.id)),
          button(
            Icons.delete_outline_rounded,
            '移除',
            () => service.remove(task.id),
          ),
        ];
      case DownloadStatus.done:
        return [
          button(
            Icons.folder_open_rounded,
            '打开所在目录',
            () => _openFolder(context, _parentDir(task.savePath)),
          ),
          button(
            Icons.delete_outline_rounded,
            '移除记录',
            () => service.remove(task.id),
          ),
        ];
    }
  }

  static String _parentDir(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index <= 0 ? path : path.substring(0, index);
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消下载'),
        content: Text('取消后已下载的分片会删除，需要重新下载：\n${task.displayName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续下载'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
    if (ok == true) await service.cancel(task.id);
  }
}
