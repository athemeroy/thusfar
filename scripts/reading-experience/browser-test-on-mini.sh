#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
export CHROME_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
cd /Users/athemeroy/projects/books-build/app
flutter --no-version-check test --platform chrome --no-pub --concurrency=1 --reporter expanded test/browser/web_shelf_and_notes_test.dart test/browser/web_reader_flows_test.dart test/browser/web_ai_cancellation_test.dart test/browser/web_ask_panel_test.dart test/browser/web_reader_customizations_test.dart > ../checks/browser-tests.log 2>&1
