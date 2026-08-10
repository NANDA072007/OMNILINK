package org.omnilink.transport

import android.content.Context
import android.os.Handler
import android.os.Looper
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
        val manager = context?.let { NearbyConnectionsManager.getInstance(it) }
        if (manager == null) {
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
                val payload = call.argument<ByteArray>("payload")
                if (peerId == null || payload == null) {
                    result.error("INVALID_ARGUMENT", "peerId and payload (ByteArray) are required", null)
                    return
                }
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
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}
