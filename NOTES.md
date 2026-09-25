# 页读 / Thusfar 2.0 踩坑记录

更新：2026-09-26。每条按症状 → 原因 → 修法记录；未解决的问题明确留在 `STATUS.md`。

## A real marginalia rejection must remain a rejection

- Symptom: the reviewed manual Aq request made two model calls and two free JEV
  calls, then returned HTTP 400: `这条批注没有通过已读内容核对，已替你隐藏`.
  Both paid attempts completed with token usage; there is no pending request.
- Cause: the production guard rejected the original comment and its rewrite.
  The recorder then wrongly attempted its cache probe despite the failed first
  request. Its two-model cap blocked a third model request before transport;
  the second HTTP response was a recorder-induced 500, not a cache hit.
- Fix: retain the original intent, four wire attempts, both observed HTTP rows,
  and shared ledger. Do not resubmit under a new task ID. Probe cache reuse only
  after a successful first HTTP response. Verify the genuine first 400 offline
  and label the retained second response as a recorder-cap consequence. This
  case supplies a real rejection fixture, not a real marginalia success claim.

## HTTP worker replay needs the same cache policy as the full book

- Symptom: the first real thread-worker HTTP replay consumed all 103 recorded
  attempts and reached done 9/9, but missed 72 JEV cache artifacts.
- Cause: the recorder disabled `JUDGE_CACHE`, as needed for new live HTTP prompt
  captures. The fresh full-book fixture instead writes those cache files.
- Fix: use a fresh book with `JUDGE_CACHE=1` for the offline worker lifecycle.
  All 154 artifact hashes then match. Keep the complete file-set assertion so
  successful HTTP responses and matching reading results cannot hide missing
  caches. No production behavior or golden artifact expectation was changed.
- Teardown review: on an HTTP failure, the worker must stop and fully join while
  cassette and network guards are still installed. A timed join after restoring
  the transport could leave a background worker outside the recorder. The
  lifecycle context now joins inside the guards, with the outer isolated-process
  timeout handling a stuck replay; an exception-path regression checks exit order.

## Default concurrency evidence must state its book scope

- Symptom: the previous default-worker comparison for Aq existed only as a
  one-off observation; it could not be rerun from a committed receipt.
- Cause: ordinary function and multi-book recordings intentionally use one
  worker, because Jekyll's lookahead changes prompt inputs at 12 workers.
- Fix: a separate offline recorder compares Aq at 1 and 12 workers under two
  independent hash seeds. All 154 artifacts match the existing full-book golden,
  including paid/free usage and the complete file set. The committed receipt
  and CI rerun explicitly limit this result to Aq; the other books remain open.
- Review correction: bind the audited tape tree and controlling recorder sources,
  and check the tree before/after every process. Artifact equality alone did not
  establish that all processes used the same reviewed tape contents.

## Paused continuation preserves results but changes free-JEV telemetry

- Symptom: resuming the API-created Aq fixture from 4/9 to 9/9 matches 152 of
  the 154 fresh-run artifacts; `status.json` and `work/usage.json` differ.
- Cause: the resumed run reuses free-JEV caches. The full fresh run makes
  82 JEV attempts; the prefix makes 36 and continuation makes 46. Paid-model
  requests partition exactly as 21 = 8 + 13, with no cached model request
  repeated. The raw notebook and source files remain byte-identical.
- Resolution: retain the exact JEV fields in a dedicated continuation receipt
  rather than excluding all usage data from comparison. Two independent hash
  seeds reproduce the receipt. The literal A5 fresh/continuation equality gate
  remains unproven for usage telemetry; this observation does not waive the
  gate or change Python behavior. Concurrency 1 is the evidenced scope. See
  `oracle/record/RESUME.md` and its tamper regressions.

## English prefix exposes two remaining unordered traversals

- Symptom: Jekyll's 19-segment offline function recordings differed between
  hash seeds. The name-index argument to `_resolve_hint` had unstable insertion
  order, and `is_generic`, `generic_word`, and `is_latin` call counts differed
  by 12 even though the book artifacts were unchanged.
- Cause: `link_segment` inserted a set of English short names directly into
  its index. Two `any()` checks in `_dedupe_candidates` also iterated name sets,
  so their early exits evaluated a different number of generic aliases.
