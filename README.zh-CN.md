<p align="center">
  <img src="assets/brand/icon-1024.png" width="112" alt="页读：翻开的书与标记阅读位置的书签">
</p>

<h1 align="center">页读 · Thusfar</h1>

<p align="center">帮你记住读过的故事，人物与情节只看到当前这一页。</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases/latest">下载客户端</a> ·
  <a href="https://athemeroy.github.io/thusfar/">在浏览器阅读</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="app/test/shots/01-shelf.png" width="260" alt="书架与阅读进度">
  <img src="app/test/shots/02-reader.png" width="260" alt="可点开人名的阅读页">
</p>

导入 TXT / EPUB，调排版、搜索、加书签、做摘记。需要时，用 AI 整理人物、关系和前情提要，或带着原文引用问书。查阅范围跟随阅读位置；退回前面的章节，人物与情节也跟着退回去。

## 开始阅读

1. 打开网页版，或安装下方对应的客户端，无需页读账号。网页版每本书的导入上限为 16 MB。
2. 导入书籍就能读。使用 AI 整理或问书时，填入自己的模型 API 密钥，再从书籍菜单开始整理。普通阅读不需要模型，整理好的书可以离线读。
3. 导出整库 ZIP 或单书备份，在另一端导入即可迁移。WebDAV 提供手动快照，不会自动后台同步。导出前请暂停整理，并等待当前请求结束。

| 平台 | 安装方式 |
| --- | --- |
| Android 8+ | 安装 APK，应用名称为“页读”。 |
| macOS 12+ | 打开 DMG，拖入“应用程序”；首次启动可能需要在“隐私与安全性”中允许。 |
| Windows 10/11 x64 | 使用安装包，或解压免安装 ZIP。 |
| Linux x64 | 解压 tar.gz 后运行 `./thusfar`，需要 GTK 3。 |
| iOS / iPadOS 15+ | IPA 未签名，需用 AltStore 或 SideStore 签名并侧载。 |

Android 2.0 与 1.7.x 的书库独立；从旧版导出备份，再在新版恢复即可迁移。

## AI、隐私与备份

- **模型自备，调用可能收费。** 支持 OpenAI 兼容、Gemini 和 Claude 兼容接口；网页托管不包含模型额度。[Gemini 免费档](https://ai.google.dev/gemini-api/docs/pricing)有使用限制，提交的内容可能用于改进 Google 产品。网页版的模型服务商须允许跨域请求（CORS）。
- **使用 AI 会发送原文。** 相关片段会发给你选择的模型服务商。安装版还可能调用 classifier.dev 核对；逐书启用 Jev 后，也会发送给 TypeSafe AI。Jev 密钥不能代替网页版整理所需的模型密钥。
- **防剧透仍有边界。** 默认隐藏未读内容，但 AI 可能出错。网页版资料是带引文的草稿，安装版人物小传另有核对流程；请结合原文判断。
- **书库保存在本地。** 导入不会把书上传到 GitHub。网页密钥仅存于标签页内存，刷新后需重填；安装版密钥保存在应用私有目录。清除应用或网站数据可能删去书库。同一 `athemeroy.github.io` 来源下的项目共享浏览器存储权限。
- **备份请妥善保管。** 整库 ZIP 包含书籍与可迁移设置，不含单独填写的 API 密钥；自定义模型地址仍可能含敏感信息。网页版 WebDAV 也需要服务端允许跨域请求。

[构建与测试](app/README.md) · [自行托管网页版](docs/SELF-HOSTING.md) · [参与贡献](CONTRIBUTING.md)

[MIT](LICENSE)，随附字体遵循各自许可证。
