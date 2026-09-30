# Thusfar Flutter app

Flutter reader for Android, macOS, Windows, Linux, iOS and the browser, using the pure Dart
package in `../core`. This is the active 2.0 client.
The Python implementation remains a behavioral reference in the source tree.

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

Installed and browser clients exchange a whole-library ZIP containing full book
backups and portable settings. A single-book JSON backup remains available.
Same-book restores merge compatible reading records and report conflicts;
native merges save a local rollback snapshot before writing. Separately entered
API keys are excluded from the ZIP and must be entered again at the destination.
Both clients also support manual, append-only WebDAV snapshots in a user-owned
HTTPS collection. Credentials stay in the open WebDAV screen. This does not run
unattended background sync.

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

Use Flutter 3.47.5 / Dart 3.13.4. Android requires JDK 17 and an Android SDK.
On the home environment, run heavy builds on the home Mini rather than NAS.

```sh
flutter pub get
flutter build apk --release --flavor probe --target-platform android-arm64
```

The browser entrypoint is `lib/main_web.dart`. It shares the TXT/EPUB parser
and visual theme with the native app, while keeping books, progress, bookmarks,
notes, and preparation drafts in browser IndexedDB. Same-origin Pages deployments
retain that database, including its versioned schema upgrades. Its build is
static and needs no Thusfar server:

```sh
flutter build web --release --target lib/main_web.dart --base-href /thusfar/
```

GitHub Actions publishes `app/build/web` through `pages.yml` when Pages is set
to **GitHub Actions** in repository settings. The browser reader supports TXT,
EPUB, search, notes, bookmarks, reading progress, typography, whole-library ZIP
and single-book JSON transfer, manual WebDAV snapshots, browser AI preparation
and book questions linked to exact excerpts from the already-read text.
Its browser AI flow produces cited drafts of character facts, relationships,
and chapter recaps from explicitly chosen chapters using a user-supplied
browser-accessible OpenAI, Gemini, or Claude-compatible API. Provider presets
and editable endpoint/model fields match the installed client. It checkpoints
completed passages in IndexedDB;
it does not auto-resume billable work after refresh. The key stays in tab memory,
while the backup includes drafts but no key. The panel also exports a compact
diagnostic record without book text or credentials. Browser WebDAV requires
CORS permission for the page origin and OPTIONS, PROPFIND, GET and PUT. Native
biographies use a separate verification pipeline. Model calls may be billed by
the provider. Do not pass private API keys or book files to the web build.

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

CI runs the same functional tests and all 31 exact screenshot comparisons on
**macOS 15 / arm64** and **macOS 26 / arm64**, with Flutter **3.47.5**. macOS 15
uses the original `test/shots/*.png`; macOS 26 uses the independently reviewed
`test/shots/macos-26/*.png`. Its `manifest.json` records source-run provenance,
image hashes and the measured differences from the macOS 15 baseline. These
measurements are review evidence, never an allowed error threshold.

The comparator reads the actual macOS product version and CPU architecture.
`THUSFAR_GOLDEN_PLATFORM=macos-15` or `macos-26`, when supplied, must match that
host; an unknown or mismatched renderer fails instead of selecting a fallback.
Non-golden tests can still run on other development hosts. Both variants retain
Flutter's exact `LocalFileComparator`, including failure-image output.

After a failed client-check run, download `flutter-golden-diagnostics-macos-15`
or `flutter-golden-diagnostics-macos-26`. Each keeps expected/actual/diff images
and an OS, architecture, Flutter and font-hash receipt for 14 days. Compare the
images before changing a baseline. Browser success does not replace these tests.

For an intentional screenshot change, on the matching arm64 macOS host and the
pinned Flutter SDK, set `THUSFAR_GOLDEN_PLATFORM` to that host's label and run
`flutter test test/<affected_suite>_test.dart --update-goldens` from `app/`.
Review only the affected images against the prior baseline, refresh their
provenance/hashes in the macOS 26 manifest when applicable, then run the same
suite normally without `--update-goldens`. Repeat on the other supported OS and
require the full CI matrix. Never generate baselines in CI or use an OS upgrade
as permission to accept changed layout, text, wrapping or controls.

Core comparisons, widget checks, successful builds, actual device interaction,
and full 2.0 acceptance are separate milestones. Development evidence is recorded
in `../STATUS.md` and `../docs/port/runs/`.
