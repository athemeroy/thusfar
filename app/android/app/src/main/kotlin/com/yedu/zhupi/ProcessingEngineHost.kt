package com.yedu.zhupi

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One app-owned engine: detaching/destroying an Activity must not destroy paid work.
 * It is created only when the user opens the app, never by a restarted service.
 * Process death still uses the Dart worker's durable recovery on the next launch.
 */
internal object ProcessingEngineHost {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var openedBookId: String? = null
    private var paths: MethodChannel? = null
    private var importOwner: Any? = null
    private var takeImports: (() -> List<Map<String, String>>)? = null
    var requestNotificationPermission: (() -> Unit)? = null

    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val created = FlutterEngine(app)
        engine = created
        MethodChannel(created.dartExecutor.binaryMessenger, "thusfar/background_settings")
            .setMethodCallHandler { call, result ->
                BackgroundProcessingSettings.handle(app, call.method, result)
            }
        val appPaths = MethodChannel(created.dartExecutor.binaryMessenger, "thusfar/paths")
        paths = appPaths
        appPaths.setMethodCallHandler { call, result ->
            when (call.method) {
                "filesDir" -> result.success(app.filesDir.absolutePath)
                "appVersion" -> {
                    @Suppress("DEPRECATION")
                    val info = app.packageManager.getPackageInfo(app.packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else {
                        @Suppress("DEPRECATION")
                        info.versionCode.toLong()
                    }
                    result.success("${info.versionName} ($code)")
                }
                "takeImports" -> result.success(takeImports?.invoke() ?: emptyList<Map<String, String>>())
                else -> result.notImplemented()
            }
        }
        val notifications = MethodChannel(created.dartExecutor.binaryMessenger, "thusfar/processing_notifications")
        channel = notifications
        ProcessingNotificationService.backgroundLimitListener = { bookIds ->
            notifications.invokeMethod("backgroundTimeLimit", bookIds)
        }
        notifications.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val id = call.argument<String>("bookId")
                    val title = call.argument<String>("title")
                    val phase = call.argument<String>("phase")
                    if (id == null || title == null || phase == null || !ProcessingNotificationService.validBookId(id)) {
                        result.error("INVALID_TASK", "整理任务无效", null)
                    } else {
                        val done = call.argument<Int>("done") ?: 0
                        val total = call.argument<Int>("total") ?: 0
                        try {
                            if (call.method == "update") {
                                result.success(ProcessingNotificationService.update(id, title, phase, done, total))
                            } else {
                                ProcessingNotificationService.start(app, id, title, phase, done, total) { started ->
                                    started.fold(
                                        onSuccess = {
                                            // Foreground execution is established before a permission dialog.
                                            result.success(app.getSystemService(NotificationManager::class.java).areNotificationsEnabled())
                                            try {
                                                requestNotificationPermission?.invoke()
                                            } catch (error: RuntimeException) {
                                                ProcessingRuntimeDiagnostics.record(app, "notification_permission_failed", error)
                                            }
                                        },
                                        onFailure = { result.error("FOREGROUND_START_FAILED", "后台整理服务未能启动，请回到页读后重试", null) },
                                    )
                                }
                            }
                        } catch (error: RuntimeException) {
                            ProcessingRuntimeDiagnostics.record(app, "foreground_command_failed", error)
                            result.error("FOREGROUND_COMMAND_FAILED", "后台整理服务不可用，请回到页读后重试", null)
                        }
                    }
                }
                "stop" -> {
                    val id = call.argument<String>("bookId")
                    result.success(id != null && ProcessingNotificationService.stop(app, id))
                }
                "takeOpenedBookId" -> {
                    result.success(openedBookId)
                    openedBookId = null
                }
                "takeBackgroundTimeLimitBookIds" -> {
                    val prefs = app.getSharedPreferences("processing_notifications", Context.MODE_PRIVATE)
                    result.success(prefs.getStringSet("background_limit_books", emptySet())?.toList() ?: emptyList<String>())
                    prefs.edit().remove("background_limit_books").apply()
                }
                "workerHeartbeat" -> {
                    val sample = mutableMapOf<String, Long>()
                    for (key in setOf("at_ms", "elapsed_ms", "gap_ms", "sequence")) {
                        call.argument<Number>(key)?.toLong()?.takeIf { it >= 0 }?.let {
                            sample["worker_$key"] = it
                        }
                    }
                    call.argument<Number>("ui_at_ms")?.toLong()?.takeIf { it >= 0 }?.let {
                        sample["ui_at_ms"] = it
                    }
                    ProcessingRuntimeDiagnostics.record(app, "worker_heartbeat", sample = sample)
                    result.success(null)
                }
                "diagnostics" -> result.success(ProcessingRuntimeDiagnostics.snapshot(app))
                "lifecycle" -> {
                    val state = call.argument<String>("state")
                    if (state in setOf("resumed", "inactive", "hidden", "paused", "detached")) {
                        ProcessingRuntimeDiagnostics.record(app, "dart_$state")
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        ProcessingRuntimeDiagnostics.record(app, "engine_started")
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun attachImports(owner: Any, take: () -> List<Map<String, String>>) {
        importOwner = owner
        takeImports = take
    }

    fun detachImports(owner: Any) {
        if (importOwner !== owner) return
        importOwner = null
        takeImports = null
    }

    fun importsAvailable(owner: Any) {
        if (importOwner === owner) paths?.invokeMethod("importsAvailable", null)
    }

    fun openBook(bookId: String) {
        openedBookId = bookId
        channel?.invokeMethod("openBook", bookId)
    }
}
