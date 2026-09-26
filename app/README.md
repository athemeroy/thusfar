# Thusfar Flutter app

Native Flutter reader for Android, using the pure Dart package in `../core`.
This is the active 2.0 development application. The 1.7.5 Python application
remains the behavioral oracle and released product until upgrade acceptance
is complete.

The reader provides a local bookshelf, TXT/EPUB and portable-backup import,
paginated reading, character cards, graph, chapter navigation, bookmarks,
notes, search, recaps, typography controls, model settings and grounded questions.
Questions use a captured reading cutoff; source citations open the corresponding
passage. An unverified model answer is withheld. A dedicated worker isolate now
runs the Dart processing engine, with explicit start/pause/resume/quality retry,
progress updates, and retained model-response caches. Startup reconciles
interrupted work without making paid requests automatically. Android can still
terminate the app; uninterrupted background operation is not yet a release claim.

Android VIEW/SEND file imports and the in-app picker share a serialized import
queue. Restored backups are validated before publication, conflicting existing
books are reported, and corrupt personal data cannot silently become an empty
export. A single Android task and foreground library refresh keep external imports
visible when returning from another application.

## Data and model configuration

`MainActivity` supplies Android `filesDir` over `thusfar/paths`. The app keeps the
1.7.x `files/yedu/` layout, including `books/`, `progress.json`, `reading-list.json`
and `.model.env`. Model credentials stay in that private app directory.
Do not package private libraries or credentials into build/test inputs.

The `probe` product flavor is `com.yedu.zhupi.v2probe` and has its own private
data, so it can coexist with `com.yedu.zhupi` 1.7.x. The `full` flavor uses the
original package. Matching the package and signing key is necessary for an
upgrade but does not prove data migration or interrupted-task acceptance.

## Build

Use the project-pinned Flutter SDK; see the current project `../STATUS.md` for
the validated revision. Android requires JDK 17 and the installed Android SDK.
On the home environment, run heavy builds on the home Mini rather than NAS.

```sh
flutter pub get
flutter build apk --release --flavor probe --target-platform android-arm64
```

The Gradle configuration reads `YEDU_SIGNING_STORE` and
`YEDU_SIGNING_PASSWORD_FILE`, or the existing NAS private signing paths. Without
those files it builds with the local debug key. For a Mini build, retrieve the
APK and sign it on NAS with the existing release key; never copy the signing key
to Mini. Verify the final signature and APK hash before installing with `-r`.

## Verification

```sh
flutter analyze --no-fatal-infos
flutter test test/import_test.dart test/ask_sheet_test.dart test/processing_test.dart \
  test/backup_test.dart test/shared_import_test.dart test/model_settings_test.dart
cd ../core
dart analyze --fatal-infos --fatal-warnings
dart test -j 1
```

`test/screens_test.dart` renders the real UI using offline reference books and
CJK fonts. It accepts `FLUTTER_ROOT` and `THUSFAR_TEST_SANS_FONT` so it can run on
the home Mini. Generated screenshot receipts belong in the dated run report;
`--update-goldens` produces review images and is not evidence that an old visual
baseline remained unchanged. Inspect the resulting images.

Core comparisons, widget checks, successful builds, actual device interaction,
and full 2.0 acceptance are separate milestones. Current evidence and remaining
work are recorded in `../STATUS.md` and `../docs/port/runs/`.
