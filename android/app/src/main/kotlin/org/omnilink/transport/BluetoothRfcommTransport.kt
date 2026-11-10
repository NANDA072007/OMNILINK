package org.omnilink.transport

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android Native Bluetooth RFCOMM Stream Socket Transport for OMNILINK.
 * Provides a location-free, Wi-Fi-free direct 1-to-1 fallback transport for bonded devices.
 * Uses a fixed UUID service record with 4-byte big-endian length prefix framing.
 * Hardened against OS Bluetooth state changes, socket leaks, and thread deadlocks.
 */
class BluetoothRfcommTransport private constructor(private val context: Context) {

    companion object {
        private const val TAG = "OMNILINK_RFCOMM"
        private const val SERVICE_NAME = "OMNILINK_MESH_RFCOMM"
        val OMNILINK_UUID: UUID = UUID.fromString("8ce255c0-200a-11ee-be56-0242ac120002")

        @Volatile
        private var instance: BluetoothRfcommTransport? = null

        fun getInstance(context: Context): BluetoothRfcommTransport {
            return instance ?: synchronized(this) {
                instance ?: BluetoothRfcommTransport(context.applicationContext).also { instance = it }
            }
        }
    }

    private val bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var acceptThread: AcceptThread? = null
    private val activeConnections = ConcurrentHashMap<String, ConnectedThread>()

