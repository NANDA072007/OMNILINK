package org.omnilink.transport

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*

/**
 * Native Android Transport Manager implementing Google Nearby Connections API.
 * Handles Bluetooth & Wi-Fi Direct physical radio advertising, discovery, socket lifecycle,
 * and raw binary payload transmission using Strategy.P2P_CLUSTER mode.
 *
 * See docs/09_android_native_transport_design.md and spec/transports.md.
 */
class NearbyConnectionsManager private constructor(private val context: Context) {

    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val SERVICE_ID = "org.omnilink.mesh.v1"
    private val localDeviceName = "OMNILINK_${Build.MODEL.replace(" ", "_")}"

    private val connectedPeers = mutableSetOf<String>()
    private var isAdvertising = false
    private var isDiscovering = false

    companion object {
        private const val TAG = "OMNILINK_NEARBY"

        @Volatile
        private var INSTANCE: NearbyConnectionsManager? = null

        fun getInstance(context: Context): NearbyConnectionsManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: NearbyConnectionsManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }

    // --------------------------------------------------------------------------
    // ADVERTISING & DISCOVERY LIFECYCLE
    // --------------------------------------------------------------------------

    fun startAdvertising(): Boolean {
        if (!checkPermissions()) {
            Log.e(TAG, "startAdvertising rejected: permissions missing")
            OmnilinkTransportPlugin.sendError(
                "MISSING_PERMISSIONS",
                "Bluetooth, Nearby Devices, or Location permissions missing."
            )
            return false
        }

        if (isAdvertising) return true

        val options = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build()
        Log.d(TAG, "startAdvertising: name=$localDeviceName serviceId=$SERVICE_ID strategy=P2P_CLUSTER")

        connectionsClient.startAdvertising(
            localDeviceName,
            SERVICE_ID,
            connectionLifecycleCallback,
            options
        ).addOnSuccessListener {
            isAdvertising = true
            Log.d(TAG, "startAdvertising: SUCCESS")
        }.addOnFailureListener { e ->
            isAdvertising = false
            Log.e(TAG, "startAdvertising: FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "ADVERTISING_FAILED",
                e.localizedMessage ?: "Failed to start advertising"
            )
        }

        return true
    }

    fun startDiscovery(serviceId: String = SERVICE_ID): Boolean {
        if (!checkPermissions()) {
            Log.e(TAG, "startDiscovery rejected: permissions missing")
            OmnilinkTransportPlugin.sendError(
                "MISSING_PERMISSIONS",
                "Bluetooth, Nearby Devices, or Location permissions missing."
            )
            return false
        }

        // Also start advertising to enable bi-directional P2P mesh discovery
        startAdvertising()

        if (isDiscovering) return true

        val options = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build()
        Log.d(TAG, "startDiscovery: serviceId=$serviceId strategy=P2P_CLUSTER")

        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            options
        ).addOnSuccessListener {
            isDiscovering = true
            Log.d(TAG, "startDiscovery: SUCCESS")
        }.addOnFailureListener { e ->
            isDiscovering = false
            Log.e(TAG, "startDiscovery: FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "DISCOVERY_FAILED",
                e.localizedMessage ?: "Failed to start discovery"
            )
        }

