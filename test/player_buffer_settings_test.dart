import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/user_data.dart';

void main() {
  group('播放缓冲设置', () {
    test('默认值：预缓冲 1s、最大 4s', () {
      final settings = PlayerSettings.fromJson({});
      expect(settings.bufferMinSec, 1.0);
      expect(settings.bufferMaxSec, 4.0);
    });

    test('copyWith → toJson → fromJson 往返保持设置', () {
      final settings = PlayerSettings.fromJson({}).copyWith(
        bufferMinSec: 2.5,
        bufferMaxSec: 30,
      );
      final restored = PlayerSettings.fromJson(settings.toJson());
      expect(restored.bufferMinSec, 2.5);
      expect(restored.bufferMaxSec, 30.0);
    });

    test('越界 / 非法值收敛到合法区间，旧配置缺字段走默认', () {
      final settings = PlayerSettings.fromJson({
        'bufferMinSec': -3,
        'bufferMaxSec': 9999,
      });
      expect(settings.bufferMinSec, 0.2);
      expect(settings.bufferMaxSec, 120.0);
    });

    test('copyWith 不传时保留已有缓冲设置', () {
      final settings = PlayerSettings.fromJson({}).copyWith(bufferMinSec: 3);
      final again = settings.copyWith(volume: 0.5);
      expect(again.bufferMinSec, 3.0);
      expect(again.bufferMaxSec, settings.bufferMaxSec);
    });

    // 边播边缓存已移除：老配置里残留的键必须被静默忽略，不能影响启动。
    test('旧配置里的 streamCache 字段被忽略', () {
      final settings = PlayerSettings.fromJson({
        'streamCache': true,
        'streamCacheMb': 4096,
        'bufferMaxSec': 8,
      });
      expect(settings.bufferMaxSec, 8.0);
      expect(settings.toJson().containsKey('streamCache'), isFalse);
    });
  });
}
