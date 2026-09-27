package com.yedu.zhupi

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var paths: MethodChannel? = null
    private var processingNotifications: MethodChannel? = null
    private var openedProcessingBookId: String? = null
    private val pendingNotificationStarts = mutableListOf<PendingNotificationStart>()
    private val pendingImports = mutableListOf<Map<String, String>>()
    private val importExecutor = Executors.newSingleThreadExecutor()

    private data class PendingNotificationStart(
        val bookId: String,
        val title: String,
        val phase: String,
        val done: Int,
        val total: Int,
        val result: MethodChannel.Result,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored activity may have died before Flutter consumed its copy.
        // Retrying is safe: the library detects duplicate content on import.
        receiveBooks(intent)
        receiveProcessingTap(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveBooks(intent)
        receiveProcessingTap(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The 1.7.x app kept everything under files/yedu; 2.0 reads the same directory.
        paths = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thusfar/paths")
        paths!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "filesDir" -> result.success(filesDir.absolutePath)
                "appVersion" -> {
                    @Suppress("DEPRECATION")
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else {
                        @Suppress("DEPRECATION")
                        info.versionCode.toLong()
                    }
                    result.success("${info.versionName} ($code)")
                }
                "takeImports" -> {
                    val ready = pendingImports.toList()
                    pendingImports.clear()
                    result.success(ready)
                }
                else -> result.notImplemented()
            }
        }
        processingNotifications = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thusfar/processing_notifications")
        ProcessingNotificationService.backgroundLimitListener = { bookIds ->
            processingNotifications?.invokeMethod("backgroundTimeLimit", bookIds)
        }
        processingNotifications!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val start = notificationStart(call, result)
                    if (start == null) {
                        result.error("INVALID_TASK", "整理任务无效", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                        !getSharedPreferences("processing_notifications", MODE_PRIVATE).getBoolean("permission_asked", false) &&
                        pendingNotificationStarts.isEmpty()
                    ) {
                        pendingNotificationStarts.add(start)
                        getSharedPreferences("processing_notifications", MODE_PRIVATE)
                            .edit().putBoolean("permission_asked", true).apply()
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
                    } else if (pendingNotificationStarts.isNotEmpty()) {
                        pendingNotificationStarts.add(start)
                    } else {
                        launchNotification(start)
                    }
                }
                "update" -> {
                    val bookId = call.argument<String>("bookId")
                    val title = call.argument<String>("title")
                    val phase = call.argument<String>("phase")
                    if (bookId == null || title == null || phase == null) {
                        result.error("INVALID_TASK", "整理任务无效", null)
                    } else {
                        result.success(ProcessingNotificationService.update(
                            bookId, title, phase,
                            call.argument<Int>("done") ?: 0,
                            call.argument<Int>("total") ?: 0,
                        ))
                    }
                }
                "stop" -> {
                    val bookId = call.argument<String>("bookId")
                    try {
                        result.success(bookId != null && ProcessingNotificationService.stop(this, bookId))
                    } catch (error: RuntimeException) {
                        result.error("NOTIFICATION_STOP_FAILED", "无法停止整理通知：${error.message ?: "系统限制"}", null)
                    }
                }
                "takeOpenedBookId" -> {
                    result.success(openedProcessingBookId)
                    openedProcessingBookId = null
                }
                "takeBackgroundTimeLimitBookIds" -> {
                    val prefs = getSharedPreferences("processing_notifications", MODE_PRIVATE)
                    result.success(prefs.getStringSet("background_limit_books", emptySet())?.toList() ?: emptyList<String>())
                    prefs.edit().remove("background_limit_books").apply()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun notificationStart(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result): PendingNotificationStart? {
        val bookId = call.argument<String>("bookId") ?: return null
        val title = call.argument<String>("title") ?: return null
        val phase = call.argument<String>("phase") ?: return null
        if (!ProcessingNotificationService.validBookId(bookId)) return null
        return PendingNotificationStart(
            bookId, title, phase,
            call.argument<Int>("done") ?: 0,
            call.argument<Int>("total") ?: 0,
            result,
        )
    }

    private fun launchNotification(start: PendingNotificationStart) {
        try {
            ProcessingNotificationService.start(
                this, start.bookId, start.title, start.phase, start.done, start.total,
            )
            val manager = getSystemService(NotificationManager::class.java)
            start.result.success(manager.areNotificationsEnabled())
        } catch (error: RuntimeException) {
            start.result.error("NOTIFICATION_START_FAILED", "无法显示整理通知：${error.message ?: "系统限制"}", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val pending = pendingNotificationStarts.toList()
        pendingNotificationStarts.clear()
        pending.forEach(::launchNotification)
    }

    private fun receiveProcessingTap(incoming: Intent?) {
        val bookId = incoming?.getStringExtra(ProcessingNotificationService.EXTRA_BOOK_ID)
        if (bookId == null || !ProcessingNotificationService.validBookId(bookId)) return
        openedProcessingBookId = bookId
        processingNotifications?.invokeMethod("openBook", bookId)
        incoming.removeExtra(ProcessingNotificationService.EXTRA_BOOK_ID)
    }

    @Suppress("DEPRECATION")
    private fun receiveBooks(incoming: Intent?) {
        if (incoming == null) return
        val uris = when (incoming.action) {
            Intent.ACTION_VIEW -> listOfNotNull(incoming.data)
            Intent.ACTION_SEND -> listOfNotNull(incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> incoming.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList() ?: emptyList()
            else -> emptyList()
        }.distinct()
        if (uris.isEmpty()) return
        if (uris.size > 32) {
            publishImports(listOf(mapOf("name" to "书籍", "error" to "一次最多打开 32 个文件，请分批导入")))
            return
        }
        // Never read another app's content provider on Android's UI thread.
        importExecutor.execute { publishImports(uris.map(::copyBook)) }
    }

    private fun copyBook(uri: Uri): Map<String, String> {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "书籍"
        var target: File? = null
        try {
            require(uri.scheme == "content") { "请从文件管理器重新打开这本书" }
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    cursor.getString(index)?.takeIf { it.isNotBlank() }?.let { name = it }
                }
            }
            val lower = name.lowercase()
            require(lower.endsWith(".txt") || lower.endsWith(".epub") || lower.endsWith(".json")) {
                "支持 TXT、EPUB 和页读备份（.json）"
            }
            val folder = File(cacheDir, "incoming-books").apply { mkdirs() }
            val copied = File.createTempFile("book-", ".import", folder)
            target = copied
            val input = contentResolver.openInputStream(uri) ?: error("无法打开这个文件")
            input.use { source ->
                copied.outputStream().use { destination ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        check(!Thread.currentThread().isInterrupted) { "导入已停止，请重新打开文件" }
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 200L * 1024 * 1024) { "文件太大，请选择 200 MB 以内的书籍" }
                        destination.write(buffer, 0, count)
                    }
                    require(total > 0) { "文件是空的" }
                }
            }
            return mapOf("name" to name, "path" to copied.absolutePath)
        } catch (error: Exception) {
            target?.delete()
            val message = if (error is IllegalArgumentException || error is IllegalStateException) {
                error.message ?: "无法读取这本书，请重新从文件管理器打开"
            } else {
                "无法读取这本书，请重新从文件管理器打开"
            }
            return mapOf("name" to name, "error" to message)
        }
    }

    private fun publishImports(items: List<Map<String, String>>) {
        runOnUiThread {
            if (isDestroyed) {
                items.forEach { it["path"]?.let { path -> File(path).delete() } }
            } else {
                pendingImports.addAll(items)
                paths?.invokeMethod("importsAvailable", null)
            }
        }
    }

    override fun onDestroy() {
        importExecutor.shutdownNow()
        pendingImports.forEach { it["path"]?.let { path -> File(path).delete() } }
        pendingImports.clear()
        paths?.setMethodCallHandler(null)
        paths = null
        pendingNotificationStarts.forEach {
            it.result.error("ACTIVITY_CLOSED", "整理通知请求已取消", null)
        }
        pendingNotificationStarts.clear()
        processingNotifications?.setMethodCallHandler(null)
        processingNotifications = null
        ProcessingNotificationService.backgroundLimitListener = null
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST = 64031
    }
}
