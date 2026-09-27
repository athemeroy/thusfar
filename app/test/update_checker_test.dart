import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/update_checker.dart';

void main() {
  test(
    'stable GitHub release is newer than a prerelease of the same version',
    () {
      expect(isNewerStableRelease('2.0.0-dev.16 (35)', 'v2.0.0'), isTrue);
    },
  );

  test('build number does not trigger a repeated stable update', () {
    expect(isNewerStableRelease('2.0.0 (38)', 'v2.0.0'), isFalse);
    expect(isNewerStableRelease('2.0.0+38', 'v2.0.0'), isFalse);
  });

  test('only a higher stable version prompts', () {
    expect(isNewerStableRelease('2.0.0 (38)', 'v2.0.1'), isTrue);
    expect(isNewerStableRelease('2.1.0', 'v2.0.9'), isFalse);
    expect(isNewerStableRelease('2.0.0', 'v2.0.1-rc.1'), isFalse);
    expect(isNewerStableRelease('unknown', 'v2.0.1'), isFalse);
  });
}
