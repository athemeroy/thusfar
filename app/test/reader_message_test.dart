import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/ui/reader_message.dart';

void main() {
  test(
    'raw provider details stay out of the UI while cost remains visible',
    () {
      const String message = 'FormatException: 模型 JSON 无效，可能已计费。';
      expect(
        readerMessage(message, fallback: '回答未完成，请重试。'),
        '回答未完成，请重试。 本次可能已产生费用。',
      );
      expect(
        readerMessage(
          'SocketException at /tmp/private-file',
          fallback: '连接失败，请重试。',
        ),
        '连接失败，请重试。',
      );
    },
  );

  test('actionable reader messages keep their meaning', () {
    const String message = '服务余额不足，请充值后再试。已完成的内容已保留。';
    expect(readerMessage(message, fallback: '未完成'), message);
  });
}
