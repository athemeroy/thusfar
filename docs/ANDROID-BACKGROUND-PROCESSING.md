# Android 后台整理：运行链与验收

## Find N5：恢复后先超时、后取得保存结果

23:54 导出的复现记录中，系统省电豁免已开启，用户也确认允许后台活动。
23:41:44 切后台后，原生和 worker 心跳再次长时间中断。23:51:00 恢复执行时，
两次正文请求先被外层总时限标为 unknown/timeout，书籍随即暂停；约 0.3 秒后，
仍未被取消的取结果任务却成功读取了服务器已保留的两个完整回复。
省电设置没有解决目标设备的执行停顿，不能把本次问题归因为未授权。

已明确修复：接受异步任务后，不再用实时流式请求的墙钟超时包住整段轮询。
轮询仍有独立、有限的等待预算，只计计划等待和每次最多 15 秒的读取；
一次读取的头和正文共享时限，长时间停止调度不会耗尽所有后续读取机会。
完整保存结果返回后重新开始解析时限，不将手机暂停时间用于学习模型速度。
普通流式请求仍保留总时限；未知的首次 POST 不重发，手动暂停仍终止读取。

新增回归：已接收任务的结果在原流式总时限之后返回，仍能提交且只发一次 POST。
保存结果、System One 读取、普通流式超时及取消相关 11 项检查通过。
这解决恢复时误暂停，尚不能证明 Find N5 在后台持续执行；后者需目标手机的系统记录。

## Find N5：手机后台设置入口

2026-10-05 的复现中，原生线程和 Dart worker 都在约 23:01–23:19
停止留下心跳，回到前台后恢复。elapsed 与 uptime 同增约 18 分钟，
不能把这段时间归因于设备深睡眠，也尚未定位到某个厂商组件。
当时省电豁免为 false；前台服务存在不能证明任务仍在执行。

设置页和整理进度页现有“切到后台继续整理”入口。用户主动点击后，
可以请求系统电池优化豁免、打开本应用的耗电管理和通知设置。
从系统设置返回会读取实际授权状态；取消授权不会显示成功。
厂商独立的后台开关无法完整读取，因此即使系统豁免已开，也保留手动检查说明。
入口不会暂停、重新提交或接管已有整理任务。

用户选择继续由手机整理，并自行操作 Find N5。安装后先允许后台运行，
在耗电管理中允许后台活动，再继续原书、切换应用或锁屏 20 分钟。
对比已完成段数及心跳是否持续；本次没有把目标设备验证标记为通过。
必要自动检查仅覆盖拒绝授权、返回后读取实际授权及设置跳转；APK 在 MINI 构建。

同次复现的最后一次模型失败是个人服务器的另一问题：Decider 常驻后，
Qwen 空闲卸载再启动时被旧显存门槛拒绝。服务器配置已调整，实际冷启动
请求成功。此项无需更换 APK，也不能解决手机停止安排下一步的问题。

## 这次修复针对什么

已知用户现象是前台及服务器长回复正常，切后台后服务器记录客户端断开。该记录是连接结束的结果，单凭它不能区分 Activity/engine 销毁、请求取消或超时、设备睡眠、Doze、网络变化、厂商限制。

在原实现中可以直接确认的风险：

- FlutterEngine 跟随 Activity 销毁，Dart 的 detached 回调还会关闭整理 worker
- 进度服务由 HomeShell 事后启动；通知权限弹窗会延迟启动，返回成功也不代表 startForeground 已完成
- 进度服务没有 CPU 唤醒锁
- 生命周期、真实服务状态及省电/后台网络状态没有连贯诊断证据
- 断流后的多层重试与进程重启可能重发服务器已处理、但客户端尚未保存结果的请求

这些是已确认的代码路径风险；未经目标设备日志对照，不能宣称其中某一项就是本次断开的唯一根因。

## 运行所有权