- Resolution: sort only the short-name index traversal and those two name
  inputs. Five hash seeds now check the Latin index order and the exact
  generic-name call count, including a mixed proper/generic alias fixture.
  The function recorder retains the original dictionary order and call
  counters, so the final two-pass comparison must still detect any drift.

## Larger corpus displaced handwritten boundary samples

- Symptom: the first byte-stable Aq/French/Jekyll function recording retained
  7,482 samples, but a separate manual-only trace showed that 11 of its 127
  observed samples were missing from the capped output (`is_latin`, `zh`, and
  `related`). Two identical recordings alone did not prove boundary coverage.
- Cause: the sampler kept the lowest input digests, so adding English inputs
  could evict previously recorded manual cases when a function reached 200.
- Resolution: preserve manual-phase input digests first, then choose the
  remaining samples deterministically within the same total limit. A limit
  too small for the mandatory manual samples must fail explicitly. Final
  acceptance includes a separate manual-only subset comparison, in addition
  to the complete two-pass byte comparison.

## Python 版本会改变标准答案

- 症状：系统 Python 3.13 跑得通部分录制，但字符类别和大小写转换结果与 Android 1.7.5 不完全相同。
- 原因：Android Chaquopy 工程固定 Python 3.11，3.11 使用 Unicode 14 数据；系统 Python 3.13 的 Unicode 版本不同。
- 修法：安装 Python 3.11.13，所有标准答案生成器固定该解释器版本；CI 改为 3.11，语义用例记录扩展区汉字、emoji、大小写、数字和空白符。

## 追踪器会改变被测行为

- 症状：给原测试套函数录制器后，少数 notebook / marginalia 用例出现额外的版本或调用计数失败；不套录制器的同一 Python 3.11 测试通过。
- 原因：早期追踪器将同一输入的不同输出直接抛异常，误把读取时钟、环境变量或闭包状态的函数当作纯函数，扰乱原测试控制流。
- 修法：录制器只报告冲突，不抛出并干预被测代码；清单将这些函数分类为状态相关。之后的冻结树上 255 个单测和函数输出双遍逐字节一致；新增 oracle 测试后的最终双录仍待执行。

## 测试时钟和 inode 会污染纯函数录制

- 症状：两次各通过 253 个单测、1,633 个函数样本且报告相同，但 6 个 server 函数 golden 的字节不同。
- 原因：被测用例把 `created`、`updated` 或含 inode 的 `graph_revision` 作为输入；`marginalia._key` 还要按真实修订元组计算哈希。对这些值直接规范化会改变业务结果。
- 修法：通用追踪器仅在 unittest 阶段对这些明确标记的动态输入跳过并报告原因；用固定时间和修订元组另录 6 份 special goldens，保留 `_key` 的实际哈希。另 3 个闭包、回调、锁相关函数也由确定性 special fixtures 录制。最终 255 单测的双遍函数目录与报告逐字节一致，128 个选定纯函数均有普通或 special 样本。真正传播的异常以 `$error` 保存，不能与函数内部捕获后返回 `None` 混淆。

## JSONL 中的 Unicode 行分隔符

- 症状：语料里的 U+0085、U+2028、U+2029 进入 JSON 字符串后，Python `splitlines()` 将一条合法 JSONL 拆成多条。
- 原因：`json.dumps(..., ensure_ascii=False)` 保留这些字符，而 Python 的通用行分割范围大于 JSONL 物理换行。
- 修法：录制器的规范化编码转义三种字符，检查器按真实 `\n` 分割；255 单测的两次函数标准答案录制已验证目录逐字节一致。

## HTTP 录制包含环境时间和 inode

- 症状：相同 HTTP 请求的版本字段和导出时间在重复录制时不同。
- 原因：`server.storage.signature` 使用文件 inode，导出响应带当前时间；会话 cookie 带随机值。
- 修法：录制时在同一路径和 inode 恢复样本、注入固定时钟，仅将随机会话令牌规范化为占位符。请求和响应的其他业务字段保留原值；60 个接口用例两次录制逐字节一致。
- CI 跨机器回放会复制一份新 baseline，原始 JSONL 无法与旧 inode 的提交版逐字节相等。现有离线回归用同一 baseline 运行两个独立 Python 3.11 进程并要求全部字节相等；对提交版逐路由比较稳定字节，仅在明确的版本、摘要输入版本、批注缓存键处核验格式后替换占位符，再独立验证报告的响应摘要。合成模型路由同样要求两遍一致和提交版字段一致，不调用真实模型。

