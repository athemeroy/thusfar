# Thusfar for Android

The app is a thin Java shell around a WebView. The actual reader — `server/`, `pipeline/` and `web/`
from the repository root — runs inside the app on Python 3.11 through [Chaquopy](https://chaquo.com/chaquopy/),
listening only on `127.0.0.1` with a random session secret. `android_bootstrap.py` starts it.

## Build

Requirements: JDK 17+, the Android SDK (platform 35) and a Python 3.11 on the build machine
(Chaquopy byte-compiles the bundled sources with it).

```bash
cd android
echo "sdk.dir=$ANDROID_HOME" > local.properties
YEDU_BUILD_PYTHON=$(which python3.11) ./gradlew assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk   (package com.yedu.zhupi.standaloneprobe)
```

The debug build uses a different application id, so it installs next to the release app.

## Release signing

Signing is optional and never read from the repository:

```bash
YEDU_SIGNING_STORE=/path/to/release.jks \
YEDU_SIGNING_PASSWORD_FILE=/path/to/password.txt \
YEDU_BUILD_PYTHON=$(which python3.11) ./gradlew assembleRelease
```

The keystore alias is `yedu`. Without those variables `assembleRelease` produces an unsigned APK.
Official releases on GitHub are signed with the maintainer's key; an APK you sign yourself cannot
update an installed official build (Android requires the same signature), so uninstall it first.

## Notes

- MOBI/AZW3 parsing is not bundled (the parser is GPL-3.0); the app asks users to convert to EPUB.
- Book processing runs in a foreground service so it survives the screen turning off; on Android 15+
  the system limits `dataSync` services per day, and a paused job resumes from its last saved passage.
- `tests/NavigationPolicyTest.java` checks which URLs the WebView may open; run it on the host JVM.
