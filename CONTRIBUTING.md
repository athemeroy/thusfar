# Contributing to Thusfar

The released product is the Flutter client in app/ and its Dart engine in core/. The Python and browser implementation is retained as a behavior reference for the port.

## What to preserve

1. **No spoilers.** Every generated fact needs a source position. Reading at an earlier position must hide facts introduced later, including search snippets, citations, notes and chapter titles.
2. **Local ownership.** Books, notes, progress and model credentials belong to the reader. An import or backup restore must report damage or conflicts instead of silently dropping data.
3. **Explicit model work.** Do not start paid model requests without a reader action. Display failures and incomplete processing clearly.
4. **Evidence for behavior changes.** Use a focused test or fixture for the actual regression. A successful build alone does not establish a safe reader interaction.

## Client checks

From the repository root:

    cd app
    flutter pub get
    flutter analyze --no-fatal-infos
    flutter test test/ask_sheet_test.dart test/backup_test.dart test/graph_view_test.dart test/import_test.dart test/manual_entities_test.dart test/marginalia_sheet_test.dart test/model_settings_test.dart test/notes_test.dart test/people_search_test.dart test/processing_test.dart test/reader_regression_test.dart test/selection_bounds_test.dart test/shared_import_test.dart
    cd ../core
    dart analyze --fatal-infos --fatal-warnings

Screenshot suites and device checks cover additional visual and platform behavior. Run the relevant ones for the change you make. Never commit personal books, keys or generated build output.