## 免费 JEV 重试抖动只影响运行耗时字段

- 症状：阿Q 的 103 次真实传输录音带可离线重放，但两遍整书快照只在 `status.json` 和 `work/usage.json` 不同。
- 原因：一次免费 JEV 超时后，`pipeline.llm` 在重试等待中加入随机抖动，把实际等待秒数累计在两处 `jev.retry_wait_seconds`；模型输出、KG 和其他 152 个文件相同。
- 修法：在 oracle 快照中只删除 `status.json:usage.jev.retry_wait_seconds` 与 `work/usage.json:jev.retry_wait_seconds` 这两个运行耗时指标。Python 的重试与原始运行文件保持原样；专门测试证明同名字段在其他位置仍保留。修正后 154 个整书文件两遍逐字节一致。

## 章内前瞻并发度会改变模型请求摘要

- 症状：阿Q 的同一真实录音带以并发度 1 和 12 重放，154 个规范化文件一致；Jekyll 的并发度 1 回放两次都稳定，但并发度 12 在第二段出现录音带缺少请求摘要，不能直接用该 tape 验收默认并发设置。
- 原因：`Runner.run2` 会在同一章内提前提交多个本地抽取任务；并发度 12 的后续任务读取了更早时刻的 `cast_hint` 和关系记忆，并发度 1 则在前一段链接后读取，实际提示词不同。这是请求输入随并发配置改变，并非相同配置下的线程完成顺序抖动。
- 修法：真实整书 golden 的 provenance 明记并发度 1，Jekyll 标为部分且不声称覆盖默认并发度。后续要么在预算允许时给默认并发度录制相应请求，要么经阶段评估后明确冻结新的调度语义；不能把现有 tape 静默用作并发度 12 的标准答案。

## 全部五书的模型录制超过原预算

- 症状：计划预计全语料真实模型/JEV 录音带花费 ¥1 以内，但五本书仅首轮抽取就有 237 段，按当前配置费率约 ¥2.197。
- 原因：日文长篇和中文长篇的分段数分别达 110、72；估算还未算分类、小传、回顾及重试。旧版公开作品缓存采用其他模型，且没有原始 SSE 请求/回复，无法作为指定模型录音带。
- 修法：录制器持久化累计金额预留账本和次数上限；在 ¥1 内优先短书与跨语种关键段，保留未覆盖清单，A0 门槛保持未通过。最终预算与完整录制范围需用户醒后按实际证据决策。

## 历史暂停快照的译本权利尚未核实

- 症状：`bovary_partial/book.json` 的前言含译者李健吾和人民文学出版社信息；之前的语料说明把该快照统称为公有领域作品数据。
- 原因：原作《包法利夫人》已进入公有领域，不自动意味着这个中文译本也可重新分发；本地 1.7.x 数据目录只能证明格式与处理状态，不能证明译本授权。
- 修法：先把原快照及其整书、折叠派生 golden 共 106 个文件封入私有本地归档，逐文件 SHA-256 比对后移出当前分支；清单和生成器同时删除该来源。使用公开领域阿Q与已录的指定模型/JEV cassette 离线跑前 4/9 段，再由真实 1.7.5 `DELETE /process`、`PUT/GET /notebook` 接口形成暂停带摘记快照；两个独立进程再生的 67 个文件逐字节一致。新快照明确标记为回放/API 生成，不冒充历史读者数据。已移除的译本仍存在于此分支早期 Git 历史，因此不能直接推送或发布整条历史；发表前须以不含这些提交的干净历史交付。原译本再分发权利仍未核实。

## 长书末段被保守预算预留挡住

