package org.omnilink.transport

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Android Native Bluetooth RFCOMM Stream Socket Transport for OMNILINK.
 * Provides a location-free, Wi-Fi-free direct 1-to-1 fallback transport for bonded devices.
 * Uses a fixed UUID service record with 4-byte big-endian length prefix framing.
 */
class BluetoothRfcommTransport(private val context: Context) {

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
        OmnilinkTransportPlugin.sendEvent(
            mapOf(
                "type" to "rfcommDisconnected",
                "peerId" to deviceAddress,
                "eventType" to "onDisconnected"
            )
        )
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
                "endpointName" to socket.remoteDevice.name
            )
        )
    }

    /**
     * Server Thread listening for incoming Bluetooth RFCOMM socket connections.
     */
    private inner class AcceptThread : Thread() {
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
            var shouldLoop = true
            while (shouldLoop) {
                val socket: BluetoothSocket? = try {
                    serverSocket?.accept()
                } catch (e: IOException) {
                    Log.d(TAG, "AcceptThread socket accept stopped.")
                    shouldLoop = false
                    null
                }

                socket?.let {
                    manageSocket(it, it.remoteDevice.address)
                }
            }
        }

        fun cancel() {
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
            bluetoothAdapter?.cancelDiscovery()
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
        private val inputStream: DataInputStream? = try {
            DataInputStream(socket.inputStream)
        } catch (e: IOException) { null }

        private val outputStream: DataOutputStream? = try {
            DataOutputStream(socket.outputStream)
        } catch (e: IOException) { null }

        override fun run() {
            val input = inputStream ?: return
            while (true) {
                try {
                    // Read 4-byte big-endian packet length prefix header
                    val packetLength = input.readInt()
                    if (packetLength <= 0 || packetLength > 5 * 1024 * 1024) {
                        Log.e(TAG, "Invalid RFCOMM packet length: $packetLength")
                        break
                    }

                    val buffer = ByteArray(packetLength)
                    input.readFully(buffer)

                    Log.d(TAG, "RFCOMM payload received from $peerAddress ($packetLength bytes)")

                    // Emit event to Dart EventChannel (matches TransportAdapter incomingPacket contract)
                    OmnilinkTransportPlugin.sendEvent(
                        mapOf(
                            "type" to "incomingPacket",
                            "peerId" to peerAddress,
                            "bytes" to buffer
                        )
                    )
                } catch (e: IOException) {
                    Log.i(TAG, "RFCOMM connection closed for $peerAddress")
                    break
                }
            }

            activeConnections.remove(peerAddress)
            OmnilinkTransportPlugin.sendEvent(
                mapOf(
                    "type" to "rfcommDisconnected",
                    "peerId" to peerAddress,
                    "eventType" to "onDisconnected"
                )
            )
        }

        fun write(bytes: ByteArray): Boolean {
            val output = outputStream ?: return false
            return try {
                synchronized(output) {
                    // Write 4-byte length prefix header followed by raw payload bytes
                    output.writeInt(bytes.size)
                    output.write(bytes)
                    output.flush()
                }
                Log.d(TAG, "RFCOMM packet sent to $peerAddress (${bytes.size} bytes)")
                true
            } catch (e: IOException) {
                Log.e(TAG, "Error writing RFCOMM packet to $peerAddress: ${e.message}")
                false
            }
        }

        fun cancel() {
            try {
                socket.close()
            } catch (e: IOException) {
                Log.e(TAG, "Error closing RFCOMM socket: ${e.message}")
            }
        }
    }
}
