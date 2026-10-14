# Android processing runtime JVM tests

These tests compile the **current production Kotlin sources** in `../app/src/main/kotlin` directly. They use the real Flutter Android embedding pinned to Flutter 3.47.5, AndroidX Java libraries, and Robolectric 4.16 with Android API 35. No production source copies or generated Android build outputs are committed.

## Run

Prerequisites: Java 21 and Maven 3.9 or newer, with access to Maven Central, Google Maven, and Flutter's official artifact repository. No Flutter SDK, Android SDK, emulator, device, signing key, app installation, or model credentials are needed.

From the repository root:

```sh
mvn -B -f app/android/runtime-tests/pom.xml test
```

The first run downloads pinned compiler/framework dependencies. Results are in `app/android/runtime-tests/target/surefire-reports/`. To force recompilation from a clean state, use `clean test`.

If your environment requires a proxy, configure Maven's normal `settings.xml` proxy. Robolectric's framework download separately accepts `-Drobolectric.dependency.proxy.host=HOST -Drobolectric.dependency.proxy.port=PORT`. Never check credentials or environment-specific proxy settings into this directory.

## Coverage

- Foreground acknowledgment occurs after notification publication and CPU lease acquisition
- Start/promotion failures, startup watchdog, stop-before-create, and same-book canceled/superseded start generations
- Active/queued transitions, multi-book handoff, finite lease expiration and renewal, final stop, and destruction
- Android 15 timeout releases resources, rejects late progress before destruction, and survives listener errors
- Bounded diagnostic history does not store exception messages
- Multiple Activity host objects reuse the same app-owned Java FlutterEngine and do not request its destruction
- Required method channels exist before entrypoint launch, and stale import-owner detachment cannot remove a replacement owner's handler

## Scope and limitations

`ResourceStub.kt` substitutes only the generated `R.drawable.ic_stat_book` with a valid Android framework drawable. The application Kotlin code and Java Flutter embedding are real. Service behavior uses Robolectric's Android framework shadows. The engine tests explicitly shadow **FlutterJNI and FlutterLoader**, so **no Dart isolate, native Flutter/C++ code, real model work, device suspend, Doze/network policy, OEM task killing, or Android system-enforced foreground deadline is executed**. The host identity test uses separate Activity objects; it is not a physical-device Activity-destruction/recreation test.

The `android-all` implementation JAR exposes Android internal nullability annotations that the SDK stubs omit. The Kotlin compile ignores `android.annotation` nullability for this harness only; normal application compilation remains unchanged. Maven cannot perform Android Gradle AAR variant selection, so the exact AndroidX bytecode needed here is declared and unpacked explicitly into `target/`.

This is an independent signing-free regression suite, not an APK build or replacement for device tests. Match the Flutter embedding engine hash to the app's pinned Flutter SDK when upgrading. The normal app analyzer/Dart/Flutter suites and physical-device background/lifecycle checks remain separate gates.
