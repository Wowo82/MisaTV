import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/download/download_task.dart';

void main() {
  group('下载文件名清洗', () {
    test('Windows 非法字符换成下划线，中文保留', () {
      expect(sanitizeFileName('片名: 第1集/特别版?'), '片名_ 第1集_特别版_');
      expect(sanitizeFileName(r'a\b*c'), 'a_b_c');
    });

    test('空名与保留设备名有兜底', () {
      expect(sanitizeFileName('   '), 'video');
      expect(sanitizeFileName('CON'), 'CON_');
      expect(sanitizeFileName('com1.mp4'), 'com1.mp4_');
    });

    test('截断超长名并去掉结尾的点 / 空格', () {
      expect(sanitizeFileName('x' * 200).length, 80);
      expect(sanitizeFileName('abc...  '), 'abc');
    });
  });

  group('媒体地址判定', () {
    test('扩展名优先，其次 content-type', () {
      expect(guessMediaExtension('https://a/b/c.MP4?sig=1'), '.mp4');
      expect(
        guessMediaExtension('https://a/stream', contentType: 'video/webm'),
        '.webm',
      );
      expect(guessMediaExtension('https://a/play?id=1'), '.mp4');
    });

    test('m3u8 识别忽略 query', () {
      expect(looksLikeHls('https://a/live.m3u8?t=1'), isTrue);
      expect(
        looksLikeHls('https://a/live', contentType: 'application/mpegurl'),
        isTrue,
      );
      expect(looksLikeHls('https://a/movie.mp4'), isFalse);
    });

    test('字节数格式化', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('任务存档', () {
    test('JSON 往返保留进度、请求头与状态', () {
      final task = DownloadTask(
        id: '123',
        title: '折月亮',
        episode: '第1集',
        url: 'http://127.0.0.1:9978/play?p=abc',
        headers: const {'Referer': 'https://a.com', 'User-Agent': 'UA'},
        savePath: r'G:\tv\折月亮\第1集.ts',
        isHls: true,
        totalBytes: 1000,
        receivedBytes: 400,
        status: DownloadStatus.queued,
      )..detail = '3/12 片';
      final back = DownloadTask.fromJson(task.toJson());
      expect(back.id, '123');
      expect(back.title, '折月亮');
      expect(back.episode, '第1集');
      expect(back.url, task.url);
      expect(back.headers['Referer'], 'https://a.com');
      expect(back.savePath, task.savePath);
      expect(back.isHls, isTrue);
      expect(back.totalBytes, 1000);
      expect(back.receivedBytes, 400);
      expect(back.status, DownloadStatus.queued);
      expect(back.detail, '3/12 片');
    });

    test('未知状态按已暂停处理，缺字段不崩', () {
      final back = DownloadTask.fromJson({
        'id': 'x',
        'url': 'https://a/b.mp4',
        'savePath': r'G:\tv\b.mp4',
        'status': 'weird',
      });
      expect(back.status, DownloadStatus.paused);
      expect(back.title, isEmpty);
      expect(back.headers, isEmpty);
    });
  });

  group('HLS 清单解析', () {
    test('媒体清单：相对地址按 base 解析', () {
      final playlist = parseHlsPlaylist(
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXTINF:10,\n'
        'seg1.ts\n'
        '#EXTINF:10,\n'
        '/sub/seg2.ts\n'
        '#EXT-X-ENDLIST\n',
        baseUrl: 'https://cdn.example.com/hls/index.m3u8',
      );
      expect(playlist.segments, [
        'https://cdn.example.com/hls/seg1.ts',
        'https://cdn.example.com/sub/seg2.ts',
      ]);
      expect(playlist.variantUrl, isEmpty);
      expect(playlist.encrypted, isFalse);
    });

    test('主清单：选 BANDWIDTH 最高的一路', () {
      final playlist = parseHlsPlaylist(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
        'low.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080\n'
        'high.m3u8\n',
        baseUrl: 'https://cdn.example.com/hls/master.m3u8',
      );
      expect(playlist.segments, isEmpty);
      expect(playlist.variantUrl, 'https://cdn.example.com/hls/high.m3u8');
    });

    test('fMP4 初始化段与 AES-128 加密标记', () {
      final playlist = parseHlsPlaylist(
        '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:6,\n'
        'seg1.m4s\n',
        baseUrl: 'https://cdn.example.com/v/index.m3u8',
      );
      expect(playlist.encrypted, isTrue);
      expect(playlist.initSegment, 'https://cdn.example.com/v/init.mp4');
      expect(playlist.segments, ['https://cdn.example.com/v/seg1.m4s']);
    });

    test('METHOD=NONE 不算加密', () {
      final playlist = parseHlsPlaylist(
        '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=NONE\n'
        '#EXTINF:6,\n'
        'seg1.ts\n',
        baseUrl: 'https://cdn.example.com/v/index.m3u8',
      );
      expect(playlist.encrypted, isFalse);
    });
  });
}