- 症状：阿Q 完成指定模型录制，Jekyll 处理到 19/20 段后，第 20 段在发送前被 ¥1 预算预检拒绝；原始 `status.json` 是 `error`。账本的配置费率估值 ¥0.445158，双倍费率守护记账 ¥0.890316，剩余 ¥0.109684，仍不足以预留该请求的最坏情况金额。
- 原因：预检按 UTF-8 请求字节数、最大输出 token 和双倍费率为每次请求先留足上限；实际模型用量回报后才释放差额。剩余额度不能当作下一次大请求已获批准。网关实际账单没有收据，不能把配置费率估值称为实付。
- 修法：不绕过账本、不以新目录重试同一付费请求。把已录到的前 19 段以 `--limit 19` 明确生成部分书 golden，289 个文件双遍一致，并在 provenance 写入截点和公开语料哈希。原失败运行的 19 份 `work/segs` 与截点回放一致；原运行在异常时只发布到第 18 段的 `kg.json`，截点回放正常发布第 19 段，因此两者的 `kg.json`、`mentions/0010.json` 和 status 不应直接当成同一快照比较。剩余三部公开书仍未获得真实录音带，A0 继续未通过。

## 余额预检只让法文书跑完第一段

- 症状：阿Q与 Jekyll 后账本还剩约 ¥0.109684 守护额度。法文书首段在真实 `deepseek-flash+nothink` 与免费 JEV 下完成，第二段的模型请求预留被拒；日文书第一段模型请求也被拒，只录到免费 JEV 回复。两个原始工作目录分别保留 `error` 状态与原始收据，不把它们当作完整整书结果。
- 原因：守护预留按每次请求的 UTF-8 输入上界、最大输出 token 和双倍率先扣；剩余金额大于零不等于足够预留下一请求。日文书第一段提示词与 token 上限已超过当前可预留额。
- 修法：法文书以明确 `--limit 1` 对同一录音带独立回放两次，得到 1/25 的 19 个逐字节相同产物和 20 个折叠截点；日文书保持 0/110，没有伪造模型输出。录音带扫描与严格账本审计通过：累计 67 次真实模型尝试、271 次免费 JEV 尝试，配置费率估值 ¥0.452480160、双倍守护记账 ¥0.904960320、无待结算请求。网关实际账单仍未知。追加的录音带树摘要同步写入 live audit 和阿Q暂停夹具 provenance，阿Q 67 文件仍在双进程再生中逐字节一致。没有绕开共享账本或新开付费目录。
- 复核入口：原始付费工作目录和来源目录分别保留于 `/home/dev/.local/share/thusfar-oracle/french-working-20260926`、`french-source-20260926`、`kokoro-working-20260926`、`kokoro-source-20260926`；其中 `.oracle-record.json` 绑定来源哈希与共享录音带路径。若以后获得新预算，只能检查原收据和账本后按原目录续跑，不能另开目录盲目重发。

## 后台小传与摘要使下一段输入随完成时刻变化

- 症状：同一章末尾的小传和摘要在不同线程先后完成时，同位点 `kg.json.log` 次序不同；下一章的 `cast_hint`、`relation_memory` 乃至经典流程的 `process()` 会看到不同的 KG 快照。
- 原因：最终整理工人直接写入共享 KG，而主线程会继续提交下一章的本地抽取任务并读取当前人物简介和前情提要；原先的前瞻提交还会跨章节。
- 修法：A0.5 的 Python 标准答案修复给同位点最终整理记录稳定排序，在续跑时先等旧任务完成，并在章界等待新任务完成后才读取下一章上下文；两阶段前瞻提交只在当前章内进行。事件控制的回归测试覆盖小传/摘要反序完成、下章提交和续跑。等待章界任务可能增加整书墙钟时间，需在完整录制时观察。
- 复查又发现经典流程同一章内的竞态：`consolidate()` 刚提交小传工人，`recap()` 才读取该章的 `profile` 日志；工人若抢先写入，小结提示词就多出新的一句话身份。跨章屏障和发布排序都发生得太晚，不能修复已构造的提示词。现在在同一个 `Runner.lock` 下完成小传提交和小结输入快照；已有小传缓存仍先同步应用。两项事件控制回归分别验证异步小传不能抢入、已有缓存仍进入小结。正式双录仍须验证整书产物。

