package com.yedu.zhupi

import android.app.NotificationManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class ServiceSmokeTest {
    @Test
    fun createsChannelAndStopsWithoutStickyRestart() {
        val controller =
            Robolectric.buildService(ProcessingNotificationService::class.java).create()
        val service = controller.get()
        val manager = service.getSystemService(NotificationManager::class.java)
        assertNotNull(manager.getNotificationChannel("book_processing"))
        assertEquals(android.app.Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1))
        assertTrue(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }
}
