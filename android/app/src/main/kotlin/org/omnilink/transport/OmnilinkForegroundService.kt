package org.omnilink.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Android 14+ Compliant Foreground Service for continuous background mesh listening & DTN routing.
 * Uses foregroundServiceType="connectedDevice".
 * Ensures Nearby Connections radio scanners survive activity lock, backgrounding, and Doze mode.
 */
class OmnilinkForegroundService : Service() {

    companion object {
        private const val TAG = "OMNILINK_SERVICE"
        private const val CHANNEL_ID = "omnilink_mesh_channel"
        private const val NOTIFICATION_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "OmnilinkForegroundService created.")
        createNotificationChannel()
        // Retain background radio manager
        NearbyConnectionsManager.getInstance(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "OmnilinkForegroundService starting in foreground...")
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OMNILINK Mesh Active Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps OMNILINK mesh scanning and store-and-forward routing active in background."
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
            .setContentTitle("OMNILINK Mesh Active")
            .setContentText("Searching for peers and routing messages in background...")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        Log.i(TAG, "OmnilinkForegroundService destroyed.")
        super.onDestroy()
    }
}