## Unicode 大小写的希腊终结 sigma 不能只看相邻字符

- 症状：初版 Dart `title()` 把 Python 3.11 的 `ΑΣ́Α` 误写成终结 `ς`；`İΣͅ` 又误写成普通 `σ`。单字符及常见词的 5,726 个语义样本未发现。
- 原因：Unicode Final_Sigma 要跳过大小写可忽略字符检查前后文；U+0345 同时属于有大小写字符和可忽略字符，不能用相邻字符的 `cased` 属性推断。
- 修法：从冻结的 Python 3.11 行为生成 Unicode 14 的 `Case_Ignorable` 范围，Dart 用原字符串双向扫描。新增 378 个组合用例及 Python/Dart 双边测试，复核审查时原先 707 个探针已无差异。

## Dart 64 位整数与浮点排序边界

- 症状：初版 `round(1e20)` 溢出为负数，`int(1e20)` 饱和为 64 位上限；`floorDiv(-2^63, -1)` 环绕；`num.compareTo` 把 `-0.0` 排在 `+0.0` 前面，且把 NaN 纳入全序。Python 3.11 的对应结果不同。
- 原因：Dart VM `int` 有宽度限制，而 Python `int` 无限精度；Dart 比较器还区分浮点符号零，混合 `int`/`double` 的 `<` 在 2^63 边界可失去精度。
- 修法：兼容层将 IEEE-754 浮点数拆成精确二进制分数计算取整和混合比较；大结果返回 `BigInt`，`PyJson` 写出完整十进制；负数整除和取模接受 `int`/`BigInt`/`bool` 并用 `BigInt` 算后收窄。74 个新增 Python/Dart 成对边界样本覆盖大整数连算、NaN、符号零、布尔键排序及异常映射。后续业务移植要证明原生 `int` 的输入范围。

## Python 集合散列顺序会改变提示词和防剧透文本

- 症状：相同的七个人物、相同提及次数，`link_segment` 的候选前六名随 `PYTHONHASHSEED` 变化；同位点人物也可改变章末去重候选顺序。等长别名会改变人物显示名或防剧透替换：`甲乙丙` 可能成为 `某人丙` 或 `甲某人`。
- 原因：几个路径将 `set` 转成列表后只按提及数、首次位置或长度排序，平局沿用散列迭代顺序；另有 `next(iter(strong_names(...)))` 直接选择集合的首项。
- 修法：提及数、首次位置、长度的排序均加入稳定的 ID/名称平局键；新人物回退名称沿用模型原始有序名称列表；防剧透替换和新别名遍历固定顺序。`test_hash_seed_determinism.py` 用五个独立 Python 3.11 进程和不同散列种子，比较真实 link、去重、KG commit 防剧透输出。
- 后续把阿Q真录音带回放加入函数双录时又发现 `link_segment` 用 `p['aliases'] | {p['name']}` 的集合迭代顺序建立 `by_name` 字典；两轮 `_resolve_hint` 的 82 个样本中 71 个仅字典插入顺序不同。改为按名称排序后建立索引，并扩充五种散列种子的探针检查 `by_name` 键顺序。函数双录仍须重跑验证；`KG.canon` 的过宽自对象输入与 `settle_rewrites` 的运行耗时输入另行处理，不能把当前两轮视为逐字节通过。
- 同轮中 `related` 调用数相差 1，并带出 `is_latin`、`_stem` 各 2 次的差异。`verify_names` 和 `_dedupe_candidates` 对名称集合执行短路 `any`，不同散列顺序使首个真值位置变化，尽管布尔结果相同。现按名称排序后遍历，五散列种子回归同时比较两个路径的 `related` 调用序列；正式函数双录仍需复核完整录音带下的逐字节结果。
- 同一轮审计还发现问书检索对命中词集合直接累加浮点权重。不同集合顺序使临界分数相差一个 ULP，默认前 14 段里最后一段可从偏移 52000 换成 56000，改变后续判断和回答提示词。权重现在按词项排序后求和，五种散列种子的回归也覆盖默认检索截点。

## 形参别名使三个函数的返回值录音漏掉原地效果

