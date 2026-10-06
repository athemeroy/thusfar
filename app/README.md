# Build and test Thusfar

The Flutter client in this directory uses the Dart engine in `../core/`.
Use Flutter 3.47.5 / Dart 3.13.4. Android also requires JDK 17 and an Android SDK.

## Run and build

From `app/`:

```sh
flutter pub get
flutter run
flutter build apk --release --flavor probe --target-platform android-arm64
```

The Android `probe` flavor has its own app data and can coexist with 1.7.x.
Release signing is configured outside the repository. Never commit books,
API keys, signing credentials, or generated build output.

For a static browser build and deployment instructions, see
[Self-hosting](../docs/SELF-HOSTING.md).

## Checks

```sh
flutter analyze --no-fatal-infos
flutter test test/import_test.dart test/ask_sheet_test.dart test/processing_test.dart \
  test/backup_test.dart test/shared_import_test.dart test/model_settings_test.dart
cd ../core
dart analyze --fatal-infos --fatal-warnings
dart test -j 1
```

Run focused tests for the behavior you change. Device interaction and browser
checks are still needed for platform-specific behavior.

## Screenshot baselines

CI compares screenshots exactly on macOS 15 / arm64 and macOS 26 / arm64 using
the pinned Flutter SDK. Baselines live in `test/shots/` and `test/shots/macos-26/`.
`THUSFAR_GOLDEN_PLATFORM` must match the actual host (`macos-15` or `macos-26`).
Non-golden tests can run on other hosts.

For intentional visual changes, use the matching macOS host:

```sh
flutter test test/<affected_suite>_test.dart --update-goldens
flutter test test/<affected_suite>_test.dart
```

Inspect the changed images, update the macOS 26 manifest hashes when applicable,
and verify both CI platforms. Never loosen comparisons to accept a change.
Failed CI runs retain expected, actual, and diff images in the
`flutter-golden-diagnostics-macos-15` / `macos-26` artifacts.

Regression fixture checks are described in [reference/](../reference/README.md).

## Local TXT directory correction

In the native reader, open the directory and choose **修正 TXT 目录**. Confirmed
TXT imports support bounded Chinese/English/numbered heading presets and a
literal-prefix rule. Preview first, then apply to this book's directory and
chapter search; **恢复原目录** returns to the import's original directory.
Unread headings remain neutral until fully read, unless the exact original
heading already has a model-verified safe verdict.

This is a local navigation sidecar, not a reparse: source text, pagination,
canonical chapter indexes, notes, reading progress, and AI preparation/results
stay unchanged. It starts no model work. Current book exports, library ZIPs,
and WebDAV sync do not include the sidecar. Moving a book to the recycle bin
moves its sidecar with it; restoring that book retains the correction, while a
fresh import starts with its original directory.
