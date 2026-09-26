#!/bin/bash
# Run in the existing home Mini build workspace after staging explicit inputs.
set -euo pipefail

BUILD_ROOT="$HOME/.local/share/thusfar-build"
SOURCE_ROOT="$BUILD_ROOT/src"
LOG_ROOT="$BUILD_ROOT/receipts/${1:-20260926-continuation}"
export FLUTTER_ROOT="$BUILD_ROOT/flutter"
export PATH="$FLUTTER_ROOT/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export THUSFAR_TEST_SANS_FONT="$SOURCE_ROOT/test-support/NotoSansSC.ttf"
mkdir -p "$LOG_ROOT"

cd "$SOURCE_ROOT/core"
dart pub get > "$LOG_ROOT/core-pub.log" 2>&1
dart analyze --fatal-infos --fatal-warnings > "$LOG_ROOT/core-analyze.log" 2>&1
dart test -j 1 --reporter=json > "$LOG_ROOT/core-tests.jsonl" 2> "$LOG_ROOT/core-tests.stderr"
printf '核心分析与测试已通过\n'

cd "$SOURCE_ROOT/app"
flutter pub get > "$LOG_ROOT/app-pub.log" 2>&1
flutter analyze --no-fatal-infos > "$LOG_ROOT/app-analyze.log" 2>&1
flutter test --no-pub --concurrency=1 test/import_test.dart test/ask_sheet_test.dart test/processing_test.dart test/model_settings_test.dart test/backup_test.dart test/shared_import_test.dart --reporter=json > "$LOG_ROOT/app-tests.jsonl" 2> "$LOG_ROOT/app-tests.stderr"
printf '应用分析与交互测试已通过\n'
flutter test --concurrency=1 test/screens_test.dart --update-goldens > "$LOG_ROOT/screens.log" 2>&1
printf '界面截图已生成，等待目视检查\n'

bash "$BUILD_ROOT/build.sh" probe > "$LOG_ROOT/build.log" 2>&1
shasum -a 256 build/app/outputs/flutter-apk/app-probe-release.apk > "$LOG_ROOT/unsigned-apk.sha256"
printf '测试 APK 已编译，等待 NAS 签名与设备验证\n'
