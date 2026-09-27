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
  &nbsp;·&nbsp; <a href="https://athemeroy.github.io/thusfar/"><strong>在浏览器阅读</strong></a>
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
- **专注书页。** 阅读工具覆盖在书页上，不挤动文字；“覆盖”翻页跟随手势，松手后平稳完成或回弹。
- **自己选择模型。** 需要整理人物资料时，填入自己的模型接口。免费判断不可用时，可为当前书籍启用已配置的模型或 TypeSafe AI 的 Jev 接口继续整理；也可填写有余额的 classifier.dev 工作区密钥。三种密钥分别保存，Jev 需逐书明确启用；每本书有可查看、可追加的调用上限。整理过程需要联网，日常阅读可以离线进行。
- **整理进度看得见。** 短时断网会自动重试，已完成的内容会保留。在书籍详情里可以查看当前步骤、继续整理，或导出不含正文和模型密钥的整理诊断。
- **从一台设备接着读。** 每本书都能导出含正文、阅读位置、书签、摘记和整理资料的备份，在另一客户端导入；也可以把快照放到自己的 WebDAV 文件夹，再从另一端取回。

## 下载客户端

从 [最新发布页](https://github.com/athemeroy/thusfar/releases/latest) 下载适合设备的安装文件。

也可以直接打开 [页读网页版](https://athemeroy.github.io/thusfar/)，导入不超过 16 MB 的 TXT / EPUB，在浏览器里阅读、搜索、加书签、做摘记和调排版。书籍与进度保存在该网站的浏览器 IndexedDB 中；**同一网址更新页面不会清空书库**，导入文件也不会上传到 GitHub。书籍菜单可导出完整 JSON 备份，在网页版与安装版之间互导。再次导入同一本书时，阅读资料会在无冲突时合并；冲突会明确提示，不会静默覆盖。

网页版也能整理人物线索、关系和前情草稿，并在书页上问书：填入**你自己的**兼容接口地址、模型和密钥。整理可选择第一章、已读完的章节或全书；只有主动开始后，所选正文才会发给模型服务商。每段最多请求两次；**模型服务商可能收费，GitHub 托管网页不提供免费模型额度**。密钥仅留在当前标签页内存，刷新后需重新输入；进度按段保存在浏览器，刷新后可手动继续。草稿附原文引文，默认隐藏未读章节；安装版的人物小传另有独立核对流程。TypeSafe / Jev 密钥不能直接填入默认的 DeepSeek 接口，所选服务商还须允许浏览器跨域调用。

安装版在“设置 → WebDAV 同步”、网页版在书架的 WebDAV 入口，均可向你自己的 HTTPS WebDAV 文件夹手动上传新快照、查看并导入另一端的快照。网页版要求 WebDAV 服务允许此网页跨域使用；这是手动快照同步，不会在后台自动覆盖另一台设备。浏览器或设备主动清除网站数据仍可能删去本地书库，重要书籍请导出备份或保存 WebDAV 快照。同一 `athemeroy.github.io` 主机下的其他 GitHub Pages 项目与页读共享浏览器同源存储权限。

| 平台 | 下载文件 | 安装方式 |
| --- | --- | --- |
| 网页 | [打开页读](https://athemeroy.github.io/thusfar/) | 用现代浏览器打开，无需安装或账号。 |
| Android 8+ | APK | 安装后显示为“页读”。 |
| macOS 12+ | DMG | 拖入“应用程序”；首次打开时可能需要在“隐私与安全性”中允许。 |
| Windows 10/11 x64 | 安装包或免安装 ZIP | 选择安装或直接解压运行。 |
| Linux x64 | tar.gz | 解压后运行 `./thusfar`，需要 GTK 3。 |
| iOS / iPadOS 15+ | 未签名 IPA | 使用 AltStore 或 SideStore 签名并侧载。 |

Android 2.0 与 1.7.x 可以并存，两者的书库各自独立。想带走旧书库，可先在 1.7.x 导出备份，再在 2.0 恢复。[1.7.5 仍可下载](https://github.com/athemeroy/thusfar/releases/tag/v1.7.5)。

## 数据放在哪里

页读不需要账号，也没有必须连接的页读服务端。书籍和摘记保存在客户端本地。安装版的模型密钥保存在设备的应用私有目录；网页版的模型密钥只留在当前页面内存。你主动整理书籍时，相关原文会发送给你配置的模型服务商；安装版也可能调用 classifier.dev 进行核对，如果你为这本书启用了 Jev，相关片段还会发送给 TypeSafe AI。请按自己的隐私需求选择模型接口。

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

为此仓库的 GitHub Pages 路径构建静态网页版：

```sh
flutter build web --release --target lib/main_web.dart --base-href /thusfar/
```

开发和检查方式见 [客户端说明](app/README.md)。欢迎阅读 [贡献指南](CONTRIBUTING.md)。感谢 Luna 和 Gemini Flash 对 2.0 客户端的贡献。

## 许可证

[MIT](LICENSE)。随附字体遵循各自的许可证。
