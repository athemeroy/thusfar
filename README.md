<p align="center">
  <img src="assets/brand/icon-1024.png" width="112" alt="Thusfar icon: an open book with a bookmark at the current page">
</p>

<h1 align="center">Thusfar · 页读</h1>

<p align="center"><strong>Stay in the story. Never read ahead by accident.</strong></p>

<p align="center">
  Open a name, follow a relationship, or ask what happened. Every answer ends at your current page.
</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases/latest"><strong>Download 2.0</strong></a>
  &nbsp;·&nbsp; <a href="https://athemeroy.github.io/thusfar/"><strong>Read in your browser</strong></a>
  &nbsp;·&nbsp; <a href="#see-it-in-action">See the app</a>
  &nbsp;·&nbsp; <a href="README.zh-CN.md">简体中文</a>
</p>

---

A long novel brings back names you have not seen for hundreds of pages. Looking one up on the web can give away the ending. Thusfar marks where each clue first appears. Character cards, relationships, recaps, and answers stop at your current reading position. Go back a chapter, and they go back with you.

## See it in action

<p align="center">
  <img src="app/test/shots/01-shelf.png" width="260" alt="Bookshelf and reading progress">
  &nbsp;
  <img src="app/test/shots/02-reader.png" width="260" alt="Reading page with tappable names">
</p>

<p align="center"><sub>Your library · A page with names you can open</sub></p>

- **Tap a name.** See a character's identity, aliases, appearances, and relationships, then check the original passage.
- **Catch up without looking ahead.** The cast list, relationship graph, recaps, and questions share the same reading cutoff. Answers link back to cited passages.
- **Make the book yours.** Import TXT or EPUB, take notes, add bookmarks, and search. Adjust type size, line spacing, letter spacing, and page margins to fit your screen. Your books and reading history stay on your device.
- **Stay with the page.** Reading controls appear over the page without moving the text. Cover page turns follow your gesture and settle smoothly when you let go.
- **Choose your own model.** Add a model API to prepare character guides. If free checking is unavailable, you can let one book continue using your configured model or TypeSafe AI's Jev API, or add a funded classifier.dev workspace key. Each credential is stored separately; Jev use requires an explicit choice for each book, with a visible allowance you can extend. Preparation uses a connection; everyday reading works offline.
- **Keep your place while preparing.** Short network outages retry automatically without discarding completed work. Open a book's details to see the current step, resume processing, or export a diagnostic record that excludes book text and API keys.

## Download

Get the installation file for your device from the [latest release](https://github.com/athemeroy/thusfar/releases/latest).

You can also [open the browser reader](https://athemeroy.github.io/thusfar/) without installing anything. Import TXT or EPUB up to 16 MB, read, search, bookmark, take notes, and tune the typography. The browser stores books and progress locally; it does not store model API keys. Use the book menu to export a JSON backup and import it in another browser. The web reader currently does not run character preparation, relationship graphs, recaps, or book questions; use an installed client for those features. Browser storage may be cleared by the browser or device, so export books you want to keep. GitHub Pages projects on the same `athemeroy.github.io` host share a browser origin and can access that origin's storage.

| Platform | File | Installation |
| --- | --- | --- |
| Web | [Open Thusfar](https://athemeroy.github.io/thusfar/) | Open in a current browser; no installation or account. |
| Android 8+ | APK | Install the APK. The app appears as 页读. |
| macOS 12+ | DMG | Drag Thusfar to Applications. You may need to allow its first launch in Privacy & Security. |
| Windows 10/11 x64 | Installer or portable ZIP | Install for your user account or extract the ZIP. |
| Linux x64 | tar.gz | Extract and run `./thusfar`; GTK 3 is required. |
| iOS / iPadOS 15+ | Unsigned IPA | Sign and sideload with AltStore or SideStore. |

Android 2.0 can coexist with 1.7.x; each app has its own library. To move books over, export a backup in 1.7.x and restore it in 2.0. [Version 1.7.5 remains available](https://github.com/athemeroy/thusfar/releases/tag/v1.7.5).

## Your data

There is no required Thusfar account or Thusfar server. Books, notes, and model credentials are stored locally in the client. When you choose to prepare a guide, relevant passages go to the model provider you configure and may be checked with classifier.dev. If you enable Jev for that book, relevant passages also go to TypeSafe AI. Choose a provider that suits your privacy needs.

## Build from source

The client consists of the Flutter interface in `app/` and the Dart reading engine in `core/`. The 2.0 release uses Flutter 3.47.5 / Dart 3.13.4. Android builds also need JDK 17 and an Android SDK.

```sh
cd app
flutter pub get
flutter run
```

The Android 2.0 package uses the `probe` build flavor:

```sh
flutter build apk --release --flavor probe --target-platform android-arm64
```

To build the static browser client for this repository's GitHub Pages path:

```sh
flutter build web --release --target lib/main_web.dart --base-href /thusfar/
```

See the [client guide](app/README.md) for development and checks, and [CONTRIBUTING.md](CONTRIBUTING.md) to contribute. Thanks to Luna and Gemini Flash for their contributions to the 2.0 client.

## License

[MIT](LICENSE). Bundled fonts retain their own licenses.
