package org.omnilink.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * User-controlled Android 14+ Foreground Service for continuous offline radio listening.
 * Enforces foregroundServiceType="connectedDevice" policy.
 * See docs/09_android_native_transport_design.md for rules.
 */
class OmnilinkForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "omnilink_offline_channel"
        private const val NOTIFICATION_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OMNILINK Offline Network",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active listening for nearby offline devices over Bluetooth and Wi-Fi."
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("OMNILINK Offline Network Active")
            .setContentText("Listening for nearby devices over direct radio link...")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }
}
