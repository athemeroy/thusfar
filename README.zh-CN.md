<p align="center">
  <img src="assets/brand/icon-1024.png" width="112" alt="页读图标：翻开的书与标记当前阅读位置的红色书签">
</p>

<h1 align="center">页读 · Thusfar</h1>

<p align="center"><strong>安心读下去，不被提前剧透。</strong></p>

<p align="center">
  点开人名、追踪关系、回顾情节。所有答案都停在你读到的这一页。
</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases/latest"><strong>下载 2.0 正式版</strong></a>
  &nbsp;·&nbsp; <a href="#它怎样陪你读书">看看界面</a>
  &nbsp;·&nbsp; <a href="README.md">English</a>
</p>

---

读长篇小说时，最怕的往往不是忘记一个名字，而是为了查这个名字，提前看到了他的结局。页读给书里的线索标上首次出现的位置。你翻到哪里，人物卡、关系图和问答就只看到哪里；退回前面的章节，它们也跟着退回去。

## 它怎样陪你读书

<p align="center">
  <img src="app/test/shots/01-shelf.png" width="260" alt="页读书架，显示书籍和阅读进度">
  &nbsp;
  <img src="app/test/shots/02-reader.png" width="260" alt="阅读页中可点开的人名">
</p>

<p align="center"><sub>书架 · 书页上可点开的人名</sub></p>

- **遇到人名，点一下。** 看人物身份、别名、出场和关系，并跳回原文核对。
- **回顾剧情，不越界。** 人物表、关系图、前情提要和问答遵守同一条阅读进度线；问答附有可打开的原文引用。
- **把阅读留在自己手里。** 导入 TXT / EPUB，做摘记、加书签、搜索。字号、行距、字距和页边距都能细调，适配手机与折叠屏；书籍和阅读记录保存在设备本地。
- **自己选择模型。** 需要整理人物资料时，填入自己的模型接口。整理过程需要联网，日常阅读可以离线进行。

## 下载客户端

从 [最新发布页](https://github.com/athemeroy/thusfar/releases/latest) 下载适合设备的安装文件。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| Android 8+ | APK | 安装后显示为“页读”。 |
| macOS 12+ | DMG | 拖入“应用程序”；首次打开时可能需要在“隐私与安全性”中允许。 |
| Windows 10/11 x64 | 安装包或免安装 ZIP | 选择安装或直接解压运行。 |
| Linux x64 | tar.gz | 解压后运行 `./thusfar`，需要 GTK 3。 |
| iOS / iPadOS 15+ | 未签名 IPA | 使用 AltStore 或 SideStore 签名并侧载。 |

Android 2.0 与 1.7.x 可以并存，两者的书库各自独立。想带走旧书库，可先在 1.7.x 导出备份，再在 2.0 恢复。[1.7.5 仍可下载](https://github.com/athemeroy/thusfar/releases/tag/v1.7.5)。

## 数据放在哪里

页读不需要账号，也没有必须连接的页读服务端。书籍、摘记和模型密钥保存在客户端本地。你主动整理书籍时，相关原文会发送给你配置的模型服务商，也可能调用 classifier.dev 进行核对。请按自己的隐私需求选择模型接口。

## 从源码运行

客户端由 `app/` 中的 Flutter 界面和 `core/` 中的 Dart 阅读引擎组成。2.0 正式版使用 Flutter 3.47.5 / Dart 3.13.4；构建 Android 还需要 JDK 17 和 Android SDK。

```sh
cd app
flutter pub get
flutter run
```

Android 2.0 安装包使用 `probe` 构建配置：

```sh
flutter build apk --release --flavor probe --target-platform android-arm64
```

开发和检查方式见 [客户端说明](app/README.md)。欢迎阅读 [贡献指南](CONTRIBUTING.md)。感谢 Luna 和 Gemini Flash 对 2.0 客户端的贡献。

## 许可证

[MIT](LICENSE)。随附字体遵循各自的许可证。
