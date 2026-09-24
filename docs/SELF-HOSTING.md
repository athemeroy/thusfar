# 自己跑一份

读到哪一页，点任何一个人就只看到他**截至这一页**的样子。这份文档讲怎么在自己的机器上把它跑起来。

## 不架服务器：安卓本地版

安卓版把同一份 Python 服务和流水线嵌入手机。在手机上安装签名 APK 后直接进入本地书架，不需要填写服务器地址、配置 Docker 或保持家里的电脑在线。导入 TXT / EPUB 即可离线阅读；MOBI/AZW3 因 GPL 解析器未打包，请先转换成 EPUB。书籍备份 `.yedu.json` 可从书籍菜单导出，在另一台设备从同一个导入框恢复。

人物整理和提问仍要联网。打开书架右上角的「模型设置」，填写自己的兼容 OpenAI 的 HTTPS 接口、模型名及 API 密钥；免费 JEV 默认直连 classifier.dev。密钥保存在 App 私有目录，设置页只回显末尾四位，书籍备份不包含密钥。上传后需要单独确认「开始整理人物」，才会调用模型。整理时有前台状态通知；暂停或进程被系统结束后，书架保留已完成段落，重新点开始即可从断点继续。安卓 15 起，系统对 `dataSync` 前台服务施加每日后台时限；达到时限会暂停，回到 App 后可继续。

开发构建需要 Android SDK、Gradle 和 Chaquopy（见 [android/README.md](../android/README.md)）；只有下文的纯 Python 服务可以在新环境中零 `pip` 依赖运行。

## 最短路径

```bash
git clone https://github.com/athemeroy/thusfar && cd thusfar
cp .env.example .env                     # 填一个 key 就行
python3 scripts/sample_books.py jekyll   # 拿一本公版书来试
python3 -m server.app                    # 打开 http://localhost:18770
```

**没有任何第三方依赖。** 正文、流水线、服务端全是 Python 标准库（3.11+），`pip install` 一行都不用跑。要训练自己的裁判模型时才需要额外的包，见下面第四节。

## 一、填什么 key

`.env` 里至少要有一个能读书的模型：

```bash
LLM_API_KEY=sk-你的key
LLM_BASE_URL=https://api.deepseek.com/v1
EXTRACT_MODEL=deepseek-flash+nothink
```

任何 OpenAI 兼容的接口都行；Anthropic、Gemini、Ollama 也原生支持（`LLM_PROTOCOL_MAP`）。

**`+nothink` 不是可选的**：DeepSeek V4 系列默认开思考，抽取任务上每段要多花 4 分钟、1.8 万 token，而结果并不更好。

### 花多少钱

按实测的 token 结构（每万字约 3.8 万输入 + 1.6 万输出）：

| 模型 | 每万字（官方价） | 一本 100 万字的小说 |
|---|---|---|
| DeepSeek（闲时） | ¥0.067 | 约 ¥7 |
| DeepSeek（标准） | ¥0.108 | 约 ¥11 |
| gemini-2.5-flash-lite | ¥0.047 | 约 ¥5 |

上传一本书**不会自动花钱**。解析入库是免费的，书架上那本书会显示预计耗时和费用，按下"开始整理人物"才开始花。别人的钱也是钱。

## 二、裁判是什么，为什么需要它

流水线里有一类判断不适合让大模型做——它们是选择题，而且要的是**校准过的概率**，不是一段话：

- 这个新名字是不是已经出现过的某个人？
- 这条刚抽出来的记录，本段原文到底支不支持？
- 这两个人是什么关系？（9 大类 × 88 小类的标签树）
- 这个章节标题会不会剧透？

我们的阈值（0.35 / 0.5 / 0.7 / 0.9）全都是按这些概率校准的。**三种办法，从免费到自建：**

### 1. 什么都不设（默认）

classifier.dev 免费、不要 key，每分钟 3000 次、每天 2 万次。直接能用。

一本 100 万字的书大约需要 3 万次判断，所以中小体量的书一天之内跑得完；大部头会撞上每日上限。

