import 'package:test/test.dart';
import 'package:thusfar_core/src/pipeline/models.dart';

void main() {
  test('a short story on a phone takes the measured few minutes', () {
    // 故乡, 5060 characters, took about 3 minutes on the Xiaomi at 4.
    expect(deviceMinutes(5060, model: 'deepseek-flash+nothink'), 3);
  });

  test('longer books scale with length and with lower concurrency', () {
    final int four = deviceMinutes(200000, model: 'deepseek-flash')!;
    final int eight = deviceMinutes(
      200000,
      model: 'deepseek-flash',
      concurrency: 8,
    )!;
    expect(four, greaterThan(eight));
    expect(four, greaterThan(deviceMinutes(20000, model: 'deepseek-flash')!));
  });

  test('an unknown model gives no guess', () {
    expect(deviceMinutes(5060, model: 'my-local-model'), isNull);
  });
}
