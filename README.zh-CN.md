<p align="center">
  <img src="app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="88" alt="页读图标">
</p>

<h1 align="center">页读 · Thusfar</h1>

<p align="center">
  <b>一个只读到你这一页的书籍阅读 App。</b><br>
  点一下人名，只看这人到当前页为止的经历。
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases"><b>下载客户端</b></a>
</p>

## 读书，不被剧透

书太长、人太多时，隔了几百页再遇到一个名字，网上一搜很容易看到结局。页读会先整理书中的信息，把每件事钉在它第一次成立的位置。往前翻时，人物卡、人物表和关系图也会回到当时的状态。

- 点人名，看截至当前页的身份、别名和关系。
- 看关系图，查找内容，记录摘记和书签，阅读前情提要。
- 问已读内容，并跳到答案引用的原文。
- 导入 TXT 或 EPUB，离线阅读。
- 使用自己配置的模型接口，在设备上整理人物资料。整理需要联网，平常阅读不需要。

2.0 客户端使用 Flutter 界面和 Dart 阅读引擎。书籍、摘记及模型密钥保存在 App 本地。整理书籍时，原文段落会发给你选择的模型服务商，也可能使用 classifier.dev 做核对。页读不要求注册账号。

## 下载与安装

[Releases](https://github.com/athemeroy/thusfar/releases) 提供安卓、macOS、Windows、Linux 和 iOS 的 2.0 预览版。安卓预览版与 1.7.x 并存，书库各自独立。要迁移书籍，可在 1.7.x 导出备份，再在 2.0 恢复。

| 平台 | 文件 | 安装方法 |
| --- | --- | --- |
| 安卓 8 及以上 | 预览版 APK | 安装后显示为“页读 2.0 试用”。 |
| macOS 12 及以上 | DMG | 拖入“应用程序”。未做苹果公证；第一次打开时到“系统设置 → 隐私与安全性”选择“仍要打开”。 |
| Windows 10/11 x64 | 安装包或免安装 ZIP | 安装包只装给当前用户。未签名的程序可能触发 SmartScreen 提示。 |
| Linux x64 | tar.gz | 解压后运行 ./thusfar；需要 GTK 3。 |
| iOS / iPadOS 15 及以上 | 未签名 IPA | 使用 AltStore 或 SideStore 签名并侧载。 |

电脑上也可以从访达或资源管理器用页读打开 TXT、EPUB；原文件留在原处。方向键、空格、Page Up/Down 和鼠标滚轮可以翻页。

原安卓版仍可在 [1.7.5 发布页](https://github.com/athemeroy/thusfar/releases/tag/v1.7.5) 下载。2.0 目前作为预览版发布，设备和原地升级的验证还在继续。

## 从源码构建

本次发布使用 Flutter 3.47.5 / Dart 3.13.4。构建安卓还需要 JDK 17 和 Android SDK。在仓库根目录运行：

    cd app
    flutter pub get
    flutter run

用 Flutter 选择目标设备。安卓预览版使用 probe flavor：

    flutter build apk --release --flavor probe --target-platform android-arm64

客户端代码在 app/（Flutter 界面）和 core/（Dart 阅读引擎）。开发与检查方式见 [app/README.md](app/README.md)。

## 参与开发

见 [CONTRIBUTING.md](CONTRIBUTING.md)。防剧透是最重要的正确性要求：任何信息都不能早于它首次成立的位置出现。Luna 和 Gemini Flash 也为 2.0 客户端开发作出了贡献。

## 许可证

[MIT](LICENSE)。随附字体分别遵循其许可证文件。
