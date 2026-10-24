package com.linote.diffstudio;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

/** Keeps the process alive (and the CPU awake) while a release is analysed or a device is updated. */
public final class WorkService extends Service {
    static final String CHANNEL = "work";
    static final String EXTRA_TEXT = "text";
    private PowerManager.WakeLock lock;

    static void start(Context ctx, String text) {
        Intent i = new Intent(ctx, WorkService.class).putExtra(EXTRA_TEXT, text);
        try {
            ctx.startForegroundService(i);
        } catch (RuntimeException ignored) {
            // Background-start restrictions: the work still runs while the app is visible.
        }
    }

    static void stop(Context ctx) {
        ctx.stopService(new Intent(ctx, WorkService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "OpenWrt Diff Studio", NotificationManager.IMPORTANCE_LOW));
        }
        String text = intent == null ? null : intent.getStringExtra(EXTRA_TEXT);
        PendingIntent open = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_work)
                .setContentTitle("OpenWrt Diff Studio")
                .setContentText(text == null ? "" : text)
                .setOngoing(true)
                .setContentIntent(open)
                .build();
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            else startForeground(1, n);
        } catch (RuntimeException e) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (lock == null) {
            PowerManager pm = getSystemService(PowerManager.class);
            if (pm != null) {
                lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "diffstudio:work");
                lock.setReferenceCounted(false);
                lock.acquire(6 * 60 * 60 * 1000L);
            }
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        if (lock != null && lock.isHeld()) lock.release();
        lock = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
