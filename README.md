<p align="center">
  <img src="app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="88" alt="Thusfar icon">
</p>

<h1 align="center">Thusfar</h1>

<p align="center">
  <b>A book reader that has only read as far as you.</b><br>
  Tap a name to see who they are as of your current page.
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases"><b>Download the apps</b></a>
</p>

## Read without spoilers

Long books are full of people. When a name returns hundreds of pages later, searching for it can reveal the ending. Thusfar builds a guide to the book and pins each fact to the place where it first becomes true. Moving back to an earlier page also moves the character cards, cast list and relationship graph back.

- Tap a name for a profile, aliases and relationships valid at your current page.
- Browse the relationship graph, search, notes, bookmarks and recaps.
- Ask a question about what you have read and open its cited passage.
- Import TXT or EPUB books and read offline.
- Prepare a character guide on your own device using a model API you configure. Preparation needs a connection; ordinary reading does not.

The 2.0 app uses Flutter for its interface and a Dart reading engine. Books, notes and model credentials stay in the app's local storage. Preparing a guide sends passages to the model provider you choose and may use classifier.dev for checks. There is no Thusfar account.

## Download

[Releases](https://github.com/athemeroy/thusfar/releases) contains the 2.0 preview for Android, macOS, Windows, Linux and iOS. The Android preview installs alongside 1.7.x and uses a separate library. To bring books over, export a backup in 1.7.x and restore it in 2.0.

| Platform | Download | Install |
| --- | --- | --- |
| Android 8+ | Preview APK | Install the APK. It appears as 页读 2.0 试用. |
| macOS 12+ | DMG | Drag Thusfar to Applications. The app is not notarized; use System Settings → Privacy & Security → Open Anyway on first launch. |
| Windows 10/11 x64 | Installer or portable ZIP | The installer is per user. Windows may show a SmartScreen warning for the unsigned app. |
| Linux x64 | tar.gz | Extract and run ./thusfar; GTK 3 is required. |
| iOS / iPadOS 15+ | Unsigned IPA | Sign and sideload with AltStore or SideStore. |

On a computer, you can also open a TXT or EPUB from Finder or Explorer with Thusfar. The original file remains where it is. Use arrow keys, Space, Page Up/Down or the mouse wheel to turn pages.

For the previous Android release, see [1.7.5](https://github.com/athemeroy/thusfar/releases/tag/v1.7.5). The 2.0 downloads are previews while device and upgrade coverage continues.

## Build from source

Flutter 3.47.5 and Dart 3.13.4 are the versions used for this release. Android builds also need JDK 17 and an Android SDK. From the repository root:

    cd app
    flutter pub get
    flutter run

Choose the target device with Flutter. The Android preview package uses the probe flavor:

    flutter build apk --release --flavor probe --target-platform android-arm64

The client code is in app/ (Flutter interface) and core/ (Dart reading engine). See [app/README.md](app/README.md) for development and validation details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Spoiler safety is the central correctness rule: information must remain behind its first valid reading position. Work on the 2.0 client has included contributions from Luna and Gemini Flash.

## License

[MIT](LICENSE). Bundled fonts retain their own license files.
