package org.omnilink.transport

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android Native Platform Channel Plugin for OMNILINK.
 * Bridges Layer 2 (Dart Core Engine) to Layer 3 (Kotlin Native Radio Transport).
 *
 * MethodChannel: "omnilink/transport/control"
 * EventChannel:  "omnilink/transport/events"
 * See docs/08_platform_channel_design.md and spec/platform_channels.md.
 */
class OmnilinkTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null

    companion object {
        private const val TAG = "OMNILINK_KOTLIN"
        private const val METHOD_CHANNEL_NAME = "omnilink/transport/control"
        private const val EVENT_CHANNEL_NAME = "omnilink/transport/events"

        private var eventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * Safely sends an event map back to Dart on the Main UI Thread.
         */
        fun sendEvent(eventMap: Map<String, Any?>) {
            mainHandler.post {
                eventSink?.success(eventMap)
            }
        }

        /**
         * Safely sends an error event back to Dart on the Main UI Thread.
         */
        fun sendError(errorCode: String, errorMessage: String, details: Any? = null) {
            mainHandler.post {
                eventSink?.error(errorCode, errorMessage, details)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME)
        eventChannel.setStreamHandler(this)

        NearbyConnectionsManager.getInstance(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
            "connectPeer" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId is required", null)
                    return
                }
                val success = manager.connectPeer(peerId)
                result.success(success)
            }
            "disconnectPeer" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId is required", null)
                    return
                }
                val success = manager.disconnectPeer(peerId)
                result.success(success)
            }
            "sendPacket" -> {
                val peerId = call.argument<String>("peerId")
                val payload = extractByteArray(call.argument<Any>("payload"))
                if (peerId == null || payload == null) {
                    Log.e(TAG, "sendPacket: INVALID_ARGUMENT peerId=$peerId payloadType=${call.argument<Any>("payload")?.javaClass?.simpleName}")
                    result.error("INVALID_ARGUMENT", "peerId and payload (ByteArray) are required", null)
                    return
                }
                Log.d(TAG, "sendPacket: peerId=$peerId bytes=${payload.size}")
                val success = manager.sendPacket(peerId, payload)
                result.success(success)
            }
            "isConnected" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId == null) {
                    result.error("INVALID_ARGUMENT", "peerId is required", null)
                    return
                }
                val isConnected = manager.isConnected(peerId)
                result.success(isConnected)
            }
            "getAndroidPermissionDetails" -> {
                result.success(getAndroidPermissionDetails())
            }
            "getTransportCapability" -> {
                val capability = manager.getTransportCapabilityMap()
                result.success(capability)
            }
            "startForegroundService" -> {
                val ctx = context
                if (ctx != null) {
                    val intent = android.content.Intent(ctx, OmnilinkForegroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.startForegroundService(intent)
                    } else {
                        ctx.startService(intent)
                    }
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            "stopForegroundService" -> {
                val ctx = context
                if (ctx != null) {
                    val intent = android.content.Intent(ctx, OmnilinkForegroundService::class.java)
                    ctx.stopService(intent)
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * Defensively extracts a ByteArray from a Flutter MethodCall argument.
     * Flutter's StandardMessageCodec decodes a Dart Uint8List into a Kotlin
     * ByteArray, but older/edge decoders may surface it as an IntArray or a
     * generic List<Int>. Accept all three shapes so sendPacket always receives
     * valid bytes.
     */
    private fun extractByteArray(argument: Any?): ByteArray? {
        return when (argument) {
            is ByteArray -> argument
            is IntArray -> argument.map { it.toByte() }.toByteArray()
            is List<*> -> {
                val out = ByteArray(argument.size)
                for (i in argument.indices) {
                    val v = argument[i] as? Number ?: return null
                    out[i] = v.toByte()
                }
                out
            }
            else -> null
        }
    }

    /**
     * Temporary diagnostic probe. Exposes permission, Google Play Services, and
     * radio (Bluetooth / Wi-Fi / Location) state to Dart for root-cause analysis.
     * Tag: OMNILINK_NATIVE_PERM
     */
    private fun getAndroidPermissionDetails(): Map<String, Any?> {
        val ctx = context
            ?: return mapOf("error" to "Plugin context not available")

        fun granted(permission: String): Boolean =
            ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

        val details = mutableMapOf<String, Any?>()

        // Android build info
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

        // Runtime permission states
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

        // Google Play Services availability
        val gms = GoogleApiAvailability.getInstance()
        val gmsStatus = gms.isGooglePlayServicesAvailable(ctx)
        details["playServicesAvailable"] = gmsStatus == ConnectionResult.SUCCESS
        details["playServicesStatusCode"] = gmsStatus
        details["playServicesUserResolvable"] = gms.isUserResolvableError(gmsStatus)

        // Radio / hardware state (best-effort, guarded)
        val isBluetoothEnabled = try {
            val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.isEnabled
        } catch (_: SecurityException) { null }
        details["bluetoothEnabled"] = isBluetoothEnabled

        val isWifiEnabled = try {
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wm?.isWifiEnabled
        } catch (_: SecurityException) { null }
        details["wifiEnabled"] = isWifiEnabled

        val isLocationEnabled = try {
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true
        } catch (_: SecurityException) { false }
        details["locationEnabled"] = isLocationEnabled

        Log.i("OMNILINK_NATIVE_PERM", "getAndroidPermissionDetails: $details")
        return details
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        Log.d(TAG, "onListen: EventChannel active")
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        Log.d(TAG, "onCancel: EventChannel inactive")
        eventSink = null
    }
}