        return true
    }

    fun stopDiscovery(): Boolean {
        if (isDiscovering) {
            connectionsClient.stopDiscovery()
            isDiscovering = false
            Log.d(TAG, "stopDiscovery: stopped")
        }
        if (isAdvertising) {
            connectionsClient.stopAdvertising()
            isAdvertising = false
            Log.d(TAG, "stopAdvertising: stopped")
        }
        return true
    }

    // --------------------------------------------------------------------------
    // CONNECTION LIFECYCLE & PEER MANAGEMENT
    // --------------------------------------------------------------------------

    fun connectPeer(peerId: String): Boolean {
        if (!checkPermissions()) {
            Log.e(TAG, "connectPeer rejected: permissions missing")
            OmnilinkTransportPlugin.sendError("MISSING_PERMISSIONS", "Permissions missing for connect")
            return false
        }

        Log.d(TAG, "connectPeer: requesting connection to $peerId")
        connectionsClient.requestConnection(
            localDeviceName,
            peerId,
            connectionLifecycleCallback
        ).addOnFailureListener { e ->
            Log.e(TAG, "connectPeer: FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "CONNECTION_REQUEST_FAILED",
                e.localizedMessage ?: "Failed to request connection to $peerId"
            )
        }

        return true
    }

    fun disconnectPeer(peerId: String): Boolean {
        connectionsClient.disconnectFromEndpoint(peerId)
        connectedPeers.remove(peerId)
        Log.d(TAG, "disconnectPeer: $peerId")

        OmnilinkTransportPlugin.sendEvent(
            mapOf(
                "eventType" to "onDisconnected",
                "peerId" to peerId,
                "transportType" to "ANDROID_NEARBY"
            )
        )
        return true
    }

    fun isConnected(peerId: String): Boolean {
        return connectedPeers.contains(peerId)
    }

    // --------------------------------------------------------------------------
    // RAW PAYLOAD TRANSMISSION & RECEPTION
    // --------------------------------------------------------------------------

    fun sendPacket(peerId: String, payloadBytes: ByteArray): Boolean {
        if (payloadBytes.size > 4096) {
            Log.e(TAG, "OMNILINK_NEARBY: sendPacket REJECTED to $peerId - payload too large (${payloadBytes.size} bytes)")
            OmnilinkTransportPlugin.sendError(
                "INVALID_PACKET_SIZE",
                "Payload size (${payloadBytes.size} bytes) exceeds 4,096 byte MTU limit"
            )
            return false
        }

        if (!connectedPeers.contains(peerId)) {
            Log.e(TAG, "OMNILINK_NEARBY: sendPacket REJECTED to $peerId - not in connectedPeers=$connectedPeers")
            OmnilinkTransportPlugin.sendError(
                "PEER_NOT_CONNECTED",
                "Cannot send packet: Endpoint $peerId is not connected."
            )
            return false
        }

        Log.d(TAG, "OMNILINK_NEARBY: sendPayload called to $peerId with ${payloadBytes.size} bytes")
        try {
            val payload = Payload.fromBytes(payloadBytes)
            connectionsClient.sendPayload(peerId, payload)
                .addOnSuccessListener {
                    Log.d(TAG, "OMNILINK_NEARBY: sendPayload task SUCCESS to $peerId")
                }
                .addOnFailureListener { e ->
                    Log.e(TAG, "OMNILINK_NEARBY: sendPayload task FAILED to $peerId - ${e.localizedMessage}", e)
                    OmnilinkTransportPlugin.sendError(
                        "PAYLOAD_SEND_FAILED",
                        e.localizedMessage ?: "Failed to transmit payload to $peerId"
                    )
                }
        } catch (e: Exception) {
            Log.e(TAG, "OMNILINK_NEARBY: sendPayload THREW for $peerId - ${e.message}", e)
            OmnilinkTransportPlugin.sendError(
                "PAYLOAD_SEND_FAILED",
                "sendPayload threw: ${e.message}"
            )
            return false
        }

        return true
    }

    // --------------------------------------------------------------------------
    // NEARBY CONNECTIONS CALLBACKS
    // --------------------------------------------------------------------------

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            Log.d(TAG, "onEndpointFound: id=$endpointId name=${info.endpointName} serviceId=${info.serviceId}")
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "eventType" to "onPeerFound",
                    "peerId" to endpointId,
                    "friendlyName" to info.endpointName,
                    "rssi" to -50, // Nearby API abstracts RSSI
                    "transportType" to "ANDROID_NEARBY"
                )
            )
        }

        override fun onEndpointLost(endpointId: String) {
            Log.d(TAG, "onEndpointLost: id=$endpointId")
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "eventType" to "onPeerLost",
                    "peerId" to endpointId
                )
            )
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            Log.d(TAG, "onConnectionInitiated: id=$endpointId token=${info.authenticationToken} endpoint=${info.endpointName} incoming=${info.isIncomingConnection}")
            // Automatically accept incoming connections for direct P2P link.
            // Per the Nearby Connections docs, onConnectionInitiated fires on BOTH sides
            // and BOTH sides must call acceptConnection so each registers its own
            // receive-side PayloadCallback.
            connectionsClient.acceptConnection(endpointId, payloadCallback)
            Log.d(TAG, "OMNILINK_NEARBY: acceptConnection called for $endpointId")
        }

        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) {
            when (result.status.statusCode) {
                ConnectionsStatusCodes.STATUS_OK -> {
                    connectedPeers.add(endpointId)
                    Log.d(TAG, "onConnectionResult: $endpointId STATUS_OK -> connected")
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "eventType" to "onConnected",
                            "peerId" to endpointId,
                            "transportType" to "ANDROID_NEARBY"
                        )
                    )
                }
                else -> {
                    connectedPeers.remove(endpointId)
                    Log.e(TAG, "onConnectionResult: $endpointId FAILED statusCode=${result.status.statusCode}")
                    OmnilinkTransportPlugin.sendError(
                        "CONNECTION_FAILED",
                        "Connection to $endpointId failed with status code ${result.status.statusCode}"
                    )
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedPeers.remove(endpointId)
            Log.d(TAG, "onDisconnected: $endpointId")
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "eventType" to "onDisconnected",
                    "peerId" to endpointId
                )
            )
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes()
                if (bytes != null) {
                    Log.d(TAG, "OMNILINK_NEARBY: onPayloadReceived from $endpointId with ${bytes.size} bytes")
                    // Emit raw payload bytes directly to Dart EventSink.
                    // Event map format MUST be: type / incomingPacket / peerId / bytes.
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "incomingPacket",
                            "peerId" to endpointId,
                            "bytes" to bytes
                        )
                    )
                } else {
                    Log.e(TAG, "OMNILINK_NEARBY: onPayloadReceived from $endpointId but payload.asBytes() returned null")
                }
            } else {
                Log.d(TAG, "OMNILINK_NEARBY: onPayloadReceived from $endpointId with non-BYTES type=${payload.type}")
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            Log.d(TAG, "OMNILINK_NEARBY: onPayloadTransferUpdate for $endpointId status=${update.status} bytes=${update.bytesTransferred}/${update.totalBytes}")
            when (update.status) {
                PayloadTransferUpdate.Status.SUCCESS -> {
                    Log.d(TAG, "OMNILINK_NEARBY: payload transfer SUCCESS for $endpointId")
                }
                PayloadTransferUpdate.Status.IN_PROGRESS -> {
                    // Intermediate progress; no action needed for small BYTES payloads.
                }
                PayloadTransferUpdate.Status.FAILURE -> {
                    Log.e(TAG, "OMNILINK_NEARBY: payload transfer FAILURE for $endpointId bytes=${update.bytesTransferred}/${update.totalBytes}")
                }
                else -> {
                    Log.e(TAG, "OMNILINK_NEARBY: payload transfer UNKNOWN status=${update.status} for $endpointId")
                }
            }
        }
    }

    // --------------------------------------------------------------------------
    // PERMISSIONS VERIFICATION HELPER
    // --------------------------------------------------------------------------

    private fun checkPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scan = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN)
            val connect = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT)
            val advertise = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_ADVERTISE)
            if (scan != PackageManager.PERMISSION_GRANTED ||
                connect != PackageManager.PERMISSION_GRANTED ||
                advertise != PackageManager.PERMISSION_GRANTED) {
                Log.e(TAG, "checkPermissions: S+ missing scan=$scan connect=$connect advertise=$advertise")
                return false
            }
        }

        val location = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
        if (location != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "checkPermissions: missing fine location (granted=$location)")
            return false
        }
        Log.d(TAG, "checkPermissions: ALL GRANTED")
        return true
    }
}