1. 第一次打开 Activity 时才创建进程内唯一的 `ProcessingEngineHost`。应用路径和整理通道在执行 Dart 入口前安装。Activity 销毁仅分离界面，再次打开复用原 engine，不创建第二个 worker。服务不自行冷启动 engine。
2. 每个实际书籍运行在发出模型请求前，先等待原生服务完成 `startForeground` 和 CPU lease 获取。通知权限只控制通知抽屉可见性，不阻塞这一步。
3. `ProcessingController` 持有后台会话、进度与限时处理。HomeShell 及 Activity 都不拥有请求生命周期。Dart worker 的新鲜心跳证明 worker 活跃；单纯 UI 计时器不作为存活证据。
4. 活跃任务使用带 10 分钟硬超时的部分 CPU 唤醒锁，稳定标记为 `Thusfar:BookProcessing`。正常心跳每 30 秒续期；相同进度不会每秒更新通知。仅排队时释放 CPU，交接下一本书时保留同一个前台服务。worker 心跳过期先释放原生资源，再请求暂停。
5. 显式暂停、worker 退出、所有任务结束、服务销毁和 Android 限时都释放资源。Android 限时先终止服务，再通知 Dart 收尾。已取消 START、延迟 STOP、旧更新不得影响新一代同书任务。
6. 已完成段落和缓存继续使用现有持久化规则。请求发出前写入不含正文/密钥的日志；请求结果不确定时暂停并保留进度。显式继续会显示可能重复产生费用的提示，不以自动恢复静默重发。

## 自动化检查

```sh
# Java 21、Maven 3.9+；无需 Android SDK、APK、签名或模型密钥
mvn -B -f app/android/runtime-tests/pom.xml test

cd app
flutter pub get
flutter analyze --fatal-infos --fatal-warnings
flutter test test/processing_background_session_test.dart \
  test/processing_test.dart test/processing_diagnostics_test.dart

cd ../core
dart analyze --fatal-infos --fatal-warnings
dart test test/jobs/jobs_test.dart test/pipeline/llm_timeout_test.dart \
  test/pipeline/request_interruption_test.dart
```

JVM 测试编译真实 Kotlin 和 Flutter Java embedding。Android 框架使用 Robolectric；engine 测试替代 FlutterJNI/FlutterLoader，不运行 Dart/C++。它不能证明真实休眠或厂商后台策略。详细边界见 [JVM 测试说明](../app/android/runtime-tests/README.md)。Dart 的准入测试使用真实 worker isolate 和本机无计费 HTTP fixture。

## 本地 Codex / 设备验收

先记录精确 Git SHA、包名、版本、target SDK、设备型号、系统版本、安装包 SHA-256 及签名证书 SHA-256。基线为 `7ff0f99f05fcb26b76c3e95ab07ec2c7c65416ca`（2.0.13+55）。修复后的测试必须固定审核过的候选 SHA。

使用合成书与无计费、可控长响应 fixture。不要使用真实书、真实模型密钥或付费模型。不要为测试全局禁用安全校验、开启无限制后台白名单或改变用户省电设置。观察真实设置即可。需要改变设备测试状态的步骤应由测试者单独确认，并记录和恢复。

| 场景 | 必须证明 |
| --- | --- |
| 前台长响应 | 一个 worker；先有 foreground_started / cpu_lease_acquired，后有首个请求 |
| 切其他应用 | 服务与同一 engine/worker 继续；服务器没有由生命周期主动取消导致的断连 |
| 锁屏 | 普通屏幕关闭时任务继续或明确记录系统限制；记录 elapsed/uptime 差值，不能用计时器“仍运行”代替进度证据 |
| Activity 销毁后重建 | 不新增 engine/worker/request；原任务仍可观察；导入/通知点击通道能重新绑定 |
| 连续排队两本 | 交接没有服务归零或新后台启动被拒绝；CPU 只覆盖活跃执行 |
| 显式暂停 | 停止发新请求，终止当前传输，前台服务与 CPU lease 释放，done/frontier/cache 不回退 |
| 取消后立即继续 | 旧 START/STOP/回调不关闭新任务；无并行同书运行 |
| 断网/响应半途断开 | 结果未知时不自动重发；保留已完成段落并显示人工确认入口 |
| 请求中进程死亡，再打开 | 不自动重放未确认请求；无请求未确认时遵循原授权与进度恢复 |
| Android dataSync 超时 | 服务及时停止，迟到的心跳不能复活，进度保留；未确认模型结果仍要求人工确认 |
| 通知权限拒绝 | 前台服务准入独立于通知抽屉权限；真实服务状态仍可检查 |

推荐只读证据命令（将包名替换为实际安装的 full 或 probe 包）：

```sh
adb shell dumpsys package com.yedu.zhupi
adb shell dumpsys activity services com.yedu.zhupi
adb shell dumpsys power
adb shell dumpsys deviceidle
adb logcat -v threadtime ThusfarProcessing:I ActivityManager:I flutter:I '*:S'
```

每次测试同时记录 fixture 的请求开始、首/末字节、正常完成与断开时间，并在任务页导出整理诊断。应用诊断只保留白名单状态、次数、时间戳和错误类型，不包含书名、正文、URL、密钥或完整异常消息。系统 logcat/dumpsys 可能含其他应用信息，分享前由测试者检查和裁剪。

