<p align="center">
  <img src="web/icon-192.png" width="88" alt="页读图标">
</p>

<h1 align="center">页读 · Thusfar</h1>

<p align="center">
  <b>一个只读到你这一页的书籍阅读 App。</b><br>
  点一下人名，告诉你这人是谁——只说到你读到的这一页，后面的剧情一个字都不会漏。
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
</p>

<p align="center">
  <a href="https://github.com/athemeroy/thusfar/releases/latest"><b>⬇ 下载安卓 App</b></a> ·
  <a href="#在电脑上用docker">用 Docker 跑网页版</a> ·
  <a href="https://x.com/WangYeruo/status/2103108551799632050">看宣传视频</a>
</p>

<p align="center">
  <img src="docs/media/demo-zh.gif" width="560" alt="点人名只说到这一页；往回翻，它就忘掉你还没读到的">
</p>

---

## 为什么做它

我这几年读了不少网文，老碰到同一个问题：书太长，人太多。隔几章冒出个名字，死活想不起来是谁；想往回翻，翻不到；想搜一下，又怕一搜就被剧透。

问 AI 也不行：大模型早就读过原著，它的记忆本身就是剧透。

页读先把整本书读一遍，把每条信息都钉在它**第一次成立的位置**上。你读到第 180 页，它就只拿出第 180 页为止成立的东西。这是结构上的保证，不是靠提示词求模型别说。

## 它能做什么

- **这人是谁？** 点人名，看身份、别名、关系和做过的事——只到你这一页。
- **往回翻，它就忘。** 跳回前面，人物卡、人物表、关系图都跟着缩回去。
- **关系图**读到哪长到哪，每条连线都标着关系（监护人、养女、姐夫……）。
- **随便问**，回答会标出出自哪一页；问结局，它会让你接着读。
- **弹幕选句**：每一句都打分（情绪、线索、主题、笔法……），点开是几句只基于已读内容的短评。
- **前情提要**：隔几周再读，先看一眼；没读到的回目，连标题都藏起来——标题也会剧透。
- **不止小说**：教材、经济、哲学书也能用，点术语看它**读到这一页时**的意思。
- **摘记归你**：划线、书签、想法钉在原文上，断网也能记，可导出 Markdown。
- **离线阅读**，8 种界面语言，支持中文、英文、日文书籍。

<p align="center">
  <img src="docs/media/01-shelf.jpg" width="250" alt="书架">
  <img src="docs/media/02-reader.jpg" width="250" alt="阅读页，人名带下划线">
  <img src="docs/media/04-card.jpg" width="250" alt="人物卡，盖着“截至第 478 页”的章">
</p>
<p align="center"><sub>网页版实拍（英文界面，《远大前程》）。人物卡右上角的章标明它截至哪一页。</sub></p>

## 怎么用

### 安卓

