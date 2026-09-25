// Translated Python 1.7.5 release-boundary contracts.
// At C, the compiled Dart server package and retained Web shell own these checks.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _run(List<Map<String, Object?>> operations) =>
    callPorted('scripts.build_release.build', {
          // The C package test adapter creates source/{pipeline,server,web}
          // fixture.txt files and a validation receipt from the initial tree.
          // Operations run in order in one temporary source/release directory.
          'fixture': 'ReleaseBoundary.setUp',
          'operations': operations,
        })
        as Map<String, Object?>;

void main() {
  test(
    "tests.test_release.ReleaseBoundary.test_verified_snapshot_reused_and_data_credentials_excluded",
    () {
      final result = _run([
        {'action': 'write', 'path': '.env', 'text': 'not-for-release'},
        {
          'action': 'write',
          'path': 'data/private.txt',
          'text': 'not-for-release',
        },
        {'action': 'build', 'receipt': 'initial'},
        {'action': 'verifyRelease'},
        {'action': 'build', 'receipt': 'initial'},
      ]);
      expect(result['firstCreated'], isTrue);
      expect(result['releaseHasEnv'], isFalse);
      expect(result['releaseHasDataDirectory'], isTrue);
      expect(result['releaseDataEntries'], isEmpty);
      expect(result['verifiedSourceSha256'], result['sourceFingerprintSha256']);
      expect(result['secondReleasePath'], result['firstReleasePath']);
      expect(result['secondCreated'], isFalse);
    },
    skip:
        'C Dart self-hosted package builder and receipt validator are pending.',
  );
  test(
    "tests.test_release.ReleaseBoundary.test_changed_source_requires_new_validation",
    () {
      final result = _run([
        {'action': 'write', 'path': 'web/fixture.txt', 'text': 'changed'},
        {'action': 'build', 'receipt': 'initial'},
      ]);
      expect(result['error'], contains('validation'));
    },
    skip:
        'C Dart source fingerprint and validation receipt adapter are pending.',
  );
  test(
    "tests.test_release.ReleaseBoundary.test_private_runtime_file_and_symlink_rejected",
    () {
      final result = _run([
        {'action': 'write', 'path': 'server/.env', 'text': 'private'},
        {'action': 'inventory', 'resultKey': 'privateError'},
        {'action': 'delete', 'path': 'server/.env'},
        {
          'action': 'symlink',
          'path': 'web/outside',
          'target': 'validation.json',
        },
        {'action': 'inventory', 'resultKey': 'symlinkError'},
      ]);
      expect(result['privateError'], contains('private'));
      expect(result['symlinkError'], contains('symlink'));
    },
    skip: 'C Dart private-file and symlink rejection adapter is pending.',
  );
  test(
    "tests.test_release.ReleaseBoundary.test_tampering_refuses_existing_release_reuse",
    () {
      final result = _run([
        {'action': 'build', 'receipt': 'initial'},
        {
          'action': 'writeReleaseFile',
          'path': 'web/fixture.txt',
          'text': 'changed live files',
        },
        {'action': 'build', 'receipt': 'initial'},
      ]);
      expect(result['error'], contains('manifest'));
    },
    skip: 'C Dart release artifact integrity verification is pending.',
  );
  test(
    "tests.test_release.ReleaseBoundary.test_root_directory_symlink_is_rejected",
    () {
      final result = _run([
        {
          'action': 'replaceDirectoryWithSymlink',
          'path': 'pipeline',
          'target': 'outside',
        },
        {'action': 'inventory'},
      ]);
      expect(result['error'], contains('symlink'));
    },
    skip: 'C Dart source-root symlink rejection is pending.',
  );
  test(
    "tests.test_release.ReleaseBoundary.test_worker_stamp_changes_for_assets_and_logic_not_downloads",
    () {
      final result = _run([
        {
          'action': 'write',
          'path': 'web/sw.js',
          'text': "const SHELL = 'yedu-shell-v4';\n// worker logic\n",
        },
        {'action': 'stampShell'},
        {'action': 'stampShell'},
        {
          'action': 'write',
          'path': 'web/fixture.txt',
          'text': 'changed JavaScript or CSS',
        },
        {'action': 'stampShell'},
        {'action': 'stampShell'},
        {
          'action': 'writeBytes',
          'path': 'web/download/app.apk',
          'utf8': 'new APK is not shell content',
        },
        {'action': 'stampShell'},
        {
          'action': 'append',
          'path': 'web/sw.js',
          'text': '// changed worker logic\n',
        },
        {'action': 'stampShell'},
      ]);
      final stamps = (result['stamps'] as List<Object?>).cast<String>();
      expect(stamps, hasLength(6));
      expect(stamps[0], stamps[1]);
      expect(stamps[0], isNot(stamps[2]));
      expect(stamps[2], stamps[3]);
      expect(stamps[3], stamps[4]);
      expect(stamps[4], isNot(stamps[5]));
    },
    skip: 'C Dart Web service-worker stamp implementation is pending.',
  );
}
