#!/usr/bin/env bash
set -euo pipefail
test "$(uname -m)" = arm64
export PATH="$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
cd /Users/athemeroy/projects/books-build/app
flutter --no-version-check test --no-pub --concurrency=2 --reporter expanded \
  test/reading_activity_test.dart test/read_aloud_test.dart test/reader_regression_test.dart test/people_search_test.dart test/adaptive_sheet_test.dart test/reading_overhaul_test.dart test/ask_sheet_test.dart test/marginalia_sheet_test.dart test/toc_search_test.dart test/toc_position_test.dart test/text_purification_test.dart test/shelf_accessibility_test.dart test/shelf_processing_action_test.dart test/notes_test.dart test/shelf_organization_test.dart test/backup_test.dart test/native_workspace_test.dart test/processing_test.dart test/typography_prefs_test.dart test/selection_bounds_test.dart > ../checks/native-tests.log 2>&1
