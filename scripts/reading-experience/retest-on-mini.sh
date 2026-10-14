#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
cd /Users/athemeroy/projects/books-build/app
flutter --no-version-check test --no-pub --concurrency=2 --reporter expanded test/auto_page_turner_test.dart test/reader_regression_test.dart test/people_search_test.dart test/adaptive_sheet_test.dart test/ask_sheet_test.dart test/marginalia_sheet_test.dart test/shelf_accessibility_test.dart test/notes_test.dart test/native_workspace_test.dart test/processing_test.dart test/shelf_organization_test.dart test/backup_test.dart > ../checks/native-retest.log 2>&1
