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
 * Android 14+ (API 34) Foreground Service for OMNILINK offline mesh radio scanning.
 * Uses foregroundServiceType="connectedDevice".
 * Keeps Nearby Connections Bluetooth/Wi-Fi active while phone screen is locked or in pocket.
 */
class OmnilinkMeshService : Service() {

    companion object {
        private const val TAG = "OMNILINK_MESH_SERVICE"
        private const val CHANNEL_ID = "omnilink_mesh_channel"
        private const val NOTIFICATION_ID = 1001
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "OmnilinkMeshService created.")
        createNotificationChannel()
        // Initialize/retain Nearby Connections Manager in background service process
        NearbyConnectionsManager.getInstance(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "OmnilinkMeshService onStartCommand called.")
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
                "OMNILINK Mesh Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active listening for nearby mesh nodes over Bluetooth & Wi-Fi Direct."
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
        Log.i(TAG, "OmnilinkMeshService destroyed.")
        super.onDestroy()
    }
}
