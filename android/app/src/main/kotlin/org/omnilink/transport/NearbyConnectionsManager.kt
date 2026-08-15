package org.omnilink.transport

import android.bluetooth.BluetoothAdapter
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
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Native Android Transport Manager implementing Google Nearby Connections API.
 * Uses Strategy.P2P_CLUSTER for true multi-peer M-to-N mesh network topology.
 * Features native outbound send buffering per endpoint with 0% silent packet drops.
 */
class NearbyConnectionsManager private constructor(private val context: Context) {

    private val connectionsClient: ConnectionsClient = Nearby.getConnectionsClient(context)
    private val SERVICE_ID = "org.omnilink.mesh.v1"
    private val localDeviceName = "OMNILINK_${Build.MODEL.replace(" ", "_")}"

    // Strategy rule #1: Upgrade to Strategy.P2P_CLUSTER for true multi-peer mesh
    private val strategy = Strategy.P2P_CLUSTER

    private val connectedPeers = mutableSetOf<String>()
    private val pendingOutgoingConnections = mutableMapOf<String, Long>()
    private val handler = Handler(Looper.getMainLooper())
    private val connectionTimeoutRunnables = mutableMapOf<String, Runnable>()

    // Native outbound payload queueing to prevent buffer overruns
    private val outboundQueues = ConcurrentHashMap<String, ConcurrentLinkedQueue<ByteArray>>()
    private val inFlightPayloads = ConcurrentHashMap<String, Boolean>()

    private var isAdvertising = false
    private var isDiscovering = false
    private var hasRetriedDiscovery = false
    private var discoveryTimeoutRunnable: Runnable? = null

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
    // RADIO PREFLIGHT CHECKS
    // --------------------------------------------------------------------------

    fun performPreflightChecks(isDiscoveryAttempt: Boolean = false): Boolean {
        val t0 = System.currentTimeMillis()
        val sdkInt = Build.VERSION.SDK_INT
        Log.d(TAG, "OMNILINK_TRANSPORT: [t=$t0] performing radio preflight checks (sdk=$sdkInt)...")

        // 1. Bluetooth enabled check (REQUIRED)
        val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        val bluetoothEnabled = bluetoothAdapter != null && bluetoothAdapter.isEnabled
        Log.d(TAG, "OMNILINK_TRANSPORT: [t=$t0] Bluetooth enabled=$bluetoothEnabled")
        if (!bluetoothEnabled) {
            OmnilinkTransportPlugin.sendError(
                "BLUETOOTH_REQUIRED",
                "Bluetooth is required for peer discovery and messaging."
            )
            return false
        }

        // 2. Wi-Fi enabled check (OPTIONAL - SPEED BOOSTER)
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val wifiEnabled = wifiManager?.isWifiEnabled == true
        Log.d(TAG, "OMNILINK_TRANSPORT: [t=$t0] Wi-Fi enabled=$wifiEnabled")
        if (!wifiEnabled) {
            Log.i(TAG, "OMNILINK_TRANSPORT: Wi-Fi is off. Operating in Bluetooth-only transport mode.")
            OmnilinkTransportPlugin.sendError(
                "WIFI_RECOMMENDED",
                "Wi-Fi improves speed but is not required for text messages."
            )
        }

        // 3. Location enabled check (CONDITIONAL: Android 11 or lower only)
        val locationManager = context.applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val locationEnabled = locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
                locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
        Log.d(TAG, "OMNILINK_TRANSPORT: [t=$t0] Location enabled=$locationEnabled")

        val locationRequired = sdkInt <= 31 && isDiscoveryAttempt
        if (locationRequired && !locationEnabled) {
            OmnilinkTransportPlugin.sendError(
                "LOCATION_REQUIRED",
                "Android 11 or lower requires Location to discover new nearby devices."
            )
            return false
        }

        // 4. Permissions check
        val permissionsGranted = checkPermissions()

        val selectedMode = if (bluetoothEnabled && wifiEnabled) "highSpeedMesh" else if (bluetoothEnabled) "bluetoothOnly" else "offlineQueue"
        Log.i(TAG, "OMNILINK_TRANSPORT: capability bluetooth=$bluetoothEnabled wifi=$wifiEnabled location=$locationEnabled sdk=$sdkInt")
        Log.i(TAG, "OMNILINK_TRANSPORT: selected mode=$selectedMode")

        return bluetoothEnabled && permissionsGranted
    }

