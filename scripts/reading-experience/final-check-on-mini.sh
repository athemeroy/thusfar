#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
export CHROME_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
cd /Users/athemeroy/projects/books-build/app
dart format lib test > ../checks/format-first.log 2>&1
dart fix --apply --code=use_null_aware_elements,curly_braces_in_flow_control_structures,unnecessary_import,unnecessary_brace_in_string_interps > ../checks/fix-style.log 2>&1
dart format lib test > ../checks/format-final.log 2>&1
flutter --no-version-check analyze --no-pub > ../checks/analyze-final.log 2>&1
flutter --no-version-check test --platform chrome --no-pub --reporter expanded test/browser/web_reader_flows_test.dart test/browser/web_ask_panel_test.dart test/browser/web_reader_customizations_test.dart --name 'bookmark toggle affects|verified selected evidence|WebDAV upload and confirmed' > ../checks/browser-retest.log 2>&1
