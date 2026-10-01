<p align="center">
  <img src="assets/brand/icon-1024.png" width="112" alt="Thusfar: an open book with a bookmark">
</p>

<h1 align="center">Thusfar · 页读</h1>

<p align="center">A novel reader that helps you remember the story, up to the page you’re on.</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases/latest">Download</a> ·
  <a href="https://athemeroy.github.io/thusfar/">Read in your browser</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="app/test/shots/01-shelf.png" width="260" alt="Bookshelf and reading progress">
  <img src="app/test/shots/02-reader.png" width="260" alt="Reading page with tappable names">
</p>

Import TXT or EPUB and read with adjustable typography, search, bookmarks, and notes. Optional AI guides connect characters, relationships, recaps, and book questions to cited passages. Lookups follow your reading position, including when you go back a chapter.

## Get started

1. Open the browser reader or install a client below. No Thusfar account is required. Browser imports are limited to 16 MB per book.
2. Import a book and start reading. For AI guides or questions, add your own model API key and start preparation from the book’s menu. Ordinary reading needs no model; prepared books can be read offline.
3. Export a library ZIP or single-book backup to move between clients. WebDAV offers manual snapshots, not automatic background sync. Pause preparation and wait for the current request before exporting.

| Platform | Installation |
| --- | --- |
| Android 8+ | Install the APK; the app is named 页读. |
| macOS 12+ | Open the DMG and drag Thusfar to Applications. First launch may require approval in Privacy & Security. |
| Windows 10/11 x64 | Use the installer or extract the portable ZIP. |
| Linux x64 | Extract the tar.gz and run `./thusfar`; requires GTK 3. |
| iOS / iPadOS 15+ | The IPA is unsigned; sign and sideload it with AltStore or SideStore. |

Android 2.0 has a separate library from 1.7.x. Export a backup from the old app and restore it in the new one.

## AI, privacy, and backups

- **Bring your own AI.** OpenAI-compatible, Gemini, and Claude-compatible APIs are supported. Calls may cost money; hosting the reader does not include model credits. [Gemini’s free tier](https://ai.google.dev/gemini-api/docs/pricing) has limits and may use submitted content to improve Google’s products. Browser providers must allow cross-origin requests (CORS).
- **Text leaves your device when you use AI.** Relevant passages go to your chosen provider. Installed clients may also use classifier.dev for checking; enabling Jev for a book sends passages to TypeSafe AI. A Jev key cannot replace the model key for browser guides.
- **Spoiler protection has limits.** Unread material is hidden by default, but AI output can be wrong. Browser guides are cited drafts; installed biographies have a separate verification process. Check the original passage before relying on an answer.
- **Your library is local.** Importing a book does not upload it to GitHub. Browser keys stay in tab memory and disappear on refresh; installed clients store keys in their private app directory. Clearing app or browser data can delete books. Projects on the same `athemeroy.github.io` origin share access to browser storage.
- **Keep backups private.** Library ZIPs include books and portable settings, but exclude separately entered API keys. Custom model URLs may still contain sensitive information. Browser WebDAV also requires CORS.

[Build and test](app/README.md) · [Self-host the web reader](docs/SELF-HOSTING.md) · [Contribute](CONTRIBUTING.md)

[MIT](LICENSE). Bundled fonts retain their own licenses.
