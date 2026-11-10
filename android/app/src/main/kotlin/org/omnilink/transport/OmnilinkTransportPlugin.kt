package org.omnilink.transport

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import org.omnilink.MainActivity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Android Native Platform Channel Plugin for OMNILINK.
 * Bridges Layer 2 (Dart Core Engine) to Layer 3 (Kotlin Native Radio Transport).
 * Features replay-safe EventChannel event buffering, sequence numbering, and transport snapshots.
 *
 * MethodChannel: "omnilink/transport/control"
 * EventChannel:  "omnilink/transport/events"
 * See docs/08_platform_channel_design.md and spec/platform_channels.md.
 */
class OmnilinkTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var inboundSpool: OmnilinkInboundSpool? = null

    private val spoolHandler = Handler(Looper.getMainLooper())
    private val spoolWatchdog = object : Runnable {
        override fun run() {
            if (spoolReplayNeeded && eventSink != null) {
                spoolReplayNeeded = false
                replaySpooledPayloads()
            }
            spoolHandler.postDelayed(this, 15_000L)
        }
    }

    companion object {
        private const val TAG = "OMNILINK_KOTLIN"
        private const val METHOD_CHANNEL_NAME = "omnilink/transport/control"
        private const val EVENT_CHANNEL_NAME = "omnilink/transport/events"
        private const val MESSAGE_CHANNEL_ID = "omnilink_messages"
        private const val MAX_BUFFER_SIZE = 512
        private const val SPOOL_REPLAY_MIN_AGE_MS = 1_500L

        private var eventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        private val sequenceCounter = AtomicLong(0L)
        private val pendingEventBuffer = ConcurrentLinkedQueue<Map<String, Any?>>()
        private val droppedEventCount = AtomicInteger(0)

        @Volatile
        private var spoolReplayNeeded = false

        /**
         * Wraps native event map with sequence number, timestamp, and unique eventId,
         * delivering directly to Dart or buffering if the EventSink is detached.
         */
        fun sendEvent(rawEventMap: Map<String, Any?>) {
            val seq = sequenceCounter.incrementAndGet()
            val timestamp = System.currentTimeMillis()
            val eventId = "evt_${timestamp}_$seq"

            val fullEvent = HashMap<String, Any?>(rawEventMap).apply {
                put("eventId", eventId)
                put("sequenceNumber", seq)
                put("timestamp", timestamp)
            }

            mainHandler.post {
                val sink = eventSink
                if (sink != null) {
                    try {
                        sink.success(fullEvent)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error delivering event to sink: ${e.message}")
                        bufferIfNeeded(fullEvent)
                    }
                } else {
                    bufferIfNeeded(fullEvent)
                }
            }
        }

        /**
         * Safely sends an error event back to Dart on the Main UI Thread.
         */
        fun sendError(errorCode: String, errorMessage: String, details: Any? = null) {
            val seq = sequenceCounter.incrementAndGet()
            val timestamp = System.currentTimeMillis()
            val eventId = "evt_err_${timestamp}_$seq"

            val errorEvent = mapOf(
                "eventId" to eventId,
                "sequenceNumber" to seq,
                "timestamp" to timestamp,
                "type" to "ERROR",
                "errorCode" to errorCode,
                "errorMessage" to errorMessage,
                "details" to details
            )

            mainHandler.post {
                val sink = eventSink
                if (sink != null) {
                    try {
                        sink.error(errorCode, errorMessage, details)
                    } catch (e: Exception) {
                        enqueueEvent(errorEvent)
                    }
                } else {
                    enqueueEvent(errorEvent)
                }
            }
        }

        /**
         * Payload events already have a durable spool row, so they must not
         * consume the 512-slot RAM buffer. Non-payload events still use it.
         */
        private fun bufferIfNeeded(event: Map<String, Any?>) {
            val isSpooledPayload =
                event["type"] == "incomingPacket" && event.containsKey("spoolId")
            if (isSpooledPayload) {
                spoolReplayNeeded = true
            } else {
                enqueueEvent(event)
            }
        }

        private fun enqueueEvent(event: Map<String, Any?>) {
            synchronized(pendingEventBuffer) {
                if (pendingEventBuffer.size >= MAX_BUFFER_SIZE) {
                    pendingEventBuffer.poll() // Drop oldest event
                    droppedEventCount.incrementAndGet()
                }
                pendingEventBuffer.add(event)
            }
            // Payloads also live in the durable spool; ask the watchdog to
            // replay unacknowledged rows once a sink is available again.
            spoolReplayNeeded = true
        }
    }

    private val radioStateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            Log.d(TAG, "Native radio state changed: ${intent?.action}")
            emitRadioStateEvent()
        }
    }

    fun emitRadioStateEvent() {
        val details = getAndroidPermissionDetails()
        val eventMap = mapOf(
            "type" to "RADIO_STATE_CHANGED",
            "details" to details
        )
        sendEvent(eventMap)

        // A Bluetooth/Wi-Fi toggle is a fresh opportunity to re-arm discovery
        // and reconnect desired peers.
        context?.let { ctx ->
            try {
                NearbyConnectionsManager.getInstance(ctx).onRadioAvailable()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to re-arm mesh after radio state change: ${e.message}", e)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        inboundSpool = OmnilinkInboundSpool.getInstance(binding.applicationContext)
        ensureMessageChannel(binding.applicationContext)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME)
        eventChannel.setStreamHandler(this)

        spoolHandler.removeCallbacks(spoolWatchdog)
        spoolHandler.postDelayed(spoolWatchdog, 15_000L)

        NearbyConnectionsManager.getInstance(binding.applicationContext)
        BluetoothRfcommTransport.getInstance(binding.applicationContext).registerBluetoothStateReceiver()

        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
            addAction("android.location.MODE_CHANGED")
        }
        try {
            binding.applicationContext.registerReceiver(radioStateReceiver, filter)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register radioStateReceiver: ${e.message}")
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        spoolHandler.removeCallbacks(spoolWatchdog)
        context?.let { ctx ->
            BluetoothRfcommTransport.getInstance(ctx).teardown()
            try {
                ctx.unregisterReceiver(radioStateReceiver)
            } catch (_: Exception) {}
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")
        val manager = context?.let { NearbyConnectionsManager.getInstance(it) }
        if (manager == null) {
            Log.e(TAG, "onMethodCall: context not initialized")
            result.error("NOT_INITIALIZED", "Plugin context not initialized", null)
            return
        }

        when (call.method) {
            "initialize" -> {
                result.success(true)
            }
            "startDiscovery" -> {
                val serviceId = call.argument<String>("serviceId") ?: "org.omnilink.mesh.v1"
                val success = manager.startDiscovery(serviceId)
                result.success(success)
            }
            "stopDiscovery" -> {
                val success = manager.stopDiscovery()
                result.success(success)
            }
            "startAdvertising" -> {
                val serviceId = call.argument<String>("serviceId") ?: "org.omnilink.mesh.v1"
                val success = manager.startAdvertising(serviceId)
                result.success(success)
            }
            "stopAdvertising" -> {
                val success = manager.stopAdvertising()
                result.success(success)
            }
            "connectPeer" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId required", null)
                    return
                }
                val success = manager.connectPeer(peerId)
                result.success(success)
            }
            "disconnectPeer" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId required", null)
                    return
                }
                val success = manager.disconnectPeer(peerId)
                result.success(success)
            }
            "sendPacket" -> {
                val peerId = call.argument<String>("peerId")
                val payload = call.argument<ByteArray>("payload")
                if (peerId == null || payload == null) {
                    result.error("INVALID_ARGUMENT", "peerId and payload required", null)
                    return
                }
                val success = manager.sendPacket(peerId, payload)
                result.success(success)
            }
            "registerNodeMapping" -> {
                val nodeId = call.argument<String>("nodeId")
                val endpointId = call.argument<String>("endpointId")
                if (nodeId == null || endpointId == null) {
                    result.error("INVALID_ARGUMENT", "nodeId and endpointId required", null)
                    return
                }
                result.success(manager.registerNodeMapping(nodeId, endpointId))
            }
            "resolveEndpoint" -> {
                val targetId = call.argument<String>("targetId")
                if (targetId == null) {
                    result.error("INVALID_ARGUMENT", "targetId required", null)
                    return
                }
                result.success(manager.resolveEndpoint(targetId))
            }
            "startForegroundService" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val serviceIntent = android.content.Intent(ctx, OmnilinkForegroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(serviceIntent)
                } else {
                    ctx.startService(serviceIntent)
                }
                result.success(true)
            }
            "stopForegroundService" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val serviceIntent = android.content.Intent(ctx, OmnilinkForegroundService::class.java)
                ctx.stopService(serviceIntent)
                result.success(true)
            }
            "getTransportCapability" -> {
                val cap = getAndroidPermissionDetails()
                result.success(cap)
            }
            "getAndroidPermissionDetails" -> {
                val cap = getAndroidPermissionDetails()
                result.success(cap)
            }
            "getDetailedPermissionStatus" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val statusMap = NearbyConnectionsManager.getInstance(ctx).getDetailedPermissionStatus()
                result.success(statusMap)
            }
            "getBluetoothUsageState" -> {
                val stateMap = getBluetoothUsageStateMap()
                result.success(stateMap)
            }
            "getBatteryState" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager

                val level = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 80
                } else 80

                val isCharging = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    bm?.isCharging == true
                } else {
                    val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                    val batteryStatus = ctx.registerReceiver(null, filter)
                    val status = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                    status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                }

                val isLowPowerMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    powerManager?.isPowerSaveMode == true
                } else false

                result.success(mapOf(
                    "level" to level,
                    "isCharging" to isCharging,
                    "isLowPowerMode" to isLowPowerMode
                ))
            }
            "getBondedBluetoothDevices" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val devices = BluetoothRfcommTransport.getInstance(ctx).getBondedDevices()
                result.success(devices)
            }
            "startRfcommServer" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val success = BluetoothRfcommTransport.getInstance(ctx).startServer()
                result.success(success)
            }
            "stopRfcommServer" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                BluetoothRfcommTransport.getInstance(ctx).stopServer()
                result.success(true)
            }
            "connectRfcommDevice" -> {
                val ctx = context
                val deviceAddress = call.argument<String>("deviceAddress")
                if (ctx == null || deviceAddress == null) {
                    result.error("INVALID_ARGUMENT", "deviceAddress required", null)
                    return
                }
                val success = BluetoothRfcommTransport.getInstance(ctx).connectDevice(deviceAddress)
                result.success(success)
            }
            "disconnectRfcommDevice" -> {
                val ctx = context
                val deviceAddress = call.argument<String>("deviceAddress")
                if (ctx == null || deviceAddress == null) {
                    result.error("INVALID_ARGUMENT", "deviceAddress required", null)
                    return
                }
                val success = BluetoothRfcommTransport.getInstance(ctx).disconnectDevice(deviceAddress)
                result.success(success)
            }
            "sendRfcommPacket" -> {
                val ctx = context
                val deviceAddress = call.argument<String>("deviceAddress")
                val payload = call.argument<ByteArray>("payload")
                if (ctx == null || deviceAddress == null || payload == null) {
                    result.error("INVALID_ARGUMENT", "deviceAddress and payload required", null)
                    return
                }
                val success = BluetoothRfcommTransport.getInstance(ctx).sendPacket(deviceAddress, payload)
                result.success(success)
            }
            "requestTransportSnapshot" -> {
                result.success(getTransportSnapshot())
            }
            "resumeFromSequence" -> {
                val lastSeq = (call.argument<Number>("lastSequence") ?: 0L).toLong()
                var replayedCount = 0
                val sink = eventSink
                if (sink != null) {
                    synchronized(pendingEventBuffer) {
                        val iterator = pendingEventBuffer.iterator()
                        while (iterator.hasNext()) {
                            val evt = iterator.next()
                            val seq = (evt["sequenceNumber"] as? Number)?.toLong() ?: 0L
                            if (seq > lastSeq) {
                                sink.success(evt)
                                replayedCount++
                            }
                        }
                    }
                }
                replayedCount += replaySpooledPayloads(respectAge = false)
                result.success(replayedCount)
            }
            "requestEnableBluetooth" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                try {
                    // On modern Android (API 33+), BluetoothAdapter.enable()/disable() is
                    // deprecated and blocked for non-system apps. Route the user to system
                    // settings instead of calling the blocked APIs directly.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        ctx.startActivity(intent)
                        result.success(true)
                        return
                    }
                    val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                    val adapter = bm?.adapter
                    if (adapter != null) {
                        if (!adapter.isEnabled) {
                            try {
                                @Suppress("DEPRECATION")
                                val ok = adapter.enable()
                                if (!ok) {
                                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    ctx.startActivity(intent)
                                }
                            } catch (_: Exception) {
                                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                ctx.startActivity(intent)
                            }
                        } else {
                            try {
                                @Suppress("DEPRECATION")
                                adapter.disable()
                            } catch (_: Exception) {
                                val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                ctx.startActivity(intent)
                            }
                        }
                    }
                    result.success(true)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to toggle bluetooth: $e")
                    result.success(false)
                }
            }
            "requestToggleWifi" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                // WifiManager.setWifiEnabled is blocked for non-system apps on API 29+.
                // Always route to the system Wi-Fi panel on Q+ instead of calling it.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val intent = Intent(Settings.Panel.ACTION_WIFI).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(intent)
                    result.success(true)
                    return
                }
                try {
                    val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    if (wm != null) {
                        @Suppress("DEPRECATION")
                        wm.setWifiEnabled(!(wm.isWifiEnabled))
                    }
                    result.success(true)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to toggle wifi: $e")
                    result.success(false)
                }
            }
            "requestToggleLocation" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                try {
                    val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("LOCATION_TOGGLE_FAILED", e.message, null)
                }
            }
            "acknowledgeInboundPacket" -> {
                val spoolId = call.argument<Number>("spoolId")?.toLong()
                if (spoolId == null) {
                    result.error("INVALID_ARGUMENT", "spoolId required", null)
                    return
                }
                inboundSpool?.acknowledge(spoolId)
                result.success(true)
            }
            "getInboundSpoolCount" -> {
                result.success(inboundSpool?.count() ?: 0)
            }
            "isIgnoringBatteryOptimizations" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                result.success(pm?.isIgnoringBatteryOptimizations(ctx.packageName) == true)
            }
            "requestIgnoreBatteryOptimizations" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm?.isIgnoringBatteryOptimizations(ctx.packageName) == true) {
                    result.success(true)
                    return
                }
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:${ctx.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    try {
                        val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        ctx.startActivity(fallback)
                        result.success(true)
                    } catch (e2: Exception) {
                        Log.e(TAG, "Failed to open battery optimization settings: ${e2.message}", e2)
                        result.error("BATTERY_EXEMPTION_FAILED", e2.message, null)
                    }
                }
            }
            "showMessageNotification" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("NO_CONTEXT", "Plugin context is null", null)
                    return
                }
                val title = call.argument<String>("title") ?: "OMNILINK"
                val body = call.argument<String>("body") ?: "New message"
                val conversationId = call.argument<String>("conversationId") ?: "omnilink"
                result.success(showMessageNotification(ctx, title, body, conversationId))
            }
            "ensureMeshActive" -> {
                result.success(manager.ensureMeshActive())
            }
            "setAutoReconnect" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                manager.setAutoReconnect(enabled)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureMessageChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(MESSAGE_CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "OMNILINK Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Incoming offline mesh messages"
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun showMessageNotification(
        ctx: Context,
        title: String,
        body: String,
        conversationId: String,
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                ctx,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.d(TAG, "Message notification suppressed: POST_NOTIFICATIONS not granted")
            return false
        }

        ensureMessageChannel(ctx)
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return false
        val launchIntent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("conversationId", conversationId)
        }
        val notificationId = conversationId.hashCode()
        val pendingIntent = PendingIntent.getActivity(
            ctx,
            notificationId,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val safeBody = if (body.length > 160) body.substring(0, 157) + "..." else body
        val notification = Notification.Builder(ctx, MESSAGE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(safeBody)
            .setStyle(Notification.BigTextStyle().bigText(safeBody))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        nm.notify(notificationId, notification)
        return true
    }

    /** Re-emits unacknowledged spool rows. Safe to call repeatedly: Dart's
     *  replay cache makes duplicate deliveries idempotent. */
    private fun replaySpooledPayloads(respectAge: Boolean = true): Int {
        val spool = inboundSpool ?: return 0
        if (eventSink == null) {
            spoolReplayNeeded = true
            return 0
        }
        val cutoff = System.currentTimeMillis() - SPOOL_REPLAY_MIN_AGE_MS
        var replayed = 0
        for (row in spool.pending()) {
            if (respectAge && row.receivedAt > cutoff) continue
            sendEvent(
                mapOf(
                    "type" to "incomingPacket",
                    "peerId" to row.endpointId,
                    "bytes" to row.bytes,
                    "spoolId" to row.id,
                    "replayedFromSpool" to true,
                ),
            )
            replayed++
        }
        if (replayed > 0) {
            Log.d(TAG, "Replayed $replayed spooled inbound payload(s)")
        }
        return replayed
    }

    private fun getTransportSnapshot(): Map<String, Any?> {
        val ctx = context
        val manager = ctx?.let { NearbyConnectionsManager.getInstance(it) }
        val connected = manager?.getConnectedEndpoints() ?: emptyList()
        val isBtEnabled = try {
            val bm = ctx?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.isEnabled == true
        } catch (_: Exception) { false }

        val seq = sequenceCounter.incrementAndGet()
        return mapOf(
            "eventId" to "evt_snap_${System.currentTimeMillis()}_$seq",
            "sequenceNumber" to seq,
            "timestamp" to System.currentTimeMillis(),
            "type" to "SNAPSHOT",
            "connectedPeers" to connected,
            "bluetoothEnabled" to isBtEnabled,
            "lastSequenceNumber" to sequenceCounter.get()
        )
    }

    private fun getAndroidPermissionDetails(): Map<String, Any?> {
        val ctx = context
            ?: return mapOf("error" to "Plugin context not available")

        fun granted(permission: String): Boolean =
            ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

        val details = mutableMapOf<String, Any?>()

        details["sdkInt"] = Build.VERSION.SDK_INT
        try {
            val pkg = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            details["versionName"] = pkg.versionName
            details["versionCode"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                pkg.longVersionCode else pkg.versionCode.toLong()
        } catch (e: Exception) {
            details["versionName"] = "unknown"
            details["versionCode"] = 0L
        }

        details["bluetoothScanGranted"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            granted(Manifest.permission.BLUETOOTH_SCAN) else true
        details["bluetoothConnectGranted"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            granted(Manifest.permission.BLUETOOTH_CONNECT) else true
        details["bluetoothAdvertiseGranted"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            granted(Manifest.permission.BLUETOOTH_ADVERTISE) else true
        details["fineLocationGranted"] = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        details["coarseLocationGranted"] = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        details["nearbyWifiDevicesGranted"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            granted(Manifest.permission.NEARBY_WIFI_DEVICES) else true

        val gms = GoogleApiAvailability.getInstance()
        val gmsStatus = gms.isGooglePlayServicesAvailable(ctx)
        details["playServicesAvailable"] = gmsStatus == ConnectionResult.SUCCESS
        details["playServicesStatusCode"] = gmsStatus
        details["playServicesUserResolvable"] = gms.isUserResolvableError(gmsStatus)

        val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val btAdapter = bm?.adapter ?: BluetoothAdapter.getDefaultAdapter()
        val bluetoothSupported = btAdapter != null
        val bluetoothEnabled = try {
            btAdapter?.isEnabled == true
        } catch (_: Exception) {
            false
        }

        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val wifiSupported = wm != null
        val wifiEnabled = try {
            wm?.isWifiEnabled == true
        } catch (_: Exception) {
            false
        }

        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val locationSupported = lm != null
        val locationServiceEnabled = try {
            lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
            lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
        } catch (_: Exception) {
            false
        }

        details["bluetoothSupported"] = bluetoothSupported
        details["bluetoothEnabled"] = bluetoothEnabled
        details["wifiSupported"] = wifiSupported
        details["wifiEnabled"] = wifiEnabled
        details["locationSupported"] = locationSupported
        details["locationServiceEnabled"] = locationServiceEnabled
        details["locationEnabled"] = locationServiceEnabled

        Log.i("OMNILINK_RADIO_NATIVE", "[OMNILINK][RADIO][NATIVE] sdkInt=${Build.VERSION.SDK_INT} btSupp=$bluetoothSupported btEn=$bluetoothEnabled wifiSupp=$wifiSupported wifiEn=$wifiEnabled locSupp=$locationSupported locEn=$locationServiceEnabled")
        return details
    }

    private fun getBluetoothUsageStateMap(): Map<String, Any?> {
        val ctx = context ?: return mapOf("error" to "Context not available")
        val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bm?.adapter ?: BluetoothAdapter.getDefaultAdapter()

        val isBtEnabled = adapter?.isEnabled == true
        val sdkInt = Build.VERSION.SDK_INT

        var a2dpConnected = false
        var headsetConnected = false

        if (isBtEnabled && adapter != null) {
            try {
                val a2dpState = adapter.getProfileConnectionState(BluetoothProfile.A2DP)
                a2dpConnected = (a2dpState == BluetoothProfile.STATE_CONNECTED)

                val headsetState = adapter.getProfileConnectionState(BluetoothProfile.HEADSET)
                headsetConnected = (headsetState == BluetoothProfile.STATE_CONNECTED)
            } catch (e: SecurityException) {
                Log.e(TAG, "SecurityException checking Bluetooth profile connection state: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "Exception checking Bluetooth profile connection state: ${e.message}")
            }
        }

        val audioConnected = a2dpConnected || headsetConnected
        val bleSupported = ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val locationReq = sdkInt <= 31

        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val isWifiEnabled = wm?.isWifiEnabled == true

        val modeStr = if (!isBtEnabled) "offlineQueue" else if (isWifiEnabled) "highSpeed" else if (audioConnected) "degradedTextOnly" else "highSpeed"

        return mapOf(
            "bluetoothEnabled" to isBtEnabled,
            "wifiEnabled" to isWifiEnabled,
            "audioDeviceConnected" to audioConnected,
            "headsetConnected" to headsetConnected,
            "a2dpConnected" to a2dpConnected,
            "bleScanSupported" to bleSupported,
            "locationRequiredForScan" to locationReq,
            "androidSdkInt" to sdkInt
        )
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.d(TAG, "onListen: EventChannel active")
        eventSink = events

        mainHandler.post {
            val sink = eventSink ?: return@post

            // 1. Replay buffered events FIRST. They carry older sequence numbers;
            //    sending a snapshot (with a new sequence) first would make Dart
            //    discard them as duplicates.
            synchronized(pendingEventBuffer) {
                while (pendingEventBuffer.isNotEmpty()) {
                    val evt = pendingEventBuffer.poll()
                    if (evt != null) {
                        try {
                            sink.success(evt)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error replaying buffered event: ${e.message}")
                        }
                    }
                }
            }

            // 2. Emit BUFFER_OVERFLOW marker event if events were dropped
            val dropped = droppedEventCount.getAndSet(0)
            if (dropped > 0) {
                val seq = sequenceCounter.incrementAndGet()
                val overflowEvent = mapOf(
                    "eventId" to "evt_overflow_${System.currentTimeMillis()}_$seq",
                    "sequenceNumber" to seq,
                    "timestamp" to System.currentTimeMillis(),
                    "type" to "BUFFER_OVERFLOW",
                    "droppedCount" to dropped
                )
                try {
                    sink.success(overflowEvent)
                } catch (e: Exception) {
                    Log.e(TAG, "Error sending overflow marker: ${e.message}")
                }
            }

            // 3. Emit SNAPSHOT after buffered events so current state wins.
            try {
                val snapshot = getTransportSnapshot()
                sink.success(snapshot)
            } catch (e: Exception) {
                Log.e(TAG, "Error sending transport snapshot: ${e.message}")
            }

            // 4. Replay durable spool rows that were never acknowledged.
            replaySpooledPayloads(respectAge = false)
        }
    }

    override fun onCancel(arguments: Any?) {
        Log.d(TAG, "onCancel: EventChannel inactive")
        eventSink = null
    }
}