    @Volatile
    private var isReceiverRegistered = false

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(recvContext: Context?, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                onBluetoothStateChanged(state)
            }
        }
    }

    init {
        registerBluetoothStateReceiver()
    }

    /**
     * Registers the BroadcastReceiver for OS Bluetooth adapter state transitions.
     */
    @Synchronized
    fun registerBluetoothStateReceiver() {
        if (!isReceiverRegistered) {
            try {
                val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
                context.applicationContext.registerReceiver(bluetoothStateReceiver, filter)
                isReceiverRegistered = true
                Log.i(TAG, "Bluetooth state BroadcastReceiver registered.")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register Bluetooth state BroadcastReceiver: ${e.message}")
            }
        }
    }

    /**
     * Unregisters the BroadcastReceiver to prevent context leaks.
     */
    @Synchronized
    fun unregisterBluetoothStateReceiver() {
        if (isReceiverRegistered) {
            try {
                context.applicationContext.unregisterReceiver(bluetoothStateReceiver)
                Log.i(TAG, "Bluetooth state BroadcastReceiver unregistered.")
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering Bluetooth state BroadcastReceiver: ${e.message}")
            } finally {
                isReceiverRegistered = false
            }
        }
    }

    /**
     * Handles OS Bluetooth state transitions: STATE_OFF, STATE_TURNING_OFF, STATE_ON, STATE_TURNING_ON.
     */
    fun onBluetoothStateChanged(state: Int) {
        val stateString = when (state) {
            BluetoothAdapter.STATE_OFF -> "STATE_OFF"
            BluetoothAdapter.STATE_TURNING_OFF -> "STATE_TURNING_OFF"
            BluetoothAdapter.STATE_ON -> "STATE_ON"
            BluetoothAdapter.STATE_TURNING_ON -> "STATE_TURNING_ON"
            else -> "STATE_UNKNOWN"
        }

        Log.i(TAG, "Bluetooth state transition: $stateString ($state)")

        OmnilinkTransportPlugin.sendEvent(
            mapOf(
                "type" to "bluetoothStateChanged",
                "state" to stateString,
                "isAvailable" to (state == BluetoothAdapter.STATE_ON)
            )
        )

        when (state) {
            BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                Log.i(TAG, "Bluetooth turning off/off. Initiating complete RFCOMM socket & thread cleanup...")
                cleanupAllConnections()
            }
            BluetoothAdapter.STATE_ON -> {
                Log.i(TAG, "Bluetooth turned back ON. Server ready for active connections.")
            }
        }
    }

    /**
     * Safely closes all active sockets, server listeners, and worker threads.
     */
    @Synchronized
    fun cleanupAllConnections() {
        Log.i(TAG, "Closing accept thread and ${activeConnections.size} active RFCOMM connection sockets...")
        stopServer()

        val iterator = activeConnections.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.cancel()
            iterator.remove()
        }
        Log.i(TAG, "RFCOMM cleanup complete. All sockets closed and thread pool drained.")
    }

    fun getBondedDevices(): List<Map<String, Any?>> {
        val adapter = bluetoothAdapter ?: return emptyList()
        val devices = mutableListOf<Map<String, Any?>>()
        try {
            val bonded = adapter.bondedDevices
            if (bonded != null) {
                for (dev in bonded) {
                    devices.add(
                        mapOf(
                            "deviceName" to (dev.name ?: "Unknown Device"),
                            "deviceAddress" to dev.address,
                            "bondState" to dev.bondState
                        )
                    )
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException fetching bonded devices: ${e.message}")
        }
        return devices
    }

    fun startServer(): Boolean {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "startServer rejected: Bluetooth adapter disabled")
            return false
        }
        stopServer()
        acceptThread = AcceptThread().apply { start() }
        Log.i(TAG, "RFCOMM AcceptThread started for UUID $OMNILINK_UUID")
        OmnilinkTransportPlugin.sendEvent(
            mapOf("type" to "rfcommServerStarted", "serviceUuid" to OMNILINK_UUID.toString())
        )
        return true
    }

    fun stopServer() {
        acceptThread?.cancel()
        acceptThread = null
    }

    fun connectDevice(deviceAddress: String): Boolean {
        val adapter = bluetoothAdapter ?: return false
        if (!adapter.isEnabled) {
            Log.e(TAG, "connectDevice rejected: Bluetooth adapter disabled")
            return false
        }
        try {
            val device: BluetoothDevice = adapter.getRemoteDevice(deviceAddress)
            ConnectThread(device).start()
            Log.i(TAG, "RFCOMM ConnectThread initiated for $deviceAddress")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error connecting RFCOMM device $deviceAddress: ${e.message}")
            return false
        }
    }

    fun disconnectDevice(deviceAddress: String): Boolean {
        val connection = activeConnections.remove(deviceAddress)
        connection?.cancel()
        Log.i(TAG, "RFCOMM disconnected for $deviceAddress")
        return true
    }

    fun sendPacket(deviceAddress: String, payload: ByteArray): Boolean {
        val connection = activeConnections[deviceAddress]
        if (connection == null) {
            Log.e(TAG, "sendPacket failed: No active RFCOMM connection for $deviceAddress")
            return false
        }
        return connection.write(payload)
    }

    fun isConnected(deviceAddress: String): Boolean {
        return activeConnections.containsKey(deviceAddress)
    }

    fun teardown() {
        cleanupAllConnections()
        unregisterBluetoothStateReceiver()
    }

    private fun manageSocket(socket: BluetoothSocket, deviceAddress: String) {
        val connectedThread = ConnectedThread(socket, deviceAddress)
        activeConnections[deviceAddress] = connectedThread
        connectedThread.start()

        Log.i(TAG, "RFCOMM socket connected with $deviceAddress")
        OmnilinkTransportPlugin.sendEvent(
            mapOf(
                "type" to "rfcommConnected",
                "peerId" to deviceAddress,
                "eventType" to "onConnected",
                "endpointName" to (socket.remoteDevice?.name ?: "Unknown Device")
            )
        )
    }

    /**
     * Server Thread listening for incoming Bluetooth RFCOMM socket connections.
     */
    private inner class AcceptThread : Thread() {
        @Volatile
        private var isListening = true

        private val serverSocket: BluetoothServerSocket? = try {
            bluetoothAdapter?.listenUsingRfcommWithServiceRecord(SERVICE_NAME, OMNILINK_UUID)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException creating RFCOMM server socket: ${e.message}")
            null
        } catch (e: IOException) {
            Log.e(TAG, "IOException creating RFCOMM server socket: ${e.message}")
            null
        }

        override fun run() {
            while (isListening) {
                val socket: BluetoothSocket? = try {
                    serverSocket?.accept()
                } catch (e: IOException) {
                    if (isListening) {
                        Log.d(TAG, "AcceptThread socket accept stopped: ${e.message}")
                    }
                    isListening = false
                    null
                }

                if (socket != null && isListening) {
                    manageSocket(socket, socket.remoteDevice.address)
                }
            }
            Log.i(TAG, "AcceptThread stopped gracefully.")
        }

        fun cancel() {
            isListening = false
            try {
                serverSocket?.close()
            } catch (e: IOException) {
                Log.e(TAG, "Error closing server socket: ${e.message}")
            }
        }
    }

    /**
     * Client Thread establishing outgoing RFCOMM socket connection to remote bonded device.
     */
    private inner class ConnectThread(private val device: BluetoothDevice) : Thread() {
        private val socket: BluetoothSocket? = try {
            device.createRfcommSocketToServiceRecord(OMNILINK_UUID)
        } catch (e: Exception) {
            Log.e(TAG, "Error creating RFCOMM client socket: ${e.message}")
            null
        }

        override fun run() {
            try {
                bluetoothAdapter?.cancelDiscovery()
            } catch (e: SecurityException) {
                Log.e(TAG, "SecurityException cancelling discovery: ${e.message}")
            }
            try {
                socket?.connect()
                socket?.let {
                    manageSocket(it, device.address)
                }
            } catch (e: IOException) {
                Log.e(TAG, "RFCOMM connect failed to ${device.address}: ${e.message}")
                try {
                    socket?.close()
                } catch (ignored: Exception) {}
                OmnilinkTransportPlugin.sendError(
                    "RFCOMM_CONNECT_FAILED",
                    "Failed to establish RFCOMM link to ${device.address}: ${e.message}"
                )
            }
        }
    }

    /**
     * Active Stream IO Thread reading/writing raw packet bytes framed with 4-byte big-endian length headers.
     */
    private inner class ConnectedThread(
        private val socket: BluetoothSocket,
        private val peerAddress: String
    ) : Thread() {
        @Volatile
        private var isRunning = true
        private val isDisconnectedEmitted = AtomicBoolean(false)

        private val inputStream: DataInputStream? = try {
            DataInputStream(socket.inputStream)
        } catch (e: IOException) { null }

        private val outputStream: DataOutputStream? = try {
            DataOutputStream(socket.outputStream)
        } catch (e: IOException) { null }

        override fun run() {
            val input = inputStream ?: run {
                closeStreamsAndSocket()
                emitDisconnectedEventOnce()
                return
            }

            while (isRunning) {
                try {
                    val packetLength = input.readInt()
                    if (packetLength <= 0 || packetLength > 5 * 1024 * 1024) {
                        Log.e(TAG, "Invalid RFCOMM packet length from $peerAddress: $packetLength")
                        break
                    }

                    val buffer = ByteArray(packetLength)
                    input.readFully(buffer)

                    Log.d(TAG, "RFCOMM payload received from $peerAddress ($packetLength bytes)")

                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "incomingPacket",
                            "peerId" to peerAddress,
                            "bytes" to buffer
                        )
                    )
                } catch (e: IOException) {
                    Log.i(TAG, "RFCOMM read closed for $peerAddress: ${e.message}")
                    break
                }
            }

            closeStreamsAndSocket()
            activeConnections.remove(peerAddress)
            emitDisconnectedEventOnce()
        }

        private fun emitDisconnectedEventOnce() {
            if (isDisconnectedEmitted.compareAndSet(false, true)) {
                OmnilinkTransportPlugin.sendEvent(
                    mapOf(
                        "type" to "rfcommDisconnected",
                        "peerId" to peerAddress,
                        "eventType" to "onDisconnected"
                    )
                )
            }
        }

        fun write(bytes: ByteArray): Boolean {
            if (!isRunning) return false
            val output = outputStream ?: return false
            return try {
                synchronized(output) {
                    output.writeInt(bytes.size)
                    output.write(bytes)
                    output.flush()
                }
                Log.d(TAG, "RFCOMM packet sent to $peerAddress (${bytes.size} bytes)")
                true
            } catch (e: IOException) {
                Log.e(TAG, "Error writing RFCOMM packet to $peerAddress: ${e.message}")
                cancel()
                false
            }
        }

        fun cancel() {
            isRunning = false
            closeStreamsAndSocket()
            emitDisconnectedEventOnce()
        }

        private fun closeStreamsAndSocket() {
            try {
                inputStream?.close()
            } catch (ignored: Exception) {}
            try {
                outputStream?.close()
            } catch (ignored: Exception) {}
            try {
                socket.close()
            } catch (e: IOException) {
                Log.e(TAG, "Error closing RFCOMM socket for $peerAddress: ${e.message}")
            }
        }
    }
}
