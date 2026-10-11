#!/usr/bin/env bash
set -euo pipefail
test "$(uname -m)" = arm64
export PATH="$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
cd /Users/athemeroy/projects/books-build/app
mkdir -p ../checks
flutter --no-version-check pub get --offline --enforce-lockfile > ../checks/pub-get.log 2>&1
dart format lib test > ../checks/format.log 2>&1
flutter --no-version-check analyze --no-pub > ../checks/analyze.log 2>&1
