package com.yedu.zhupi;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import com.chaquo.python.Python;

import org.json.JSONObject;

import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Keep the in-process Python worker alive while a user-started book job is active. */
public class ProcessingService extends Service {
    private static final String CHANNEL = "book-processing";
    private static final int NOTIFICATION = 1001;
    private final ExecutorService monitor = Executors.newSingleThreadExecutor();
    private volatile boolean running;
    private PowerManager.WakeLock wakeLock;

    @Override public void onCreate() {
        super.onCreate();
        NotificationChannel channel = new NotificationChannel(CHANNEL,
                UiLanguage.get(this, R.string.processing_channel), NotificationManager.IMPORTANCE_LOW);
        getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }

    private Notification notification(String title, String detail) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(detail)
                .setContentIntent(pending)
                .setOngoing(true)
                .build();
    }

    private void publish(Notification value) {
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(NOTIFICATION, value, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else startForeground(NOTIFICATION, value);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        publish(notification(UiLanguage.get(this, R.string.preparing_processing),
                UiLanguage.get(this, R.string.books_readable)));
        if (!running) {
            running = true;
            PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Yedu:BookProcessing");
            wakeLock.acquire();
            monitor.submit(() -> watch(startId));
        }
        return START_STICKY;
    }

    private void watch(int startId) {
        try {
            Python.getInstance().getModule("android_bootstrap")
                    .callAttr("start", new File(getFilesDir(), "yedu").getAbsolutePath());
            while (running && !Thread.currentThread().isInterrupted()) {
                JSONObject state = new JSONObject(Python.getInstance().getModule("android_bootstrap")
                        .callAttr("processing_status").toString());
                if (!state.optBoolean("active")) break;
                String title = state.optString("title", UiLanguage.get(this, R.string.book_fallback));
                String detail = "finalizing".equals(state.optString("state"))
                        ? UiLanguage.get(this, R.string.checking_details)
                        : UiLanguage.get(this, R.string.segment_progress)
                            .replace("{done}", String.valueOf(state.optInt("done")))
                            .replace("{total}", String.valueOf(state.optInt("total")));
                publish(notification(UiLanguage.get(this, R.string.processing_book)
                        .replace("{title}", title), detail));
                Thread.sleep(5000);
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            android.util.Log.e("Yedu", "整理状态监测失败", error);
        } finally {
            running = false;
            stopForeground(true);
            stopSelf(startId);
        }
    }

    @Override public void onTimeout(int startId, int fgsType) {
        // Android 15 gives dataSync services six background hours per day.
        // Stop promptly and leave the source journal ready for the next launch.
        requestStop();
        stopSelf(startId);
    }

    private void requestStop() {
        try {
            Python.getInstance().getModule("android_bootstrap").callAttr("request_processing_stop");
        } catch (Exception error) {
            android.util.Log.e("Yedu", "无法暂停整理", error);
        }
    }

    @Override public void onDestroy() {
        running = false;
        requestStop();
        monitor.shutdownNow();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
