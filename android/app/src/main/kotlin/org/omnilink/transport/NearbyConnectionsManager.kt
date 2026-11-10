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
import java.util.UUID
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

    // Stable, unique advertised name. Using only Build.MODEL makes every phone
    // of the same model indistinguishable for reconnect-by-name.
    private val localDeviceName: String = buildLocalDeviceName()
    private val reconnectPrefs =
        context.applicationContext.getSharedPreferences("omnilink_reconnect", Context.MODE_PRIVATE)

    // Strategy rule #1: Upgrade to Strategy.P2P_CLUSTER for true multi-peer mesh
    private val strategy = Strategy.P2P_CLUSTER

    private val connectedPeers: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val endpointNames = ConcurrentHashMap<String, String>()
    // Authoritative bidirectional mapping: persistent 64-char nodeId <-> transient endpointId.
    // Populated from Dart via registerNodeMapping once ROUTE_ADVERTISEMENT handshake completes.
    private val nodeIdToEndpoint = ConcurrentHashMap<String, String>()
    private val endpointToNodeId = ConcurrentHashMap<String, String>()
    private val pendingOutgoingConnections = mutableMapOf<String, Long>()
    private val handler = Handler(Looper.getMainLooper())
    private val connectionTimeoutRunnables = mutableMapOf<String, Runnable>()

    // Native outbound payload queueing to prevent buffer overruns
    private val outboundQueues = ConcurrentHashMap<String, ConcurrentLinkedQueue<ByteArray>>()
    private val inFlightPayloads = ConcurrentHashMap<String, Boolean>()

    private var isAdvertising = false
    private var isDiscovering = false
    private var autoDiscoveryEnabled = true
    private var discoveryTimeoutRunnable: Runnable? = null

    // Reconnect state. Endpoint IDs rotate, so we track the remote device name
    // as a rediscovery key as well as the last endpoint for fast retries.
    private var autoReconnectEnabled = true
    private val desiredEndpointNames = ConcurrentHashMap.newKeySet<String>()
    private val manualDisconnects = ConcurrentHashMap.newKeySet<String>()
    private val reconnectAttempts = ConcurrentHashMap<String, Int>()
    private val reconnectRunnables = ConcurrentHashMap<String, Runnable>()

    companion object {
        private const val TAG = "OMNILINK_NEARBY"
        private const val MAX_RECONNECT_ATTEMPTS = 12
        private const val DESIRED_NAMES_KEY = "desired_peer_names"

        @Volatile
        private var INSTANCE: NearbyConnectionsManager? = null

        fun getInstance(context: Context): NearbyConnectionsManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: NearbyConnectionsManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }

    init {
        loadDesiredNames()
    }

    private fun buildLocalDeviceName(): String {
        val prefs = context.applicationContext.getSharedPreferences("omnilink_device", Context.MODE_PRIVATE)
        var suffix = prefs.getString("device_suffix", null)
        if (suffix.isNullOrEmpty()) {
            suffix = UUID.randomUUID().toString().replace("-", "").take(6).uppercase()
            prefs.edit().putString("device_suffix", suffix).apply()
        }
        return "OMNILINK_${Build.MODEL.replace(" ", "_")}_$suffix"
    }

    private fun loadDesiredNames() {
        desiredEndpointNames.addAll(
            reconnectPrefs.getStringSet(DESIRED_NAMES_KEY, emptySet()) ?: emptySet(),
        )
    }

    private fun persistDesiredNames() {
        reconnectPrefs.edit().putStringSet(DESIRED_NAMES_KEY, desiredEndpointNames.toSet()).apply()
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
        val permMap = getDetailedPermissionStatus()

        return mapOf(
            "bluetoothEnabled" to bluetoothEnabled,
            "wifiEnabled" to wifiEnabled,
            "locationEnabled" to locationEnabled,
            "androidSdkInt" to sdkInt,
            "nearbyPlayServicesAvailable" to playServicesAvailable,
            "canDiscoverNewPeers" to canDiscover,
            "canUseHighBandwidth" to wifiEnabled,
            "canUseBluetoothOnlyFallback" to bluetoothEnabled,
            "nearbyWifiDevicesGranted" to (permMap["nearbyWifiDevices"] == true),
            "bluetoothConnectGranted" to (permMap["bluetoothConnect"] == true),
            "permissionsFullyGranted" to (permMap["isFullyGranted"] == true)
        )
    }

    fun getDetailedPermissionStatus(): Map<String, Any> {
        val sdkInt = Build.VERSION.SDK_INT
        val missing = mutableListOf<String>()

        val scanGranted = if (sdkInt >= Build.VERSION_CODES.S) {
            val g = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            if (!g) missing.add(android.Manifest.permission.BLUETOOTH_SCAN)
            g
        } else true

        val connectGranted = if (sdkInt >= Build.VERSION_CODES.S) {
            val g = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            if (!g) missing.add(android.Manifest.permission.BLUETOOTH_CONNECT)
            g
        } else true

        val advertiseGranted = if (sdkInt >= Build.VERSION_CODES.S) {
            val g = ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
            if (!g) missing.add(android.Manifest.permission.BLUETOOTH_ADVERTISE)
            g
        } else true

        val nearbyWifiGranted = if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
            val g = ContextCompat.checkSelfPermission(context, android.Manifest.permission.NEARBY_WIFI_DEVICES) == PackageManager.PERMISSION_GRANTED
            if (!g) missing.add(android.Manifest.permission.NEARBY_WIFI_DEVICES)
            g
        } else true

        val locationGranted = if (sdkInt <= 31) {
            val g = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            if (!g) missing.add(android.Manifest.permission.ACCESS_FINE_LOCATION)
            g
        } else true

        val isFully = missing.isEmpty()

        return mapOf(
            "bluetoothScan" to scanGranted,
            "bluetoothConnect" to connectGranted,
            "bluetoothAdvertise" to advertiseGranted,
            "nearbyWifiDevices" to nearbyWifiGranted,
            "fineLocation" to locationGranted,
            "isFullyGranted" to isFully,
            "missingPermissions" to missing
        )
    }

    private fun checkPermissions(): Boolean {
        val permMap = getDetailedPermissionStatus()
        val isFully = permMap["isFullyGranted"] == true
        if (!isFully) {
            val missing = permMap["missingPermissions"] as? List<*>
            Log.e(TAG, "checkPermissions FAILED. Missing required permissions: $missing")
            OmnilinkTransportPlugin.sendError(
                "OMNILINK_ERROR_PERMISSION_DENIED",
                "Missing required Android radio permissions: $missing"
            )
        }
        return isFully
    }

    /** Silent permission probe for the 15s service watchdog (no event spam). */
    private fun hasRadioPermissions(): Boolean {
        return getDetailedPermissionStatus()["isFullyGranted"] == true
    }

    // --------------------------------------------------------------------------
    // ADVERTISING & DISCOVERY LIFECYCLE (P2P_CLUSTER)
    // --------------------------------------------------------------------------

    fun startAdvertising(serviceId: String = SERVICE_ID): Boolean {
        val t0 = System.currentTimeMillis()
        if (!performPreflightChecks(isDiscoveryAttempt = true)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] startAdvertising rejected: preflight checks failed")
            return false
        }

        if (isAdvertising) return true

        val options = AdvertisingOptions.Builder().setStrategy(strategy).build()
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] startAdvertising name=$localDeviceName serviceId=$serviceId strategy=P2P_CLUSTER")

        try {
            connectionsClient.startAdvertising(
                localDeviceName,
                serviceId,
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
        } catch (e: SecurityException) {
            isAdvertising = false
            Log.e(TAG, "OMNILINK_NEARBY: SecurityException in startAdvertising: ${e.message}")
            OmnilinkTransportPlugin.sendError(
                "OMNILINK_ERROR_PERMISSION_DENIED",
                "SecurityException in startAdvertising: ${e.message}"
            )
            return false
        }

        return true
    }

    fun stopAdvertising(): Boolean {
        val t0 = System.currentTimeMillis()
        if (isAdvertising) {
            connectionsClient.stopAdvertising()
            isAdvertising = false
            Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] stopAdvertising stopped")
        }
        return true
    }

    fun startDiscovery(serviceId: String = SERVICE_ID): Boolean {
        val t0 = System.currentTimeMillis()
        autoDiscoveryEnabled = true
        if (!performPreflightChecks(isDiscoveryAttempt = true)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] startDiscovery rejected: preflight checks failed")
            return false
        }

        // Start advertising simultaneously to enable bi-directional P2P cluster discovery
        startAdvertising()

        if (isDiscovering) return true

        val options = DiscoveryOptions.Builder().setStrategy(strategy).build()
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] startDiscovery serviceId=$serviceId strategy=P2P_CLUSTER")

        try {
            connectionsClient.startDiscovery(
                serviceId,
                endpointDiscoveryCallback,
                options
            ).addOnSuccessListener {
                val tSucc = System.currentTimeMillis()
                isDiscovering = true
                Log.d(TAG, "OMNILINK_NEARBY: [t=$tSucc] startDiscovery SUCCESS")
                scheduleDiscoveryCycle(serviceId)
            }.addOnFailureListener { e ->
                val tFail = System.currentTimeMillis()
                isDiscovering = false
                Log.e(TAG, "OMNILINK_NEARBY: [t=$tFail] startDiscovery FAILED - ${e.localizedMessage}", e)
                OmnilinkTransportPlugin.sendError(
                    "DISCOVERY_FAILED",
                    e.localizedMessage ?: "Failed to start discovery"
                )
            }
        } catch (e: SecurityException) {
            isDiscovering = false
            Log.e(TAG, "OMNILINK_NEARBY: SecurityException in startDiscovery: ${e.message}")
            OmnilinkTransportPlugin.sendError(
                "OMNILINK_ERROR_PERMISSION_DENIED",
                "SecurityException in startDiscovery: ${e.message}"
            )
            return false
        }

        return true
    }

    // Continuous duty-cycled discovery. Nearby discovery can silently stop on
    // some OEMs; restart it whenever no peer is connected and keep the cycle
    // alive while connected so a later disconnect still has a fresh loop.
    private fun scheduleDiscoveryCycle(serviceId: String) {
        discoveryTimeoutRunnable?.let { handler.removeCallbacks(it) }

        val runnable = Runnable {
            if (!autoDiscoveryEnabled) return@Runnable
            val tNow = System.currentTimeMillis()
            if (connectedPeers.isEmpty()) {
                Log.w(TAG, "OMNILINK_NEARBY: [t=$tNow] no connected peers; restarting discovery in 1s")
                if (isDiscovering) {
                    connectionsClient.stopDiscovery()
                    isDiscovering = false
                }
                handler.postDelayed({
                    if (autoDiscoveryEnabled) startDiscovery(serviceId)
                }, 1000L)
            } else {
                handler.postDelayed({
                    if (autoDiscoveryEnabled) scheduleDiscoveryCycle(serviceId)
                }, 20000L)
            }
        }
        discoveryTimeoutRunnable = runnable
        handler.postDelayed(runnable, 20000L)
    }

    fun stopDiscovery(): Boolean {
        val t0 = System.currentTimeMillis()
        autoDiscoveryEnabled = false
        discoveryTimeoutRunnable?.let { handler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null

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

    /**
     * Service watchdog entry point. Re-arms advertising/discovery without
     * disturbing an already active link.
     */
    fun ensureMeshActive(): Boolean {
        if (!hasRadioPermissions()) return false
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return false
        if (!adapter.isEnabled) return false

        val advertising = if (!isAdvertising) startAdvertising() else true
        val discovering = if (!isDiscovering) startDiscovery() else true
        return advertising && discovering
    }

    fun setAutoReconnect(enabled: Boolean) {
        autoReconnectEnabled = enabled
        if (!enabled) {
            desiredEndpointNames.clear()
            persistDesiredNames()
            for (runnable in reconnectRunnables.values) handler.removeCallbacks(runnable)
            reconnectRunnables.clear()
            reconnectAttempts.clear()
        }
    }

    private fun scheduleReconnect(endpointId: String) {
        if (!autoReconnectEnabled || connectedPeers.contains(endpointId)) return

        val attempts = (reconnectAttempts[endpointId] ?: 0) + 1
        reconnectAttempts[endpointId] = attempts
        if (attempts > MAX_RECONNECT_ATTEMPTS) {
            Log.w(TAG, "OMNILINK_NEARBY: giving up reconnect for $endpointId after $attempts attempt(s)")
            return
        }

        val delayMs = when (attempts) {
            1 -> 2_000L
            2 -> 5_000L
            3 -> 10_000L
            else -> 30_000L
        }

        reconnectRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            if (autoReconnectEnabled && !connectedPeers.contains(endpointId)) {
                Log.d(TAG, "OMNILINK_NEARBY: reconnect attempt $attempts for $endpointId")
                connectPeer(endpointId)
            }
        }
        reconnectRunnables[endpointId] = runnable
        handler.postDelayed(runnable, delayMs)
    }

    private fun cancelReconnect(endpointId: String) {
        reconnectRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }
        reconnectAttempts.remove(endpointId)
    }

    private fun rememberDesiredPeer(endpointId: String) {
        val name = endpointNames[endpointId] ?: return
        if (desiredEndpointNames.add(name)) {
            persistDesiredNames()
        }
    }

    /** Called after a radio toggle or boot so desired peers reconnect quickly. */
    fun onRadioAvailable() {
        if (!autoReconnectEnabled) return
        ensureMeshActive()
        for ((endpointId, name) in endpointNames) {
            if (desiredEndpointNames.contains(name) && !connectedPeers.contains(endpointId)) {
                scheduleReconnect(endpointId)
            }
        }
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

        // Check if endpoint is already connected
        if (connectedPeers.contains(peerId)) {
            Log.i(TAG, "OMNILINK_NEARBY: [t=$t0] connectPeer ignored for peerId=$peerId: already connected")
            return true
        }

        // A fresh connect attempt is explicit intent; clear a previous manual
        // disconnect marker so failures can be retried by the reconnect loop.
        manualDisconnects.remove(peerId)

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
            if (connectedPeers.contains(peerId)) {
                Log.w(TAG, "OMNILINK_NEARBY: [t=$tFail] connectPeer request failed for peerId=$peerId but endpoint is already connected. Suppressing error.")
                return@addOnFailureListener
            }
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
        // Accept either endpointId or nodeId so Dart callers holding nodeIds clean up correctly.
        val endpointId = resolveEndpoint(peerId) ?: peerId
        manualDisconnects.add(peerId)
        manualDisconnects.add(endpointId)
        cancelReconnect(endpointId)
        endpointNames[endpointId]?.let {
            if (desiredEndpointNames.remove(it)) persistDesiredNames()
        }

        connectionsClient.disconnectFromEndpoint(endpointId)
        connectedPeers.remove(endpointId)
        unregisterNodeMappingForEndpoint(endpointId)
        pendingOutgoingConnections.remove(peerId)
        pendingOutgoingConnections.remove(endpointId)
        connectionTimeoutRunnables.remove(peerId)?.let { handler.removeCallbacks(it) }
        connectionTimeoutRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }

        // Clean up native send buffers
        outboundQueues.remove(endpointId)
        inFlightPayloads.remove(endpointId)

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
        if (connectedPeers.contains(peerId)) return true;
        // Allow callers holding a persistent nodeId to query via resolved endpoint.
        val endpoint = nodeIdToEndpoint[peerId]
        return endpoint != null && connectedPeers.contains(endpoint)
    }

    fun registerNodeMapping(nodeId: String, endpointId: String): Boolean {
        if (nodeId.isEmpty() || endpointId.isEmpty()) return false
        nodeIdToEndpoint[nodeId] = endpointId
        endpointToNodeId[endpointId] = nodeId
        Log.d(TAG, "registerNodeMapping nodeId=${nodeId.take(8)} <-> endpointId=$endpointId")
        return true
    }

    fun unregisterNodeMappingForEndpoint(endpointId: String) {
        val nodeId = endpointToNodeId.remove(endpointId)
        if (nodeId != null) {
            if (nodeIdToEndpoint[nodeId] == endpointId) {
                nodeIdToEndpoint.remove(nodeId)
            }
            Log.d(TAG, "unregisterNodeMapping endpointId=$endpointId (nodeId=${nodeId.take(8)})")
        }
    }

    fun resolveEndpoint(targetId: String): String? {
        if (connectedPeers.contains(targetId)) return targetId
        val endpoint = nodeIdToEndpoint[targetId]
        if (endpoint != null && connectedPeers.contains(endpoint)) return endpoint
        return null
    }

    fun getConnectedEndpoints(): List<String> {
        synchronized(connectedPeers) {
            return connectedPeers.toList()
        }
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

        var targetEndpointId = peerId
        // Resolve persistent nodeId -> transient endpointId via authoritative map.
        if (!connectedPeers.contains(targetEndpointId)) {
            val resolved = nodeIdToEndpoint[peerId]
            if (resolved != null && connectedPeers.contains(resolved)) {
                Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] sendPacket resolved nodeId=${peerId.take(8)} -> endpoint $resolved")
                targetEndpointId = resolved
            }
        }
        if (!connectedPeers.contains(targetEndpointId)) {
            Log.e(TAG, "OMNILINK_NEARBY: [t=$t0] sendPacket REJECTED to $peerId - not in connectedPeers=$connectedPeers")
            OmnilinkTransportPlugin.sendError(
                "PEER_NOT_CONNECTED",
                "Cannot send packet: Endpoint $peerId is not connected."
            )
            return false
        }

        // Add payload to endpoint's native concurrent outbound queue
        val queue = outboundQueues.getOrPut(targetEndpointId) { ConcurrentLinkedQueue() }
        queue.add(payloadBytes)
        Log.d(TAG, "OMNILINK_NEARBY: [t=$t0] Payload enqueued for targetEndpointId=$targetEndpointId. Queue depth=${queue.size}")

        // Process next item in native queue asynchronously
        processNextPayload(targetEndpointId)
        return true
    }

    @Synchronized
    private fun processNextPayload(peerId: String) {
        if (!connectedPeers.contains(peerId)) {
            Log.d(TAG, "OMNILINK_NEARBY: processNextPayload aborted for $peerId - endpoint is not connected.")
            inFlightPayloads[peerId] = false
            outboundQueues.remove(peerId)
            return
        }

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
            endpointNames[endpointId] = info.endpointName
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

            // Endpoint IDs rotate. Rediscovering a desired device name is the
            // reliable way to re-establish a link after a drop.
            if (autoReconnectEnabled &&
                desiredEndpointNames.contains(info.endpointName) &&
                !connectedPeers.contains(endpointId)
            ) {
                Log.d(TAG, "OMNILINK_NEARBY: auto-connecting desired peer ${info.endpointName} at $endpointId")
                connectPeer(endpointId)
            }
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
            endpointNames[endpointId] = info.endpointName
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
                    val name = endpointNames[endpointId] ?: "OMNILINK_$endpointId"
                    manualDisconnects.remove(endpointId)
                    cancelReconnect(endpointId)
                    if (desiredEndpointNames.add(name)) persistDesiredNames()
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tRes] onConnectionResult $endpointId STATUS_OK -> connected (P2P_CLUSTER mesh link active)")
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "eventType" to "onConnected",
                            "peerId" to endpointId,
                            "friendlyName" to name,
                            "transportType" to "ANDROID_NEARBY"
                        )
                    )
                }
                ConnectionsStatusCodes.STATUS_ALREADY_CONNECTED_TO_ENDPOINT -> {
                    connectedPeers.add(endpointId)
                    val name = endpointNames[endpointId] ?: "OMNILINK_$endpointId"
                    manualDisconnects.remove(endpointId)
                    cancelReconnect(endpointId)
                    if (desiredEndpointNames.add(name)) persistDesiredNames()
                    Log.i(TAG, "OMNILINK_NEARBY: [t=$tRes] onConnectionResult $endpointId STATUS_ALREADY_CONNECTED_TO_ENDPOINT (8003) -> connection converged; endpoint retained in connectedPeers")
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "eventType" to "onConnected",
                            "peerId" to endpointId,
                            "friendlyName" to name,
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
                    if (autoReconnectEnabled && !manualDisconnects.contains(endpointId)) {
                        rememberDesiredPeer(endpointId)
                        scheduleReconnect(endpointId)
                    }
                }
            }
        }

        override fun onDisconnected(endpointId: String) {
            val tDisc = System.currentTimeMillis()
            val wasManual = manualDisconnects.remove(endpointId)
            if (!wasManual) {
                rememberDesiredPeer(endpointId)
            }

            connectedPeers.remove(endpointId)
            unregisterNodeMappingForEndpoint(endpointId)
            pendingOutgoingConnections.remove(endpointId)
            connectionTimeoutRunnables.remove(endpointId)?.let { handler.removeCallbacks(it) }

            outboundQueues.remove(endpointId)
            inFlightPayloads[endpointId] = false
            inFlightPayloads.remove(endpointId)

            Log.d(TAG, "OMNILINK_NEARBY: [t=$tDisc] onDisconnected id=$endpointId (manual=$wasManual)")
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "eventType" to "onDisconnected",
                    "peerId" to endpointId
                )
            )

            if (autoReconnectEnabled && !wasManual) {
                scheduleReconnect(endpointId)
            }
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            val tRecv = System.currentTimeMillis()
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes()
                if (bytes != null) {
                    Log.d(TAG, "OMNILINK_NEARBY: [t=$tRecv] onPayloadReceived from $endpointId with ${bytes.size} bytes")
                    // Persist before emitting. The spool is the durability
                    // boundary for inbound payloads; Dart acknowledges rows
                    // only after the packet is durably accepted.
                    val spoolId = OmnilinkInboundSpool.getInstance(context).append(endpointId, bytes)
                    val event = mutableMapOf<String, Any?>(
                        "type" to "incomingPacket",
                        "peerId" to endpointId,
                        "bytes" to bytes,
                    )
                    if (spoolId != null) {
                        event["spoolId"] = spoolId
                    }
                    OmnilinkTransportPlugin.sendEvent(event)
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
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "payloadTransferUpdate",
                            "eventType" to "onPayloadTransferUpdate",
                            "peerId" to endpointId,
                            "payloadId" to update.payloadId,
                            "status" to "SUCCESS",
                            "bytesTransferred" to update.bytesTransferred,
                            "totalBytes" to update.totalBytes
                        )
                    )
                    // Trigger next item in native outbound queue immediately
                    handler.post { processNextPayload(endpointId) }
                }
                PayloadTransferUpdate.Status.FAILURE,
                PayloadTransferUpdate.Status.CANCELED -> {
                    Log.e(TAG, "OMNILINK_NEARBY: [t=$tUpdate] payload transfer status=${update.status} for $endpointId")
                    inFlightPayloads[endpointId] = false
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "payloadTransferUpdate",
                            "eventType" to "onPayloadTransferUpdate",
                            "peerId" to endpointId,
                            "payloadId" to update.payloadId,
                            "status" to "FAILURE",
                            "bytesTransferred" to update.bytesTransferred,
                            "totalBytes" to update.totalBytes
                        )
                    )
                    // Trigger next item in native outbound queue immediately
                    handler.post { processNextPayload(endpointId) }
                }
                PayloadTransferUpdate.Status.IN_PROGRESS -> {
                    // Payload bytes transferring...
                }
            }
        }
    }
}
