package com.yedu.zhupi

import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/** User-initiated system settings only; never changes task ownership or progress. */
internal object BackgroundProcessingSettings {
    fun handle(context: Context, method: String, result: MethodChannel.Result) {
        val power = context.getSystemService(PowerManager::class.java)
        val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"))
        if (method == "status") {
            result.success(mapOf(
                "batteryExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
                "powerSave" to power.isPowerSaveMode,
                "backgroundRestricted" to (Build.VERSION.SDK_INT >= 28 &&
                    context.getSystemService(ActivityManager::class.java).isBackgroundRestricted),
                "notifications" to context.getSystemService(NotificationManager::class.java).areNotificationsEnabled(),
                "manufacturer" to Build.MANUFACTURER,
            ))
            return
        }
        val intent = when (method) {
            "requestBatteryExemption" -> {
                if (power.isIgnoringBatteryOptimizations(context.packageName)) {
                    result.success(null)
                    return
                }
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}"))
            }
            "openAppSettings" -> appDetails
            "openNotificationSettings" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            else -> { result.notImplemented(); return }
        }
        try {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: ActivityNotFoundException) {
                context.startActivity(appDetails.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            ProcessingRuntimeDiagnostics.record(context, "background_settings_opened")
            result.success(null)
        } catch (_: RuntimeException) {
            result.error("SETTINGS_UNAVAILABLE", "请长按页读图标，打开应用信息中的耗电管理。", null)
        }
    }
}