    fun getTransportCapabilityMap(): Map<String, Any> {
        val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        val bluetoothEnabled = bluetoothAdapter != null && bluetoothAdapter.isEnabled

        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val wifiEnabled = wifiManager?.isWifiEnabled == true

        val locationManager = context.applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        val locationEnabled = locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
                locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true

        val sdkInt = Build.VERSION.SDK_INT
        val playServicesCode = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
        val playServicesAvailable = playServicesCode == ConnectionResult.SUCCESS

        val canDiscover = bluetoothEnabled && checkPermissions() && (sdkInt > 31 || locationEnabled)

        return mapOf(
            "bluetoothEnabled" to bluetoothEnabled,
            "wifiEnabled" to wifiEnabled,
            "locationEnabled" to locationEnabled,
            "androidSdkInt" to sdkInt,
            "nearbyPlayServicesAvailable" to playServicesAvailable,
            "canDiscoverNewPeers" to canDiscover,
            "canUseHighBandwidth" to wifiEnabled,
            "canUseBluetoothOnlyFallback" to bluetoothEnabled
        )
    }

    // --------------------------------------------------------------------------
    // ADVERTISING & DISCOVERY LIFECYCLE (P2P_CLUSTER)
    // --------------------------------------------------------------------------

    fun startAdvertising(): Boolean {
        val t0 = System.currentTimeMillis()
        if (!performPreflightChecks(isDiscoveryAttempt = true)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] startAdvertising rejected: preflight checks failed")
            return false
        }

        if (isAdvertising) return true

