package org.omnilink.transport

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Android BroadcastReceiver handling system boot events.
 * Automatically restores OMNILINK's background radio listening and DTN routing service
 * upon device startup without requiring manual app launch.
 */
class OmnilinkBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "OMNILINK_BOOT"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.i(TAG, "OmnilinkBootReceiver received action: $action")

        // Do not start on LOCKED_BOOT_COMPLETED: credential-encrypted storage
        // (device name, reconnect prefs, spool DB) is unavailable before unlock.
        if (Intent.ACTION_BOOT_COMPLETED == action ||
            "android.intent.action.QUICKBOOT_POWERON" == action
        ) {
            try {
                Log.i(TAG, "Starting OmnilinkForegroundService from boot receiver...")
                val serviceIntent = Intent(context, OmnilinkForegroundService::class.java)
                ContextCompat.startForegroundService(context, serviceIntent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start OmnilinkForegroundService on boot: ${e.message}", e)
            }
        }
    }
}
