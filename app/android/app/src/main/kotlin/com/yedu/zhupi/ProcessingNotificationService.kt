package com.yedu.zhupi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

private data class BookTask(
    val id: String,
    val title: String,
    val phase: String,
    val done: Int,
    val total: Int,
)

/** Keeps visible progress for the in-process Dart worker; it cannot restart that worker. */
class ProcessingNotificationService : Service() {
    private val tasks = linkedMapOf<String, BookTask>()
    private lateinit var notifications: NotificationManager
    private var foregroundId: Int? = null

    override fun onCreate() {
        super.onCreate()
        notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "书籍整理", NotificationManager.IMPORTANCE_LOW).apply {
                description = "显示正在整理的书籍和真实进度"
                setShowBadge(false)
            },
        )
        instance = this
        startPending = false
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            intent.getStringExtra(EXTRA_BOOK_ID)?.let(::remove)
            if (tasks.isEmpty()) stopSelf(startId)
            return START_NOT_STICKY
        }
        val task = taskFrom(intent)
        if (task == null) {
            if (tasks.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        if (task.id !in desiredBooks) {
            // The user may have stopped the book while Android was still
            // creating this service for an earlier START command.
            if (tasks.isEmpty()) stopSelf(startId)
            return START_NOT_STICKY
        }
        upsert(task)
        return START_NOT_STICKY
    }

    private fun taskFrom(intent: Intent?): BookTask? {
        val id = intent?.getStringExtra(EXTRA_BOOK_ID) ?: return null
        if (!validBookId(id)) return null
        val phase = intent.getStringExtra(EXTRA_PHASE) ?: return null
        if (phase !in PHASES) return null
        return BookTask(
            id = id,
            title = intent.getStringExtra(EXTRA_TITLE)?.trim()?.take(60)?.ifEmpty { "这本书" } ?: "这本书",
            phase = phase,
            done = intent.getIntExtra(EXTRA_DONE, 0).coerceAtLeast(0),
            total = intent.getIntExtra(EXTRA_TOTAL, 0).coerceAtLeast(0),
        )
    }

    private fun upsert(task: BookTask) {
        tasks[task.id] = task
        publish()
    }

    private fun remove(id: String) {
        if (tasks.remove(id) == null) return
        notifications.cancel(notificationId(id))
        publish()
    }

    private fun publish() {
        val foreground = tasks.values.firstOrNull { it.phase != "queued" } ?: tasks.values.firstOrNull()
        if (foreground == null) {
            foregroundId = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        val id = notificationId(foreground.id)
        // The service and the Dart isolate share this process. START_NOT_STICKY avoids
        // displaying a restarted task after Android has killed its actual worker.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, notification(foreground), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(id, notification(foreground))
        }
        val old = foregroundId
        foregroundId = id
        for (task in tasks.values) {
            if (task.id != foreground.id) notifications.notify(notificationId(task.id), notification(task))
        }
        if (old != null && old != id && tasks.values.none { notificationId(it.id) == old }) {
            notifications.cancel(old)
        }
    }

    private fun notification(task: BookTask): Notification {
        val id = notificationId(task.id)
        val open = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            putExtra(EXTRA_BOOK_ID, task.id)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val tap = PendingIntent.getActivity(
            this,
            id,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val progressKnown = task.total > 0 && task.phase != "queued"
        val line = when (task.phase) {
            "queued" -> "等待整理"
            "preparing" -> "正在准备整理"
            "waiting" -> if (progressKnown) "已整理 ${task.done.coerceAtMost(task.total)} / ${task.total} 段 · 等待模型回复" else "等待模型回复"
            "finalizing" -> "正在汇总人物与前情"
            else -> if (progressKnown) "已整理 ${task.done.coerceAtMost(task.total)} / ${task.total} 段" else "正在整理"
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_book)
            .setContentTitle(if (task.phase == "queued") "《${task.title}》等待整理" else "《${task.title}》正在整理")
            .setContentText(line)
            .setContentIntent(tap)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                Notification.Builder(this, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_book)
                    .setContentTitle("页读正在整理书籍")
                    .build(),
            )
            .setProgress(
                if (progressKnown) task.total else 0,
                if (progressKnown) task.done.coerceIn(0, task.total) else 0,
                !progressKnown && task.phase != "queued",
            )
            .build()
    }

    private fun notificationId(bookId: String): Int {
        val prefs = getSharedPreferences("processing_notification_ids", Context.MODE_PRIVATE)
        val key = "book_$bookId"
        val known = prefs.getInt(key, 0)
        if (known != 0) return known
        val next = prefs.getInt("next", 1000) + 1
        prefs.edit().putInt(key, next).putInt("next", next).apply()
        return next
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        startPending = false
        for (bookId in tasks.keys) notifications.cancel(notificationId(bookId))
        tasks.clear()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15+ dataSync has a per-app time allowance. Keep a durable
        // signal for the Flutter worker/UI; stopping this service cannot by
        // itself settle the in-process model requests.
        val affected = tasks.keys.toSet()
        getSharedPreferences("processing_notifications", Context.MODE_PRIVATE)
            .edit().putStringSet("background_limit_books", affected).commit()
        try {
            backgroundLimitListener?.invoke(affected.toList())
        } catch (_: RuntimeException) {
            // The Android timeout still has to stop this service promptly.
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        try {
            tasks.values.firstOrNull()?.let { task ->
                val open = Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    putExtra(EXTRA_BOOK_ID, task.id)
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                val tap = PendingIntent.getActivity(
                    this,
                    notificationId(task.id) + 1_000_000,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                notifications.notify(
                    notificationId(task.id) + 1_000_000,
                    Notification.Builder(this, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_stat_book)
                        .setContentTitle("页读后台整理时段已结束")
                        .setContentText("打开页读查看整理状态")
                        .setContentIntent(tap)
                        .setAutoCancel(true)
                        .setVisibility(Notification.VISIBILITY_PRIVATE)
                        .build(),
                )
            }
        } catch (_: RuntimeException) {
            // A disabled notification channel must not cause an FGS timeout ANR.
        }
        stopSelf()
    }

    companion object {
        const val EXTRA_BOOK_ID = "processingBookId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PHASE = "phase"
        private const val EXTRA_DONE = "done"
        private const val EXTRA_TOTAL = "total"
        private const val CHANNEL_ID = "book_processing"
        private const val ACTION_UPSERT = "com.yedu.zhupi.PROCESSING_UPSERT"
        private const val ACTION_STOP = "com.yedu.zhupi.PROCESSING_STOP"
        private val PHASES = setOf("queued", "preparing", "waiting", "running", "finalizing")
        private var instance: ProcessingNotificationService? = null
        private var startPending = false
        private val desiredBooks = mutableSetOf<String>()
        var backgroundLimitListener: ((List<String>) -> Unit)? = null
        fun validBookId(id: String): Boolean = id.length in 1..128 && id.all {
            it.isLetterOrDigit() || it == '-' || it == '_' || it == '.'
        }

        fun start(context: Context, bookId: String, title: String, phase: String, done: Int, total: Int) {
            require(validBookId(bookId) && phase in PHASES) { "整理任务无效" }
            val task = BookTask(bookId, title.trim().take(60).ifEmpty { "这本书" }, phase, done.coerceAtLeast(0), total.coerceAtLeast(0))
            val intent = Intent(context, ProcessingNotificationService::class.java).apply {
                action = ACTION_UPSERT
                putExtra(EXTRA_BOOK_ID, task.id)
                putExtra(EXTRA_TITLE, task.title)
                putExtra(EXTRA_PHASE, task.phase)
                putExtra(EXTRA_DONE, task.done)
                putExtra(EXTRA_TOTAL, task.total)
            }
            desiredBooks.add(bookId)
            try {
                if (instance != null) {
                    context.startService(intent)
                } else {
                    startPending = true
                    context.startForegroundService(intent)
                }
            } catch (error: RuntimeException) {
                desiredBooks.remove(bookId)
                if (instance == null) startPending = false
                throw error
            }
        }

        fun update(bookId: String, title: String, phase: String, done: Int, total: Int): Boolean {
            if (!validBookId(bookId) || phase !in PHASES || bookId !in desiredBooks) return false
            val running = instance ?: return false
            running.upsert(BookTask(bookId, title.trim().take(60).ifEmpty { "这本书" }, phase, done.coerceAtLeast(0), total.coerceAtLeast(0)))
            return true
        }

        fun stop(context: Context, bookId: String): Boolean {
            if (!validBookId(bookId)) return false
            desiredBooks.remove(bookId)
            val running = instance
            running?.remove(bookId)
            if (running == null && !startPending) return false
            if (running == null) {
                // A startForegroundService intent may still be queued. STOP is
                // ordered after it; desiredBooks also rejects a late START if
                // Android refuses to enqueue this second intent in background.
                try {
                    context.startService(Intent(context, ProcessingNotificationService::class.java).apply {
                        action = ACTION_STOP
                        putExtra(EXTRA_BOOK_ID, bookId)
                    })
                } catch (_: RuntimeException) {
                    // The tombstone above is the authoritative cancellation.
                }
            }
            return true
        }
    }
}
