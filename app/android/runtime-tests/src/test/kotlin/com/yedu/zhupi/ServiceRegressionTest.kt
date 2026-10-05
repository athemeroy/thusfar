package com.yedu.zhupi

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Looper
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
@LooperMode(LooperMode.Mode.PAUSED)
class ServiceRegressionTest {
    private val app
        get() = RuntimeEnvironment.getApplication()

    private var controller: ServiceController<ProcessingNotificationService>? = null
    private val ids = mutableSetOf<String>()

    private fun create(): ProcessingNotificationService {
        controller = Robolectric.buildService(ProcessingNotificationService::class.java).create()
        return controller!!.get()
    }

    private fun request(
        id: String = "book1",
        phase: String = "running",
        done: Int = 1,
        total: Int = 4,
        callback: (Result<Unit>) -> Unit = {},
    ): Intent {
        ids.add(id)
        ProcessingNotificationService.start(app, id, "Title $id", phase, done, total, callback)
        return shadowOf(app).nextStartedService!!
    }

    private fun start(
        id: String = "book1",
        phase: String = "running",
    ): ProcessingNotificationService {
        val intent = request(id, phase)
        val service = controller?.get() ?: create()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(intent, 0, 1))
        return service
    }

    private fun state() = ProcessingNotificationService.runtimeState()

    @After
    fun cleanup() {
        ProcessingNotificationService.backgroundLimitListener = null
        ids.forEach { ProcessingNotificationService.stop(app, it) }
        controller?.destroy()
    }

    @Test
    fun acknowledgmentWaitsForForegroundAndWakeLease() {
        val results = mutableListOf<Result<Unit>>()
        var callbackState: Map<String, Any>? = null
        val intent = request {
            results.add(it)
            callbackState = state()
        }
        assertEquals(0, results.size)
        val service = create()
        assertEquals(0, results.size)
        service.onStartCommand(intent, 0, 1)
        assertEquals(1, results.size)
        assertTrue(results.single().isSuccess)
        assertEquals(true, callbackState!!["running"])
        assertEquals(true, callbackState["wake_lock_held"])
        assertNotNull(shadowOf(service).lastForegroundNotification)
    }

    @Test
    fun stopBeforeServiceCreationRejectsLateStartExactlyOnce() {
        val results = mutableListOf<Result<Unit>>()
        val intent = request(callback = { results.add(it) })
        assertTrue(ProcessingNotificationService.stop(app, "book1"))
        assertEquals(1, results.size)
        assertTrue(results.single().isFailure)
        val service = create()
        service.onStartCommand(intent, 0, 1)
        assertEquals(1, results.size)
        assertEquals(false, state()["wake_lock_held"])
        assertEquals(0, state()["task_count"])
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun cancelledOldIntentCannotAcknowledgeRestartForSameBook() {
        val firstResults = mutableListOf<Result<Unit>>()
        val oldIntent = request(callback = { firstResults.add(it) })
        ProcessingNotificationService.stop(app, "book1")
        val staleStopIntent = shadowOf(app).nextStartedService!!
        val nextResults = mutableListOf<Result<Unit>>()
        val nextIntent = request(callback = { nextResults.add(it) })
        val service = create()
        service.onStartCommand(oldIntent, 0, 1)
        assertEquals(1, firstResults.size)
        assertTrue(firstResults.single().isFailure)
        assertEquals("Stale START cannot finish a later generation", 0, nextResults.size)
        service.onStartCommand(staleStopIntent, 0, 2)
        assertEquals("Stale STOP cannot finish a later generation", 0, nextResults.size)
        assertFalse(
            "Old commands cannot stop a desired new generation",
            shadowOf(service).isStoppedBySelf,
        )
        assertEquals(0, state()["task_count"])
        assertEquals(false, state()["wake_lock_held"])
        service.onStartCommand(nextIntent, 0, 3)
        assertEquals(1, nextResults.size)
        assertTrue(nextResults.single().isSuccess)
        assertEquals(true, state()["wake_lock_held"])
    }

    @Test
    fun supersededOldStartCannotOverwriteNewProgress() {
        val firstResults = mutableListOf<Result<Unit>>()
        val oldIntent =
            request(phase = "preparing", done = 0, total = 8, callback = { firstResults.add(it) })
        val nextResults = mutableListOf<Result<Unit>>()
        val nextIntent =
            request(phase = "running", done = 6, total = 8, callback = { nextResults.add(it) })
        val service = create()
        service.onStartCommand(nextIntent, 0, 2)
        service.onStartCommand(oldIntent, 0, 1)
        assertEquals(1, firstResults.size)
        assertTrue(firstResults.single().isFailure)
        assertEquals(1, nextResults.size)
        assertTrue(nextResults.single().isSuccess)
        assertEquals(
            6,
            shadowOf(service)
                .lastForegroundNotification
                .extras
                .getInt(android.app.Notification.EXTRA_PROGRESS),
        )
    }

    @Test
    fun rejectedForegroundPromotionFailsCallbackAndCleansLease() {
        val results = mutableListOf<Result<Unit>>()
        val intent = request(callback = { results.add(it) })
        val service = create()
        shadowOf(service).setThrowInStartForeground(SecurityException("synthetic denied promotion"))
        service.onStartCommand(intent, 0, 1)
        assertEquals(1, results.size)
        assertTrue(results.single().isFailure)
        assertEquals(false, state()["wake_lock_held"])
        assertEquals(0, state()["task_count"])
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun rejectedStartIntentFailsCallbackWithoutThrowing() {
        val results = mutableListOf<Result<Unit>>()
        val rejected =
            object : ContextWrapper(app) {
                override fun startForegroundService(intent: Intent): ComponentName? =
                    throw IllegalStateException("synthetic unavailable")
            }
        ids.add("book1")
        ProcessingNotificationService.start(rejected, "book1", "Title", "running", 0, 1) {
            results.add(it)
        }
        assertEquals(1, results.size)
        assertTrue(results.single().isFailure)
        assertEquals(false, state()["start_pending"])
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun startupWatchdogFailsCallbackAndRejectsLateIntent() {
        val results = mutableListOf<Result<Unit>>()
        val intent = request(callback = { results.add(it) })
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(11))
        assertEquals(1, results.size)
        assertTrue(results.single().isFailure)
        val service = create()
        service.onStartCommand(intent, 0, 1)
        assertEquals(1, results.size)
        assertEquals(0, state()["task_count"])
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun queuedWorkDoesNotHoldCpuLease() {
        start(phase = "queued")
        assertEquals(false, state()["wake_lock_held"])
        assertTrue(ProcessingNotificationService.update("book1", "Title", "running", 0, 4))
        assertEquals(true, state()["wake_lock_held"])
        assertTrue(ProcessingNotificationService.update("book1", "Title", "queued", 0, 4))
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun lastStopReleasesLeaseButStoppingOneOfTwoDoesNot() {
        start("book1")
        start("book2")
        assertEquals(2, state()["task_count"])
        assertTrue(ProcessingNotificationService.stop(app, "book1"))
        assertEquals(1, state()["task_count"])
        assertEquals(true, state()["wake_lock_held"])
        assertTrue(ProcessingNotificationService.stop(app, "book2"))
        assertEquals(0, state()["task_count"])
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun destructionReleasesLeaseAndRejectsUpdates() {
        start()
        assertEquals(true, state()["wake_lock_held"])
        controller!!.destroy()
        controller = null
        assertEquals(false, state()["wake_lock_held"])
        assertFalse(ProcessingNotificationService.update("book1", "Title", "running", 2, 4))
    }

    @Test
    fun timeoutReleasesLeaseAndRejectsLateProgressBeforeDestroy() {
        val service = start()
        val delivered = mutableListOf<String>()
        ProcessingNotificationService.backgroundLimitListener = { delivered.addAll(it) }
        service.onTimeout(1, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertEquals(listOf("book1"), delivered)
        assertEquals(
            setOf("book1"),
            app.getSharedPreferences("processing_notifications", Context.MODE_PRIVATE)
                .getStringSet("background_limit_books", emptySet()),
        )
        assertEquals(false, state()["wake_lock_held"])
        assertTrue(shadowOf(service).isStoppedBySelf)
        assertFalse(
            "Timeout must invalidate late heartbeats before onDestroy",
            ProcessingNotificationService.update("book1", "Title", "running", 2, 4),
        )
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun timeoutStillStopsWhenListenerFails() {
        val service = start()
        ProcessingNotificationService.backgroundLimitListener = {
            throw IllegalStateException("synthetic listener failure")
        }
        service.onTimeout(1, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        assertEquals(false, state()["wake_lock_held"])
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test
    fun cpuLeaseExpiresWithoutHeartbeat() {
        start()
        assertEquals(true, state()["wake_lock_held"])
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(11))
        assertEquals("Lease must expire without a live heartbeat", false, state()["wake_lock_held"])
    }

    @Test
    fun heartbeatRenewsCpuLeaseBeforeExpiration() {
        start()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(5))
        assertTrue(ProcessingNotificationService.update("book1", "Title", "waiting", 1, 4))
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(6))
        assertEquals(true, state()["wake_lock_held"])
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(5))
        assertEquals(false, state()["wake_lock_held"])
    }

    @Test
    fun queuedBookHandoffKeepsNotificationsAndReleasesThenReacquiresLease() {
        val service = start("book1")
        start("book2", "queued")
        assertTrue(ProcessingNotificationService.stop(app, "book1"))
        assertEquals(1, state()["task_count"])
        assertEquals(false, state()["wake_lock_held"])
        assertTrue(
            shadowOf(service)
                .lastForegroundNotification
                .extras
                .getCharSequence(android.app.Notification.EXTRA_TITLE)
                .toString()
                .contains("book2")
        )
        assertTrue(ProcessingNotificationService.update("book2", "Second", "running", 0, 4))
        assertEquals(true, state()["wake_lock_held"])
    }

    @Test
    fun diagnosticsSnapshotUsesOnlyContentFreeNetworkFlags() {
        val snapshot = ProcessingRuntimeDiagnostics.snapshot(app)
        assertEquals(
            setOf(
                "sdk",
                "pid",
                "elapsed_ms",
                "uptime_ms",
                "interactive",
                "device_idle",
                "power_save",
                "battery_optimization_exempt",
                "background_restricted",
                "network_available",
                "network_validated",
                "network_metered",
                "background_data_restriction",
                "notifications_enabled",
                "service",
                "events",
            ),
            snapshot.keys,
        )
        assertTrue(snapshot["network_available"] is Boolean)
        assertTrue(snapshot["network_validated"] is Boolean)
        assertTrue(snapshot["network_metered"] is Boolean)
        assertTrue(snapshot["background_data_restriction"] is Int)
    }

    @Test
    fun diagnosticsAreBoundedAndDoNotPersistExceptionMessages() {
        val secret = "SECRET_BOOK_OR_CREDENTIAL_SENTINEL"
        repeat(80) {
            ProcessingRuntimeDiagnostics.record(app, "test_event", IllegalArgumentException(secret))
        }
        val raw =
            app.getSharedPreferences("processing_runtime_diagnostics", Context.MODE_PRIVATE)
                .getString("events", "[]")!!
        assertFalse(raw.contains(secret))
        val entries = org.json.JSONArray(raw)
        assertEquals(64, entries.length())
        assertEquals("IllegalArgumentException", entries.getJSONObject(63).getString("error_type"))
    }
}
