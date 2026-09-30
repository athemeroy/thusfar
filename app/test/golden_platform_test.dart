import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';

import 'support/golden_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GoldenPlatform select(String version, {String? requested}) =>
      selectGoldenPlatform(
        operatingSystem: 'macos',
        productVersion: version,
        architecture: 'arm64',
        requestedPlatform: requested,
      );

  test('selects each reviewed OS generation explicitly', () {
    expect(select('15.7.9', requested: 'macos-15'), GoldenPlatform.macos15);
    expect(select('26.6.2', requested: 'macos-26'), GoldenPlatform.macos26);
    expect(select('26.6.2'), GoldenPlatform.macos26);
  });

  test('rejects a mismatched or unknown requested baseline', () {
    expect(() => select('26.6.2', requested: 'macos-15'), throwsStateError);
    expect(() => select('15.7.9', requested: 'macos-26'), throwsStateError);
    expect(() => select('26.6.2', requested: 'macos-latest'), throwsStateError);
  });

  test('rejects unreviewed OS versions and architectures', () {
    for (final String version in <String>['14.8', '27.0', 'unknown']) {
      expect(() => select(version), throwsStateError);
    }
    expect(
      () => selectGoldenPlatform(
        operatingSystem: 'macos',
        productVersion: '26.6.2',
        architecture: 'x86_64',
      ),
      throwsStateError,
    );
    expect(
      () => selectGoldenPlatform(
        operatingSystem: 'linux',
        productVersion: '26.6.2',
        architecture: 'arm64',
      ),
      throwsStateError,
    );
  });

  test('routes the same screenshot key to independent strict baselines', () {
    final Uri testFile = File('test/example_test.dart').absolute.uri;
    final PlatformGoldenFileComparator mac15 = PlatformGoldenFileComparator(
      testFile,
      platformResolver: () => GoldenPlatform.macos15,
    );
    final PlatformGoldenFileComparator mac26 = PlatformGoldenFileComparator(
      testFile,
      platformResolver: () => GoldenPlatform.macos26,
    );
    final Uri key = Uri.parse('shots/02-reader.png');
    expect(mac15.getTestUri(key, null), key);
    expect(mac26.getTestUri(key, null), Uri.parse('shots/macos-26/02-reader.png'));
    expect(mac26.getTestUri(key, 2), Uri.parse('shots/macos-26/02-reader.2.png'));
    expect(() => mac26.getTestUri(Uri.parse('../shots/a.png'), null),
        throwsArgumentError);
  });

  // Both fixtures are opaque 64x64 RGBA images. Only the first pixel's red
  // channel changes from 0 to 1: one of 4096 pixels (0.0244140625%).
  final Uint8List original = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAlklEQVR4nO3QQRHAMADD'
    'sKz8OXcw9KiFwOdv293Djg7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7Q'
    'GqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqAD'
    'tAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkD7AVC0AX8AKmT5'
    'AAAAAElFTkSuQmCC',
  );
  final Uint8List changed = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAnUlEQVR4nO3QMQHAMACE'
    'wE/9e05l3BBQAJyz3bt3+V6O37ZPC2gaoAU0DdACmgZoAU0DtICmAVpA0wAtoGmA'
    'FtA0QAtoGqAFNA3QApoGaAFNA7SApgFaQNMALaBpgBbQNEALaBqgBTQN0AKaBmgB'
    'TQO0gKYBWkDTAC2gaYAW0DRAC2gaoAU0DdACmgZoAU0DtICmAVpA0wAtoHl+wA+R'
    '6wN+eRyNqgAAAABJRU5ErkJggg==',
  );

  test('missing macOS 26 baseline never falls back to macOS 15', () async {
    final Directory root = Directory.systemTemp.createTempSync('golden-missing-');
    addTearDown(() => root.deleteSync(recursive: true));
    final Uri testFile = root.uri.resolve('example_test.dart');
    final PlatformGoldenFileComparator mac15 = PlatformGoldenFileComparator(
      testFile,
      platformResolver: () => GoldenPlatform.macos15,
    );
    final PlatformGoldenFileComparator mac26 = PlatformGoldenFileComparator(
      testFile,
      platformResolver: () => GoldenPlatform.macos26,
    );
    final Uri key = Uri.parse('shots/pixel.png');
    final Uri mac15Key = mac15.getTestUri(key, null);
    final Uri mac26Key = mac26.getTestUri(key, null);
    await mac15.update(mac15Key, original);
    expect(await mac15.compare(original, mac15Key), isTrue);
    expect(File.fromUri(root.uri.resolveUri(mac26Key)).existsSync(), isFalse);
    await expectLater(
      mac26.compare(original, mac26Key),
      throwsA(isA<TestFailure>()),
    );
  });

  test('one channel of one pixel still fails and keeps all diff images', () async {
    final Directory root = Directory.systemTemp.createTempSync('golden-strict-');
    addTearDown(() => root.deleteSync(recursive: true));
    final PlatformGoldenFileComparator comparator = PlatformGoldenFileComparator(
      root.uri.resolve('example_test.dart'),
      platformResolver: () => GoldenPlatform.macos26,
    );
    final Uri key = comparator.getTestUri(Uri.parse('shots/pixel.png'), null);
    await comparator.update(key, original);
    expect(File.fromUri(root.uri.resolveUri(key)).existsSync(), isTrue);
    expect(await comparator.compare(original, key), isTrue);
    await expectLater(
      comparator.compare(changed, key),
      throwsA(isA<FlutterError>()),
    );
    for (final String suffix in <String>[
      'masterImage', 'testImage', 'isolatedDiff', 'maskedDiff',
    ]) {
      expect(File('${root.path}/failures/pixel_$suffix.png').existsSync(), isTrue);
    }
    expect(File('${root.path}/shots/pixel.png').existsSync(), isFalse);
  });
}
