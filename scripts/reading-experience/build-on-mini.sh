#!/usr/bin/env bash
set -euo pipefail
test "$(uname -m)" = arm64
work=/Users/athemeroy/projects/books-build
signing=$(mktemp -d /Users/athemeroy/.local/share/android-build/reading72-signing.XXXXXX)
trap 'rm -rf "$signing"' EXIT
chmod 700 "$signing"
scp -O nas:/volume2/docker/book/signing/yedu-release.jks "$signing/yedu-release.jks"
scp -O nas:/volume2/docker/book/signing/password "$signing/password"
chmod 600 "$signing/"*
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/Users/athemeroy/.local/share/thusfar-build/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$HOME/.local/share/thusfar-build/flutter/bin:$PATH"
export YEDU_SIGNING_STORE="$signing/yedu-release.jks"
export YEDU_SIGNING_PASSWORD_FILE="$signing/password"
export https_proxy=http://127.0.0.1:1080
export http_proxy=http://127.0.0.1:1080
export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/36.0.0/aapt2 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=1080 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=1080"
unset PUB_HOSTED_URL
cd "$work/app"
flutter --no-version-check build web --release --no-pub --target lib/main_web.dart --no-web-resources-cdn > ../checks/build-web.log 2>&1
python3 web/prepare_offline.py build/web >> ../checks/build-web.log 2>&1
flutter --no-version-check build apk --release --flavor probe --target-platform android-arm64 --build-number=72 --no-pub > ../checks/build-android.log 2>&1
apk=build/app/outputs/flutter-apk/app-probe-release.apk
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$apk" > "$work/checks/signature.txt"
"$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging "$apk" > "$work/checks/badging.txt"
python3 - <<'PY'
from pathlib import Path
import re,json,hashlib
work=Path('/Users/athemeroy/projects/books-build')
signer=re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-f]+)',(work/'checks/signature.txt').read_text()).group(1)
package=re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",(work/'checks/badging.txt').read_text()).groups()
assert package==('com.yedu.zhupi.v2probe','72','2.1.0'),package
assert signer=='2228582f6dfcccc2988ad53b8026b7be3d652fe661dd06ac95b119a318a29acc',signer
apk=work/'app/build/app/outputs/flutter-apk/app-probe-release.apk'
report=dict(build_host='mini',version=package[2],version_code=72,package=package[0],signer_sha256=signer,sha256=hashlib.sha256(apk.read_bytes()).hexdigest(),apk='yedu-2.1.0-reading72-arm64.apk')
(work/'checks/build-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
cp "$apk" "$work/yedu-2.1.0-reading72-arm64.apk"