### 2. 自己托管判官

判官只是一个 HTTP 服务：收一段原文和一道选择题，回每个选项的概率。流水线用的是 classifier.dev 的协议，所以任何说同一种协议的服务都能直接接上，流水线一行不用改：

```bash
JEV_ROUTE=local
CLASSIFIER_URL=http://127.0.0.1:8008/v1/evaluate
```

`local` 路线只走你指定的服务，**永远不会回退到付费判官**。请求和返回的格式见 [`scripts/judge_server.py`](../scripts/judge_server.py) 开头的注释，它是一个用开源零样本分类器（GLiClass）实现同一协议的参考服务。

要说清楚的是：我们试过用开源小模型接替 JEV，零样本效果明显不如 JEV，微调后在开发集上接近，但还没有在整本书上验收过。这条路线适合想完全离线、或者想自己研究判官的人；想省心就用默认的免费线路。流水线的阈值是按概率校准的，换判官时请重新检查阈值，不要只看首选标签的一致率。

### 3. 付费接口

```bash
JEV_ROUTE=paid
JEV_URL=https://ai-gateway.vercel.sh/v1/evaluate
JEV_MODEL=typesafe-ai/jev
JEV_API_KEY=...
JEV_PAID_MAX_CALLS=100
JEV_PAID_MAX_CHARS=500000
JEV_BUDGET_FILE=/absolute/private/data/paid-budget.json
```

### 实在不想要裁判

用普通聊天模型冒充判官的旧开关（`JUDGE_FALLBACK`）已经关掉了：它给不出校准过的概率，也绕开了付费预算的记账。请明确选一条判官路线。`JUDGE_IMPORTANCE=0` 这类可选开关能减少调用次数；关掉逐条核对会降低质量，产出就不能再称为“已核对”。

## 三、书从哪来

TXT / EPUB / MOBI / AZW3 直接传。中英日的分章、注释、插图、ruby 注音都认。

仓库里不带书（那是别人的文字，而且是不是公版取决于你在哪）。要几本试试：

```bash
python3 scripts/sample_books.py            # 看有哪些
python3 scripts/sample_books.py jekyll     # 下一本到 data/samples/
```

五本覆盖了流水线要应付的各种情况：英文小说、英文短篇集、英文剧本、英文非虚构、日文小说。
来源都是自己声明授权的地方：[Project Gutenberg](https://www.gutenberg.org/)、[维基文库](https://zh.wikisource.org/)、[青空文庫](https://www.aozora.gr.jp/)。

**不要指向盗版站。** 有人传上去的连载网文不是公版。

## 四、要训练自己的裁判

参考服务依赖 PyTorch 和 GLiClass，放在单独的虚拟环境里：

```bash
python3 -m venv .venv-judge
.venv-judge/bin/pip install torch transformers gliclass accelerate
python3 scripts/export_judge_data.py data/books/<id>   # 把判官判过的题导出成训练数据
python3 scripts/judge_server.py --model <你的模型目录>
```

Apple Silicon 可以用 Metal，CUDA 和纯 CPU 也能跑。

## 五、测试纪律

如果要改流水线并且声称改好了，请遵守这三条——我们自己吃过亏：

1. **探针先写后跑**。先写好"这本书在第 N 页之前不该出现什么"，再去跑，不然就是在给结果找理由。
2. **逐个看过个例的书就降级成开发集**，不能再当测试集。事先把哪些书是测试集、哪些是开发集写下来，不要事后调换。
3. **永远报多数类基线**。有个任务 94% 的答案是同一个，模型拿 93.6% 看着很美，其实等于什么都没学。

## 六、目录

```
pipeline/    读书：分章、抽取、合并、裁判、关系树
server/      HTTP 服务（纯标准库）
web/         前端（无框架，无构建步骤）
android/     安卓 App（内嵌同一份 Python 服务，离线可用）
scripts/     跑书、导出训练数据、训练与评测裁判
docs/        设计文档
tests/       探针与回归
testsets/    防剧透评测的探针（只有探针，不含原文）
```
