package org.omnilink.transport

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
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
            OmnilinkTransportPlugin.sendError(
                "MISSING_PERMISSIONS",
                "Bluetooth, Nearby Devices, or Location permissions missing."
            )
            return false
        }

        if (isAdvertising) return true

        val options = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build()

        connectionsClient.startAdvertising(
            localDeviceName,
            SERVICE_ID,
            connectionLifecycleCallback,
            options
        ).addOnSuccessListener {
            isAdvertising = true
        }.addOnFailureListener { e ->
            isAdvertising = false
            OmnilinkTransportPlugin.sendError(
                "ADVERTISING_FAILED",
                e.localizedMessage ?: "Failed to start advertising"
            )
        }

        return true
    }

    fun startDiscovery(serviceId: String = SERVICE_ID): Boolean {
        if (!checkPermissions()) {
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

        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            options
        ).addOnSuccessListener {
            isDiscovering = true
        }.addOnFailureListener { e ->
            isDiscovering = false
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
        }
        if (isAdvertising) {
            connectionsClient.stopAdvertising()
            isAdvertising = false
        }
        return true
    }

    // --------------------------------------------------------------------------
    // CONNECTION LIFECYCLE & PEER MANAGEMENT
    // --------------------------------------------------------------------------

    fun connectPeer(peerId: String): Boolean {
        if (!checkPermissions()) {
            OmnilinkTransportPlugin.sendError("MISSING_PERMISSIONS", "Permissions missing for connect")
            return false
        }

        connectionsClient.requestConnection(
            localDeviceName,
            peerId,
            connectionLifecycleCallback
        ).addOnFailureListener { e ->
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
            OmnilinkTransportPlugin.sendError(
                "INVALID_PACKET_SIZE",
                "Payload size (${payloadBytes.size} bytes) exceeds 4,096 byte MTU limit"
            )
            return false
        }

        if (!connectedPeers.contains(peerId)) {
            OmnilinkTransportPlugin.sendError(
                "PEER_NOT_CONNECTED",
                "Cannot send packet: Endpoint $peerId is not connected."
            )
            return false
        }

        val payload = Payload.fromBytes(payloadBytes)
        connectionsClient.sendPayload(peerId, payload).addOnFailureListener { e ->
            OmnilinkTransportPlugin.sendError(
                "PAYLOAD_SEND_FAILED",
                e.localizedMessage ?: "Failed to transmit payload to $peerId"
            )
        }

        return true
    }

    // --------------------------------------------------------------------------
    // NEARBY CONNECTIONS CALLBACKS
    // --------------------------------------------------------------------------

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
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
            // Automatically accept incoming connections for direct P2P link
            connectionsClient.acceptConnection(endpointId, payloadCallback)
        }

        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) {
            when (result.status.statusCode) {
                ConnectionsStatusCodes.STATUS_OK -> {
                    connectedPeers.add(endpointId)
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
                    OmnilinkTransportPlugin.sendError(
                        "CONNECTION_FAILED",
                        "Connection to $endpointId failed with status code ${result.status.statusCode}"
                    )
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedPeers.remove(endpointId)
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
                    // Emit raw payload bytes directly to Dart EventSink without base64/json string parsing
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "eventType" to "onPacketReceived",
                            "senderPeerId" to endpointId,
                            "payloadBytes" to bytes
                        )
                    )
                }
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            // Unused for short MTU payloads (<= 4 KB)
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
                return false
            }
        }

        val location = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
        return location == PackageManager.PERMISSION_GRANTED
    }
}
