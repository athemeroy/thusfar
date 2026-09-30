import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

enum GoldenPlatform { macos15, macos26 }

GoldenPlatform selectGoldenPlatform({
  required String operatingSystem,
  required String productVersion,
  required String architecture,
  String? requestedPlatform,
}) {
  if (operatingSystem != 'macos' || architecture != 'arm64') {
    throw StateError('Reviewed goldens require macOS arm64; got '
        '$operatingSystem / $architecture.');
  }
  final GoldenPlatform platform;
  final String label;
  switch (productVersion.split('.').first) {
    case '15':
      platform = GoldenPlatform.macos15;
      label = 'macos-15';
    case '26':
      platform = GoldenPlatform.macos26;
      label = 'macos-26';
    default:
      throw StateError('No reviewed goldens for macOS $productVersion.');
  }
  if (requestedPlatform != null && requestedPlatform != label) {
    throw StateError('THUSFAR_GOLDEN_PLATFORM=$requestedPlatform does not '
        'match this host ($label).');
  }
  return platform;
}

GoldenPlatform hostGoldenPlatform() {
  if (!Platform.isMacOS) {
    throw StateError('Screenshot comparisons require a reviewed macOS host.');
  }
  String readHostValue(String command, List<String> arguments) {
    final ProcessResult result = Process.runSync(command, arguments);
    if (result.exitCode != 0) {
      throw StateError('Could not establish the golden rendering environment.');
    }
    return (result.stdout as String).trim();
  }

  return selectGoldenPlatform(
    operatingSystem: Platform.operatingSystem,
    productVersion: readHostValue('/usr/bin/sw_vers', <String>['-productVersion']),
    architecture: readHostValue('/usr/bin/uname', <String>['-m']),
    requestedPlatform: Platform.environment['THUSFAR_GOLDEN_PLATFORM'],
  );
}

// Only the golden file URI changes. Pixel comparison and failure output stay
// Flutter's unmodified, exact LocalFileComparator implementation.
class PlatformGoldenFileComparator extends LocalFileComparator {
  PlatformGoldenFileComparator(
    super.testFile, {
    GoldenPlatform Function()? platformResolver,
  }) : _platformResolver = platformResolver ?? hostGoldenPlatform;

  final GoldenPlatform Function() _platformResolver;
  GoldenPlatform? _platform;

  @override
  Uri getTestUri(Uri key, int? version) {
    if (key.isAbsolute ||
        !key.path.startsWith('shots/') ||
        key.pathSegments.contains('..')) {
      throw ArgumentError.value(key, 'key', 'Expected a relative shots/ URI');
    }
    // Resolve lazily, so non-golden functional tests can still run on Linux or
    // another development host. Unknown hosts fail at the screenshot assertion.
    final GoldenPlatform platform = _platform ??= _platformResolver();
    final Uri platformKey = platform == GoldenPlatform.macos26
        ? key.replace(path: 'shots/macos-26/${key.path.substring(6)}')
        : key;
    return super.getTestUri(platformKey, version);
  }
}