1. 在 [**Releases**](https://github.com/athemeroy/thusfar/releases/latest) 下载 APK 安装（安卓 8.0 及以上）。
2. 导入 TXT 或 EPUB，马上就能读，完全离线。
3. 要生成人物资料：在书架打开 **模型设置**，填一个兼容 OpenAI 的接口（默认推荐 DeepSeek）和你的 key，先点 **测试连接** 确认 key 和模型可用，再在书上点 **开始整理人物**。不点这个按钮，不会发出任何东西，也不会花一分钱。整理停下时，书籍菜单会写明原因（没填 key、模型名不对、余额不足等）。

整个 App——Python 服务、读书流水线、网页界面——都跑在手机里。没有账号，也没有我们的服务器。

### 在电脑上（Docker）

```bash
git clone https://github.com/athemeroy/thusfar && cd thusfar
cp .env.example .env          # 填一个模型 key，比如 LLM_API_KEY=sk-...
docker compose up -d          # 打开 http://localhost:18770
```

### 或者直接用 Python

只用标准库，零依赖（Python 3.11+）：

```bash
cp .env.example .env
python3 scripts/sample_books.py jekyll   # 可选：下载一本公版书试试
python3 -m server.app                    # http://localhost:18770
```

如果要让别的设备访问，先在 `.env` 里设 `PASSCODE=`。模型、费用、判官和全部配置见 [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md)。

## 原理

**大模型负责读和写，判官负责判。**

1. **阶段一，并行**：每段单独读，只看这一段，抽出人物、事件、档案和关系。
2. **阶段二，顺序**：第 *k* 段只用第 1 到 *k* 段合并。每条记录都带着它第一次成立的位置。
3. **阅读时**：翻页只折叠位置不超过当前页的记录。

凡是能写成选择题的判断，都交给 [JEV](https://classifier.dev)——一个只做选择题、只给概率的判官：*这段里的“老太太”是不是贾母？* *原文支不支持这句话？* *这两人是 88 种关系里的哪一种？* *这句值不值得停一下？* 人物合并、逐条核对原文、关系分类、防剧透守卫、弹幕选句，都不花大模型的 token。

**探针在跑之前就写好**（第 *N* 页之前不该看到什么），测试书不参与调参：

| 书 | 规模 | 探针 | 人工核对后的真泄露 | 读到该处后能看到 |
|---|---|---|---|---|
| 《远大前程》 | 99 万字符 | 14 | 0 | 14 / 14 |
| 《儒林外史》 | 32.5 万字 | 8 | 0 | 6 / 8 |

《远大前程》用 GPT-5.6 Terra 整理，19 分钟，约 ¥2–3。其他模型的估算见 [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md#花多少钱)。

## 隐私

- 书、图谱、你的摘记和 API key 都留在你的设备（或你自己的服务器）上。
- 整理一本书时，原文段落会发给**你自己配置的模型服务商**，默认还会发给 **classifier.dev**（免费、不要 key 的 JEV 服务）做选择题判断。阅读、摘记和搜索不联网。
- 也可以换成自己的判官：设 `JEV_ROUTE=local`，把 `CLASSIFIER_URL` 指向任何说同一协议的服务（[参考实现](scripts/judge_server.py)）。

## 支持的格式

TXT、EPUB 全平台可用。MOBI/AZW3 在 Python/Docker 版里 `pip install mobi` 之后可用（这个解析库是 GPL-3.0，所以没有打包；安卓版请先转成 EPUB）。

## 目录

```
pipeline/   读书：分章、抽取、合并、判官、关系
server/     HTTP 服务和接口（纯标准库）
web/        界面（无框架、无构建步骤）
android/    安卓 App，用 Chaquopy 内嵌同一份服务，见 android/README.md
scripts/    跑书、参考判官服务、发布检查
tests/      单元、Node、浏览器测试和防剧透探针
testsets/   防剧透探针定义（只有探针，不含原文）
docs/       自托管与设计文档
```

## 开发

```bash
python3 -m unittest discover -s tests -p 'test*.py'
for f in tests/*.test.mjs; do node "$f"; done
python3 tests/frontend_browser.py      # 需要 pip install playwright && playwright install chromium
```

欢迎贡献，见 [CONTRIBUTING.md](CONTRIBUTING.md)。改了流水线、想说它变好了，请先写探针再跑。

## 现状与限制

- App 目前只有安卓；网页版能在任何有 Python 或 Docker 的机器上跑。暂时没有 iOS。
- 整理一本书需要联网和模型 key；读书不需要。
- 免费判官有每日额度，几百万字的网文可能要分几天整理完。
- 非中文界面文字由机器翻译、主要页面人工校过，欢迎指正。

## 许可证

[MIT](LICENSE)。随附字体采用 SIL Open Font License（许可文件在 `web/fonts/` 里）。

感谢 typesafe.ai 的 [JEV](https://classifier.dev) 和 [Chaquopy](https://chaquo.com/chaquopy/)。宣传片由 Claude Code（Opus 5.5）用 Remotion 纯代码制作，旁白是 Gemini 3.8 Flash TTS。