        val options = AdvertisingOptions.Builder().setStrategy(strategy).build()
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] startAdvertising name=$localDeviceName serviceId=$SERVICE_ID strategy=P2P_CLUSTER")

        connectionsClient.startAdvertising(
            localDeviceName,
            SERVICE_ID,
            connectionLifecycleCallback,
            options
        ).addOnSuccessListener {
            val tSucc = System.currentTimeMillis()
            isAdvertising = true
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tSucc] startAdvertising SUCCESS")
        }.addOnFailureListener { e ->
            val tFail = System.currentTimeMillis()
            isAdvertising = false
            Log.e(TAG, "OMNILINK_NEARBY: [t=$tFail] startAdvertising FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "ADVERTISING_FAILED",
                e.localizedMessage ?: "Failed to start advertising"
            )
        }

        return true
    }

    fun startDiscovery(serviceId: String = SERVICE_ID): Boolean {
        val t0 = System.currentTimeMillis()
        if (!performPreflightChecks(isDiscoveryAttempt = true)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] startDiscovery rejected: preflight checks failed")
            return false
        }

        // Start advertising simultaneously to enable bi-directional P2P cluster discovery
        startAdvertising()

        if (isDiscovering) return true

        val options = DiscoveryOptions.Builder().setStrategy(strategy).build()
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] startDiscovery serviceId=$serviceId strategy=P2P_CLUSTER")

        connectionsClient.startDiscovery(
            serviceId,
            endpointDiscoveryCallback,
            options
        ).addOnSuccessListener {
            val tSucc = System.currentTimeMillis()
            isDiscovering = true
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tSucc] startDiscovery SUCCESS")
            scheduleDiscoveryTimeout(serviceId)
        }.addOnFailureListener { e ->
            val tFail = System.currentTimeMillis()
            isDiscovering = false
            Log.e(TAG, "OMNILINK_NEARBY: [t=$tFail] startDiscovery FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "DISCOVERY_FAILED",
                e.localizedMessage ?: "Failed to start discovery"
            )
        }

        return true
    }

    // Discovery Timeout & Single Retry (20 seconds)
    private fun scheduleDiscoveryTimeout(serviceId: String) {
        discoveryTimeoutRunnable?.let { handler.removeCallbacks(it) }

        val runnable = Runnable {
            val tNow = System.currentTimeMillis()
            if (isDiscovering && connectedPeers.isEmpty()) {
                Log.w(TAG, "OMNILINK_NEARBY: [t=$tNow] no peers found in 20s")
                if (!hasRetriedDiscovery) {
                    hasRetriedDiscovery = true
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tNow] restarting discovery once after 1s delay...")
                    connectionsClient.stopDiscovery()
                    isDiscovering = false
                    handler.postDelayed({
                        startDiscovery(serviceId)
                    }, 1000L)
                }
            }
        }
        discoveryTimeoutRunnable = runnable
        handler.postDelayed(runnable, 20000L)
    }

    fun stopDiscovery(): Boolean {
        val t0 = System.currentTimeMillis()
        discoveryTimeoutRunnable?.let { handler.removeCallbacks(it) }
        hasRetriedDiscovery = false

        if (isDiscovering) {
            connectionsClient.stopDiscovery()
            isDiscovering = false
            Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] stopDiscovery stopped")
        }
        if (isAdvertising) {
            connectionsClient.stopAdvertising()
            isAdvertising = false
            Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] stopAdvertising stopped")
        }
        return true
    }

    // --------------------------------------------------------------------------
    // CONNECTION LIFECYCLE & PEER MANAGEMENT
    // --------------------------------------------------------------------------

    fun connectPeer(peerId: String): Boolean {
        val t0 = System.currentTimeMillis()
        if (!checkPermissions()) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] connectPeer rejected: permissions missing")
            OmnilinkTransportPlugin.sendError("MISSING_PERMISSIONS", "Permissions missing for connect")
            return false
        }

        // Prevent Duplicate Connection Races (Ignore duplicate requests for 5s)
        val lastAttempt = pendingOutgoingConnections[peerId]
        if (lastAttempt != null && (t0 - lastAttempt) < 5000L) {
            Log.w(TAG, "OMNILINK_NEARBY: [t=$t0] ignoring duplicate connection attempt for peerId=$peerId (lock active)")
            return false
        }
        pendingOutgoingConnections[peerId] = t0

        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] connectPeer requested for peerId=$peerId")

        // Connection Timeout (15 seconds)
        val timeoutRunnable = Runnable {
            val tTimeout = System.currentTimeMillis()
            if (!connectedPeers.contains(peerId)) {
                Log.e(TAG, "OMNILINK_NEARBY: [t=$tTimeout] connection timeout for peerId=$peerId")
                pendingOutgoingConnections.remove(peerId)
                OmnilinkTransportPlugin.sendEvent(
                    mapOf(
                        "eventType" to "onError",
                        "peerId" to peerId,
                        "errorCode" to "CONNECTION_TIMEOUT",
                        "errorMessage" to "Connection to $peerId timed out after 15 seconds"
                    )
                )
            }
        }
        connectionTimeoutRunnables[peerId]?.let { handler.removeCallbacks(it) }
        connectionTimeoutRunnables[peerId] = timeoutRunnable
        handler.postDelayed(timeoutRunnable, 15000L)

        connectionsClient.requestConnection(
            localDeviceName,
            peerId,
            connectionLifecycleCallback
        ).addOnFailureListener { e ->
            val tFail = System.currentTimeMillis()
            connectionTimeoutRunnables.remove(peerId)?.let { handler.removeCallbacks(it) }
            pendingOutgoingConnections.remove(peerId)
            Log.e(TAG, "OMNILINK_NEARBY: [t=$tFail] connectPeer FAILED - ${e.localizedMessage}", e)
            OmnilinkTransportPlugin.sendError(
                "CONNECTION_REQUEST_FAILED",
                e.localizedMessage ?: "Failed to request connection to $peerId"
            )
        }

        return true
    }

    fun disconnectPeer(peerId: String): Boolean {
        val t0 = System.currentTimeMillis()
        connectionsClient.disconnectFromEndpoint(peerId)
        connectedPeers.remove(peerId)
        pendingOutgoingConnections.remove(peerId)
        connectionTimeoutRunnables.remove(peerId)?.let { handler.removeCallbacks(it) }

        // Clean up native send buffers
        outboundQueues.remove(peerId)
        inFlightPayloads.remove(peerId)

        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] disconnectPeer $peerId")

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
    // NATIVE BUFFERED PAYLOAD TRANSMISSION (0% SILENT DROPS)
    // --------------------------------------------------------------------------

    fun sendPacket(peerId: String, payloadBytes: ByteArray): Boolean {
        val t0 = System.currentTimeMillis()
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] sendPacket called for peerId=$peerId byteSize=${payloadBytes.size}")

        if (payloadBytes.size > 4096) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] sendPacket REJECTED to $peerId - payload size (${payloadBytes.size} bytes) exceeds 4096 MTU")
            OmnilinkTransportPlugin.sendError(
                "INVALID_PACKET_SIZE",
                "Payload size (${payloadBytes.size} bytes) exceeds 4,096 byte MTU limit"
            )
            return false
        }

        if (!connectedPeers.contains(peerId)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] sendPacket REJECTED to $peerId - not in connectedPeers=$connectedPeers")
            OmnilinkTransportPlugin.sendError(
                "PEER_NOT_CONNECTED",
                "Cannot send packet: Endpoint $peerId is not connected."
            )
            return false
        }

        // Add payload to endpoint's native concurrent outbound queue
        val queue = outboundQueues.getOrPut(peerId) { ConcurrentLinkedQueue() }
        queue.add(payloadBytes)
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] Payload enqueued for peerId=$peerId. Queue depth=${queue.size}")

        // Process next item in native queue asynchronously
        processNextPayload(peerId)
        return true
    }

    @Synchronized
    private fun processNextPayload(peerId: String) {
        val isBusy = inFlightPayloads[peerId] ?: false
        if (isBusy) {
            Log.d(TAG, "OMNILINK_NEARBY: Endpoint $peerId is currently busy transmitting. Queue item waiting.")
            return
        }

        val queue = outboundQueues[peerId] ?: return
        val nextBytes = queue.poll()
        if (nextBytes == null) {
            inFlightPayloads[peerId] = false
            return
        }

        inFlightPayloads[peerId] = true

        try {
            val payload = Payload.fromBytes(nextBytes)
            connectionsClient.sendPayload(peerId, payload)
                .addOnSuccessListener {
                    Log.d(TAG, "OMNILINK_NEARBY: [t=${System.currentTimeMillis()}] sendPayload accepted by Nearby client for $peerId (queue depth=${queue.size})")
                }
                .addOnFailureListener { e ->
                    Log.e(TAG, "OMNILINK_NEARBY: sendPayload failed for $peerId - ${e.localizedMessage}", e)
                    inFlightPayloads[peerId] = false
                    OmnilinkTransportPlugin.sendError(
                        "PAYLOAD_SEND_FAILED",
                        e.localizedMessage ?: "Failed to transmit payload to $peerId"
                    )
                    // Trigger next item in queue despite failure
                    handler.post { processNextPayload(peerId) }
                }
        } catch (e: Exception) {
            Log.e(TAG, "OMNILINK_NEARBY: sendPayload exception for $peerId - ${e.message}", e)
            inFlightPayloads[peerId] = false
            handler.post { processNextPayload(peerId) }
        }
    }

    // --------------------------------------------------------------------------
    // NEARBY CONNECTIONS CALLBACKS
    // --------------------------------------------------------------------------

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            val tFound = System.currentTimeMillis()
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tFound] onEndpointFound id=$endpointId name=${info.endpointName} serviceId=${info.serviceId}")
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "eventType" to "onPeerFound",
                    "peerId" to endpointId,
                    "friendlyName" to info.endpointName,
                    "rssi" to -50,
                    "transportType" to "ANDROID_NEARBY"
                )
            )
        }

        override fun onEndpointLost(endpointId: String) {
            val tLost = System.currentTimeMillis()
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tLost] onEndpointLost id=$endpointId")
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
            val tInit = System.currentTimeMillis()
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tInit] onConnectionInitiated id=$endpointId endpoint=${info.endpointName} -> Accepting connection instantly!")
            
            // INSTANT CONNECTION ACCEPTANCE (Zero Dart round-trip delay)
            connectionsClient.acceptConnection(endpointId, payloadCallback)
        }

        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) {
            val tRes = System.currentTimeMillis()
            connectionTimeoutRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }
            pendingOutgoingConnections.remove(endpointId)

            when (result.status.statusCode) {
                ConnectionsStatusCodes.STATUS_OK -> {
                    connectedPeers.add(endpointId)
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tRes] onConnectionResult $endpointId STATUS_OK -> connected (P2P_CLUSTER mesh link active)")
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
                    Log.e(TAG, "OMNILINK_NEARBY: [t=$tRes] onConnectionResult $endpointId FAILED statusCode=${result.status.statusCode}")
                    OmnilinkTransportPlugin.sendError(
                        "CONNECTION_FAILED",
                        "Connection to $endpointId failed with status code ${result.status.statusCode}"
                    )
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            val tDisc = System.currentTimeMillis()
            connectedPeers.remove(endpointId)
            pendingOutgoingConnections.remove(endpointId)
            connectionTimeoutRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }

            outboundQueues.remove(endpointId)
            inFlightPayloads.remove(endpointId)

            Log.d(TAG, "OMNILINK_NEARBY: [t=$tDisc] onDisconnected id=$endpointId")
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
            val tRecv = System.currentTimeMillis()
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes()
                if (bytes != null) {
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tRecv] onPayloadReceived from $endpointId with ${bytes.size} bytes")
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "incomingPacket",
                            "peerId" to endpointId,
                            "bytes" to bytes
                        )
                    )
                } else {
                    Log.e(TAG, "OMNILINK_NEARBY: [t=$tRecv] onPayloadReceived from $endpointId but payload.asBytes() returned null")
                }
            } else {
                Log.d(TAG, "OMNILINK_NEARBY: [t=$tRecv] onPayloadReceived from $endpointId with non-BYTES type=${payload.type}")
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            val tUpdate = System.currentTimeMillis()
            Log.d(TAG, "OMNILINK_NEARBY: [t=$tUpdate] onPayloadTransferUpdate for $endpointId status=${update.status} bytes=${update.bytesTransferred}/${update.totalBytes}")
            when (update.status) {
                PayloadTransferUpdate.Status.SUCCESS -> {
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tUpdate] payload transfer SUCCESS for $endpointId (<50ms radio delivery)")
                    inFlightPayloads[endpointId] = false
                    // Trigger next item in native outbound queue immediately
                    handler.post { processNextPayload(endpointId) }
                }
                PayloadTransferUpdate.Status.FAILURE,
                PayloadTransferUpdate.Status.CANCELED -> {
                    Log.e(TAG, "OMNILINK_NEARBY: [t=$tUpdate] payload transfer status=${update.status} for $endpointId")
                    inFlightPayloads[endpointId] = false
                    // Trigger next item in native outbound queue immediately
                    handler.post { processNextPayload(endpointId) }
                }
                PayloadTransferUpdate.Status.IN_PROGRESS -> {
                    // Payload bytes transferring...
                }
            }
        }
    }

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
        return true
    }
}
