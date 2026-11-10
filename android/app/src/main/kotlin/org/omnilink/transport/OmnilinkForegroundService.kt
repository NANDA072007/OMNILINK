package org.omnilink.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Android 14+ compliant foreground service that owns the mesh radio lifecycle.
 *
 * Responsibilities:
 *  - Keep advertising/discovery alive while the app is backgrounded.
 *  - Hold a partial wake lock + Wi-Fi lock so Nearby can finish transfers.
 *  - Re-arm radios periodically (some OEMs silently stop discovery).
 *  - Restore itself after boot and after a process kill (START_STICKY).
 */
class OmnilinkForegroundService : Service() {

    companion object {
        private const val TAG = "OMNILINK_SERVICE"
        private const val CHANNEL_ID = "omnilink_mesh_channel"
        private const val NOTIFICATION_ID = 1001
        private const val MESH_WATCHDOG_INTERVAL_MS = 15_000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val meshWatchdog = object : Runnable {
        override fun run() {
            try {
                val active = NearbyConnectionsManager
                    .getInstance(applicationContext)
                    .ensureMeshActive()
                if (!active) {
                    Log.d(TAG, "Mesh watchdog: radios not ready yet; will retry")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Mesh watchdog failed: ${e.message}", e)
            }
            handler.postDelayed(this, MESH_WATCHDOG_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "OmnilinkForegroundService created.")
        // Keep onCreate minimal: startForeground must happen within the
        // system window after startForegroundService().
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "OmnilinkForegroundService starting/refreshing in foreground...")
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // START_STICKY restarts the service after a process kill. Re-arm the
        // radios here as well because onCreate may be skipped on some OEMs.
        acquireLocks()
        startMesh()
        scheduleWatchdog()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startMesh() {
        try {
            val manager = NearbyConnectionsManager.getInstance(applicationContext)
            manager.ensureMeshActive()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start mesh radios: ${e.message}", e)
        }
    }

    private fun scheduleWatchdog() {
        handler.removeCallbacks(meshWatchdog)
        handler.postDelayed(meshWatchdog, MESH_WATCHDOG_INTERVAL_MS)
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "OMNILINK::MeshWakeLock",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "Partial wake lock acquired")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to acquire wake lock: ${e.message}", e)
            }
        }

        if (wifiLock == null) {
            try {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "OMNILINK::WifiLock").apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "Wi-Fi lock acquired")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to acquire Wi-Fi lock: ${e.message}", e)
            }
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release wake lock: ${e.message}", e)
        } finally {
            wakeLock = null
        }

        try {
            wifiLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release Wi-Fi lock: ${e.message}", e)
        } finally {
            wifiLock = null
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OMNILINK Mesh Active Service",
                NotificationManager.IMPORTANCE_LOW,
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
        Log.i(TAG, "OmnilinkForegroundService destroyed. Cleaning up transports...")
        handler.removeCallbacks(meshWatchdog)
        releaseLocks()

        BluetoothRfcommTransport.getInstance(applicationContext).cleanupAllConnections()
        try {
            NearbyConnectionsManager.getInstance(applicationContext).stopDiscovery()
            NearbyConnectionsManager.getInstance(applicationContext).stopAdvertising()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping Nearby during service destroy: ${e.message}")
        }
        super.onDestroy()
    }
}
