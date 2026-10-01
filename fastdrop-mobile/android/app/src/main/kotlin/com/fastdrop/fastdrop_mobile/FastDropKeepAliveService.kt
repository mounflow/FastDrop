package com.fastdrop.fastdrop_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 常驻前台服务：让手机在**熄屏/后台**时仍能接收电脑发来的文件。
 *
 * 仅有前台服务不足以让 socket 服务端响应：熄屏后 CPU 进入休眠，Flutter
 * isolate 被冻结，端口不可达（实测：熄屏后 http://<手机>:9527/health 无响应，
 * 唤醒后才恢复）。因此这里同时持有：
 *  - PARTIAL_WAKE_LOCK：保持 CPU 可运行（不休眠），使 Dart 侧的服务端能处理
 *    入站连接与分块写入；
 *  - WifiLock（HIGH_PERF / LOW_LATENCY）：避免 Wi-Fi 射频在省电模式下进入
 *    低功耗而丢包。
 * 两者随服务生命周期获取/释放；用户在设置里关闭"允许接收文件"即停止服务，
 * 不额外耗电。
 */
class FastDropKeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(notificationId, buildNotification())
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 被系统回收（含厂商省电策略）后自动重建，保证"随时可接收"。
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:fastdrop-receive",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "$packageName:fastdrop-receive").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            channelId,
            "FastDrop background receiving",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps local file receiving available while FastDrop is in the background."
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_fastdrop_status)
            .setContentTitle("FastDrop 可随时接收文件")
            .setContentText("同一 Wi-Fi 下的已配对设备可以直接发送。")
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        private const val channelId = "fastdrop_background_receive"
        private const val notificationId = 9527

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, FastDropKeepAliveService::class.java),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, FastDropKeepAliveService::class.java))
        }
    }
}