云端自动化检查不生成或发布 APK。原签名真机测试结果见下方记录。后续正式覆盖安装仍须使用已有签名证书；没有原签名材料时只做编译和测试，不创建新密钥、不使用 debug 签名冒充正式包。

## 系统边界

普通前台服务和部分 CPU 唤醒锁不保证绕过 Doze、断网、强行停止或厂商杀进程策略。Doze 可以暂停网络和忽略普通唤醒锁；此时正确结果是保留进度、准确说明中断，并安全恢复。[Android Doze 文档](https://developer.android.com/training/monitoring-device-state/doze-standby)

Android 15+ 对 `dataSync` 后台执行有共享时长限制，超时后服务必须及时停止，不能用重新启动服务规避。[前台服务超时文档](https://developer.android.com/develop/background-work/services/fgs/timeout)

Activity 与 engine 所有权的处理遵循 Flutter 的提供 engine / 宿主销毁约定。[FlutterActivity API](https://api.flutter.dev/javadoc/io/flutter/embedding/android/FlutterActivity.html)


## 首轮真机结果与判断错误复测

`7924e3b` 的原签名 APK 已在 Redmi Note 8 Pro / Android 11 / MIUI 12.5.3 完成首轮测试（[报告与 APK](https://github.com/athemeroy/thusfar/releases/tag/v2.0.13-background-7924e3b)）。切应用和锁屏期间 engine/PID、前台服务与 CPU 锁保持；但免费本地 Qwen 的判断回答验证失败，`done=0/24`、`frontier=0`。这不能证明持续后台进度已通过。

后续窄修复保留原始验证错误，不再被收尾和 worker 的 `request_outcome_unknown` 提示覆盖。收到完整响应但结果未提交时，仍保留请求日志、禁止自动重放并要求显式继续；没有放宽概率范围、字段完整性、合计或所选选项检查，也没有增加修复请求数。

判断失败现在记录最近一次耗尽双次判断尝试的安全诊断：`work/judge/model-answer-failure.json`，并进入任务页导出诊断的 `last_model_judge_failure`。只有时间、该次问题数、未完成数、尝试数和固定原因计数；不含正文、问题/选项 ID、回答、概率原值、模型 URL 或密钥。短批次拆分后的单问题失败会记录该单问题的双次尝试，次数不是整本书的累计请求数。该字段表示最近失败，复测时请按时间确认归属。

复测固定新的候选 SHA，不追加广泛审查：

1. 仍使用合成书和已获授权的免费模型。如果 Qwen 再失败，导出安全诊断，报告 `last_model_judge_failure` 的原因及计数；不提交原始书籍、提示词、回复或凭据。当前证据不足以声称 Qwen 兼容性已修复。
2. 为分离模型格式问题与 Android 生命周期问题，可以使用无计费、确定性、返回完整且严格合法判断分布的本地 HTTP fixture。必须报告这是模拟模型，不把它作为 Qwen 通过证明。
3. 需要看到 `done` 和 `frontier` 非零增长，然后执行切应用、至少两分钟活跃锁屏、暂停与恢复；确认进度不回退、已有抽取缓存不重发、暂停后服务与 CPU 锁释放。保留 SHA、时间、计数和裁剪后的生命周期证据。
4. PR 保持未合并；本补丁不发布正式版本，不代替真机验收。


## Delayed-background-error diagnostic candidate

This instrumentation does not claim to fix an unconfirmed device suspension or
network cause. It preserves model choice, request/retry/cancellation behavior,
FGS admission, finite CPU lease, cache/frontier, and explicit unknown-outcome
resume policy.

The existing JSON export now retains allowlisted `status.failure_code` and the
unsettled request journal. Previously the generic uncertainty message could
export as `error_code: unknown` even when the worker had recorded a precise code.
New `model_requests` diagnostics retain the last 32 attempts, up to 16 events per
attempt: dispatch, application-observed request submission, response headers,
application-observed raw bytes, safe
exception category, cancel/abort/body-close observations, and settlement. Byte
checkpoints are throttled to five seconds and flushed at terminal events. IDs
are explicitly local to the app; they are not provider/server correlation IDs.
No diagnostic metadata is added to HTTP headers.

For an active worker only, `worker_heartbeats` is written directly by its isolate
every 15 seconds and at run start/end, without waiting for UI frames. Android
records an independent native-thread heartbeat, actual process importance, and
separate worker-sample, UI-receipt, and native-delivery timestamps in a separate bounded ring.
Native samples neither renew the wake lock nor restart work; sampling stops
with the service. Lifecycle events retain their own ring, including Activity
configuration changes, so heartbeat traffic cannot evict them. All exports use
fixed enums, numbers, and booleans; no book text, prompts, replies, endpoints,
credentials, exception messages, or arbitrary provider IDs are included.

Interpretation must distinguish observations from causes:

- Continuous worker samples with late UI/native receipt indicate delayed UI or
  channel delivery, not a stopped worker
- Continuous native samples with a worker gap narrow the delay to Dart or its
  execution dependencies; this does not by itself identify a Flutter bug
- Gaps in both samples require device/system evidence; an unchanged PID and
  foreground-service notification alone do not prove or disprove freezing
- `body_cancel_requested` can be normal parser cleanup after a complete reply;
  only `cancel_requested` identifies run cancellation, with its recorded cause
- Early transport errors followed by late status updates can be distinguished
  from errors first observed late; ordered in-flight requests are still drained
  to preserve successful work before final settlement
- Native elapsed time is since boot, while Dart elapsed time is since its run or
  request. Compare intervals within each clock; wall times provide alignment
  but may change if the device clock changes

Use one reproduction on the affected device, export immediately after the error
without manually resuming the book, and compare the same request's events. JVM
and offline tests verify bounded/redacted evidence and resource cleanup only;
they cannot establish device-background execution or a provider-side outcome.

## Resuming an accepted System One check

Find N5 diagnostics showed successful foreground-service admission, delayed native
and Dart samples after backgrounding, and `http_exception` before receiving the
last two replies. The matching NAS window contained two `/v1/systemone` 499s.
These observations do not establish which device/system component cut the socket.

System One requests now offer `Prefer: respond-async`. Ordinary 200 responses keep
the existing path. A service may explicitly accept with 202,
`Preference-Applied: respond-async`, and a same-origin `Location`. The client then
reads that result with GET. Dropped reads, temporary server errors and partial
responses retry GET for up to ten minutes; they do not replay inference POSTs.
Explicit pause still cancels client work. Initial acceptance lost before headers,
process death and expired server results retain the existing uncertain-outcome
handling. Book-generation support is described below; ordinary providers keep their existing streaming path.

The personal service implementation is in `tools/systemone/`: it computes accepted
checks independently of the HTTP connection and retains the latest 256 completed
results on disk. Identical authenticated inputs and model revision share one job.
Polling requires authentication, never starts inference and never recreates a lost
job. No request text is written to this result store. Existing synchronous clients
remain supported. This protocol is optional, not tied to a model name in the app.

When the background-session observer itself has not run for over 60 seconds, it
allows one heartbeat interval for delayed worker evidence before retiring a stale
worker. That grace neither fabricates a heartbeat nor renews the CPU lease.

Focused validation: lost/partial polling replies recover with one inference POST;
cross-origin result URLs are rejected; initial POST failure and expired jobs never
resubmit inference; explicit pause stops polling; completed server results survive
a service restart; observer suspension does not immediately cancel healthy work,
and truly missing workers still expire. Device confirmation remains necessary.

## Retaining book-generation results

The next Find N5 reproduction advanced to 24/603 segments and completed a
chapter biography. Its System One polls returned 202 then 200 successfully.
The failing request was a Qwen stream started at 22:40:01: it had HTTP 200 and
329,887 received bytes before `http_exception` at 22:41:05, just as the activity
resumed. It had no explicit user cancellation. This is a different path from
the earlier pre-connection failure and the synchronous System One requests.

Book-processing chat now offers the same optional asynchronous protocol.
The personal NAS relay in `tools/resumable_chat` completes the original Qwen
request independently of the phone, saves the entire response, and returns it
in a status/content-type/body envelope. The shared result poller retries reads
of that saved response, including interrupted downloads. The client parses the
original SSE only after the entire envelope is available, preserving completion
checks and avoiding partial text or duplicate generation. Interactive chat does
not opt in. Other providers can ignore the preference and return their usual
stream. Neither the model nor book extraction/biography validation changed.

Validation includes a local upstream continuing after the original connection
closes, a truncated result read, retrieval after restart, authentication, and
exactly one upstream generation. A real Dart client through NAS TLS to Qwen
recovered from an injected first GET failure: one inference POST, two result
GETs, nonempty completed response, no uncertain request left. Find N5 hardware
confirmation remains necessary. Initial lost acceptance, process death, expired
results and a broken NAS-to-Qwen connection retain explicit recovery semantics.