- 症状：`pipeline.parse.classify` 和 `pipeline.run.settle_rewrites` 在函数 goldens 里都只返回 `null`，实际却分别写章节 `kind`、人物简介和审核 verdict；`pipeline.parse.finish` 返回已改写的 `blocks`，但没有证明调用者持有的原列表也被改写。尤其 `settle_rewrites` 的动态样本未触发回退分支。
- 原因：AST 分类器只看赋值目标的根变量是否为形参，把循环局部变量 `c`、`pr`、`b`、`f` 当作独立局部状态；通用录制器只在调用时编码输入、返回时编码返回值，不能表达原地修改与别名关系。
- 修法：逐项审计原 128 个纯函数，将这三项列入有依据的形参别名原位修改覆盖表；清单因此为 125 个纯函数。它们不再纳入返回值专用函数录制；另录调用前输入、调用后输入及返回值的专用状态合同，覆盖 `settle_rewrites` 的实际回退。`KG.canon` 的输入只记录从 pid 可达的 `merged_into` 链，保留环的闭合边，避免无关人物 `mentions` 在样本上限内挤掉有效案例。专用状态 golden 和最终双录验收完成前，不将 A0 判为通过。

## 函数录制重生不能依赖仓库里的旧标准答案通过单测

- 症状：把三个原地修改函数移出纯函数清单后，首次含阿Q回放的试录跑了 287 项 Python 测试，只有 `test_verify_function_goldens.py` 报旧 golden 的选中集合与新清单不一致；真实函数测试和离线回放正常。
- 原因：验证器单测直接验证当时仓库里尚未替换的旧正式 golden，形成“先有新 golden 才能跑完录制、先跑完录制才能发布新 golden”的循环依赖。
- 修法：篡改/清单匹配单测改用自建且内部一致的临时 golden 与临时清单；CI 仍另行对提交的正式 goldens 执行完整选中集合、报告和树 SHA 校验，未放宽正式规则。随后两种 `PYTHONHASHSEED` 的独立正式录制均通过 287 项 Python 测试、阿Q 9/9 离线回放，120 个普通函数 4,652 条样本与 5 个专用覆盖，整树逐字节相同，SHA-256 为 `2ef15bffba67e7fd74fac8e97951bbc282d250ff2cfc0b4986f709c75b837d14`；70 次未编码调用保留在报告中，不能称作已覆盖。

## 2026-09-26: Final HTTP oracle integration checks

- Symptom: the standalone settings-recorder module passed, but full Python test discovery had already imported `server.app` before the settings application-error test ran. The recorder correctly rejected that shared interpreter because its data directory was not the isolated fixture directory.
- Cause: the new test invoked the real handler fixture in the shared unittest process; other server tests legitimately import the app during discovery.
- Fix: commit `1bab17e` runs that HTTP application-error fixture in a fresh child interpreter, keeps the production isolation guard, and checks the persisted HTTP 200/application-failure observation in the parent. All 10 module tests and the explicit pre-import regression passed. The complete suite and formal function captures still require a fresh run.
- A separate full-suite run observed one complete-book hash mismatch in the thread-worker HTTP receipt. A standalone capture and a repeated 48-test prefix matched all 154 reference artifacts. This intermittent failure remains under diagnosis; a successful retry does not establish its cause or close it. Diagnostic captures retain every normalized artifact under `/tmp/thusfar-worker-stress-20260926` so the first differing path can be inspected without relaxing the comparator.

## 2026-09-26: Freeze actual unittest dependencies

- Symptom: the ordinary function input fingerprint omitted Dart contract files and their Python generator even though a Python unittest reads them. Changing those dependencies could leave the advertised recording input tree unchanged.
- Cause: the initial whitelist excluded all Dart files and some support scripts, treating only the direct oracle inputs as dependencies.
- Fix: commit `66d631c` adds the exact imported generator, deferred-marker helper, and ported Dart test contracts. Mutation tests reject changes to each added dependency. Provenance metadata now validates the two distinct integer seeds, frozen commit identifier, positive test count, and declared workload shapes. Metadata alone is not proof that two processes ran: the final acceptance record must also retain the actual commands, exit codes and independently compared output hashes. Python child-process tests assert their own results; their internal calls are outside the parent's function tracer.
