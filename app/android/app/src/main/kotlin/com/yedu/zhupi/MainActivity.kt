package com.yedu.zhupi

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val pendingImports = mutableListOf<Map<String, String>>()
    private val importExecutor = Executors.newSingleThreadExecutor()

    override fun provideFlutterEngine(context: Context): FlutterEngine = ProcessingEngineHost.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

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
        ProcessingEngineHost.attachImports(this) {
            val ready = pendingImports.toList()
            pendingImports.clear()
            ready
        }
    }

    private fun requestProcessingNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !getSharedPreferences("processing_notifications", MODE_PRIVATE).getBoolean("permission_asked", false)
        ) {
            getSharedPreferences("processing_notifications", MODE_PRIVATE)
                .edit().putBoolean("permission_asked", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
        }
    }

    override fun onResume() {
        super.onResume()
        ProcessingRuntimeDiagnostics.record(this, "activity_resumed")
        ProcessingEngineHost.requestNotificationPermission = ::requestProcessingNotificationPermission
        if (ProcessingNotificationService.runtimeState()["running"] == true) requestProcessingNotificationPermission()
    }

    override fun onPause() {
        ProcessingEngineHost.requestNotificationPermission = null
        ProcessingRuntimeDiagnostics.record(this, "activity_paused")
        super.onPause()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        ProcessingRuntimeDiagnostics.record(this, "activity_configuration_changed")
    }

    override fun onStop() {
        ProcessingRuntimeDiagnostics.record(this, "activity_stopped")
        super.onStop()
    }

    private fun receiveProcessingTap(incoming: Intent?) {
        val bookId = incoming?.getStringExtra(ProcessingNotificationService.EXTRA_BOOK_ID)
        if (bookId == null || !ProcessingNotificationService.validBookId(bookId)) return
        ProcessingEngineHost.openBook(bookId)
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
                ProcessingEngineHost.importsAvailable(this)
            }
        }
    }

    override fun onDestroy() {
        importExecutor.shutdownNow()
        pendingImports.forEach { it["path"]?.let { path -> File(path).delete() } }
        pendingImports.clear()
        ProcessingEngineHost.detachImports(this)
        ProcessingRuntimeDiagnostics.record(this, "activity_destroyed")
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST = 64031
    }
}
