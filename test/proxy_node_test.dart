import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/proxy_node.dart';

void main() {
  group('proxy.txt 解析', () {
    test('socks5 / http / https 三种前缀，https 归为 http', () {
      final nodes = parseProxyList(
        '# 代理列表更新时间: 2026-11-10 15:00:05\n'
        '\n'
        'socks5://13.140.215.192:1080    入库时间：11-10 14:26\t[机房] 法国 — Contabo\n'
        'http://1.2.3.4:8080 入库时间：11-10 10:00 [家宽] 越南 河内\n'
        'https://5.6.7.8:3128 入库时间：11-10 09:00 [机房] 美国\n',
      );
      expect(nodes.length, 3);
      expect(nodes[0].type, 'socks5');
      expect(nodes[0].host, '13.140.215.192');
      expect(nodes[0].port, 1080);
      expect(nodes[0].label, contains('法国'));
      // 「入库时间」只是抓取时间，不该混进备注。
      expect(nodes[0].label, isNot(contains('入库时间')));
      expect(nodes[1].type, 'http');
      expect(nodes[1].label, contains('家宽'));
      expect(nodes[2].type, 'http');
    });

    test('跳过脱敏地址、非法端口与重复项', () {
      final nodes = parseProxyList(
        'socks5://27.77.X.92:1020\n'
        'socks5://1.2.3.4:0\n'
        'socks5://1.2.3.4:99999\n'
        'socks5://1.2.3.4:1080\n'
        'socks5://1.2.3.4:1080\n',
      );
      expect(nodes.length, 1);
      expect(nodes.first.address, '1.2.3.4:1080');
    });

    test('没有协议前缀的裸地址不猜', () {
      expect(parseProxyList('1.2.3.4:8080\n').isEmpty, isTrue);
    });
  });

  group('ProxyNode', () {
    test('JSON 往返保留延时与手动标记', () {
      const node = ProxyNode(
        type: 'socks5',
        host: '1.2.3.4',
        port: 1080,
        label: '测试节点',
        manual: true,
        latencyMs: 123,
        testedAt: 456,
      );
      final back = ProxyNode.fromJson(node.toJson());
      expect(back.type, 'socks5');
      expect(back.host, '1.2.3.4');
      expect(back.port, 1080);
      expect(back.label, '测试节点');
      expect(back.manual, isTrue);
      expect(back.latencyMs, 123);
      expect(back.testedAt, 456);
    });

    test('id / address / 类型标签', () {
      const node = ProxyNode(type: 'http', host: '8.8.8.8', port: 8080);
      expect(node.id, 'http://8.8.8.8:8080');
      expect(node.address, '8.8.8.8:8080');
      expect(node.typeLabel, 'HTTP');
      expect(node.reachable, isFalse);
      expect(node.copyWith(latencyMs: 50).reachable, isTrue);
    });
  });
}
