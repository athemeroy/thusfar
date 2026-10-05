package com.yedu.zhupi

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/** Bounded, content-free evidence. Never record book IDs, titles, URLs or errors' messages. */
internal object ProcessingRuntimeDiagnostics {
    private const val PREFS = "processing_runtime_diagnostics"
    private const val TAG = "ThusfarProcessing"
    private const val LIMIT = 64

    @Synchronized
    fun record(context: Context, event: String, failure: Throwable? = null) {
        val row = JSONObject()
            .put("event", event)
            .put("at_ms", System.currentTimeMillis())
            .put("elapsed_ms", SystemClock.elapsedRealtime())
            .put("uptime_ms", SystemClock.uptimeMillis())
            .put("pid", Process.myPid())
        failure?.let { row.put("error_type", it.javaClass.simpleName) }
        Log.i(TAG, row.toString())
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previous = try { JSONArray(prefs.getString("events", "[]")) } catch (_: Exception) { JSONArray() }
        val events = JSONArray()
        for (index in maxOf(0, previous.length() - LIMIT + 1) until previous.length()) {
            events.put(previous.get(index))
        }
        events.put(row)
        prefs.edit().putString("events", events.toString()).apply()
    }

    fun snapshot(context: Context): Map<String, Any?> {
        val power = context.getSystemService(PowerManager::class.java)
        val activity = context.getSystemService(ActivityManager::class.java)
        val network = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = network.getNetworkCapabilities(network.activeNetwork)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val events = try { JSONArray(prefs.getString("events", "[]")) } catch (_: Exception) { JSONArray() }
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "pid" to Process.myPid(),
            "elapsed_ms" to SystemClock.elapsedRealtime(),
            "uptime_ms" to SystemClock.uptimeMillis(),
            "interactive" to power.isInteractive,
            "device_idle" to power.isDeviceIdleMode,
            "power_save" to power.isPowerSaveMode,
            "battery_optimization_exempt" to power.isIgnoringBatteryOptimizations(context.packageName),
            "background_restricted" to (Build.VERSION.SDK_INT >= 28 && activity.isBackgroundRestricted),
            "network_available" to (network.activeNetwork != null),
            "network_validated" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            "network_metered" to network.isActiveNetworkMetered,
            "background_data_restriction" to network.restrictBackgroundStatus,
            "notifications_enabled" to context.getSystemService(NotificationManager::class.java).areNotificationsEnabled(),
            "service" to ProcessingNotificationService.runtimeState(),
            "events" to (0 until events.length()).map { index ->
                val row = events.getJSONObject(index)
                row.keys().asSequence().associateWith { row.get(it) }
            },
        )
    }
}
