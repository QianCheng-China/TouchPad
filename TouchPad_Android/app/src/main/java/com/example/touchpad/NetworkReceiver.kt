package com.example.touchpad

import android.util.Log
import kotlinx.coroutines.*
import java.io.InputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

class NetworkReceiver(private val onFrameReceived: (ByteArray) -> Unit) {
    private var job: Job? = null
    private var socket: Socket? = null
    private var isRunning = false

    fun connect() {
        if (isRunning) {
            Log.w("NetworkReceiver", "Already running")
            return
        }
        isRunning = true
        job = CoroutineScope(Dispatchers.IO).launch {
            try {
                Log.d("NetworkReceiver", "Connecting to ${Constants.HOST}:${Constants.VIDEO_PORT}")
                socket = Socket(Constants.HOST, Constants.VIDEO_PORT)

                // 【关键修复】设置超时时间，避免永久阻塞
                socket?.soTimeout = 5000

                val input = socket!!.getInputStream()
                Log.d("NetworkReceiver", "Connected successfully!")

                while (isRunning) {
                    val packet = readPacket(input)
                    if (packet != null) {
                        Log.d("NetworkReceiver", "Received packet size: ${packet.size}")
                        onFrameReceived(packet)
                    } else {
                        Log.w("NetworkReceiver", "readPacket returned null (EOF or Error)")
                        break
                    }
                }
            } catch (e: Exception) {
                Log.e("NetworkReceiver", "Connection error: ${e.message}", e)
                e.printStackTrace()
            } finally {
                disconnect()
            }
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray, offset: Int, len: Int): Boolean {
        var readTotal = 0
        while (readTotal < len) {
            val r = input.read(buf, offset + readTotal, len - readTotal)
            if (r == -1) {
                Log.e("NetworkReceiver", "readFully failed: EOF reached (read: $readTotal, expected: $len)")
                return false
            }
            readTotal += r
        }
        return true
    }

    private fun readPacket(input: InputStream): ByteArray? {
        try {
            // Read type (1 byte)
            val type = input.read()
            if (type == -1) {
                Log.e("NetworkReceiver", "readPacket: Type is -1 (EOF)")
                return null
            }

            // Read length (4 bytes big-endian)
            val lengthBytes = ByteArray(4)
            if (!readFully(input, lengthBytes, 0, 4)) {
                Log.e("NetworkReceiver", "readPacket: Failed to read length bytes")
                return null
            }
            val length = ByteBuffer.wrap(lengthBytes).order(ByteOrder.BIG_ENDIAN).int

            if (length <= 0 || length > Constants.BUFFER_SIZE * 10) {
                Log.e("NetworkReceiver", "readPacket: Invalid packet length: $length")
                return null
            }

            // Read payload
            val payload = ByteArray(length)
            if (!readFully(input, payload, 0, length)) {
                Log.e("NetworkReceiver", "readPacket: Failed to read payload bytes (len: $length)")
                return null
            }

            return payload
        } catch (e: Exception) {
            Log.e("NetworkReceiver", "readPacket exception: ${e.message}")
            return null
        }
    }

    fun disconnect() {
        Log.d("NetworkReceiver", "Disconnecting...")
        isRunning = false
        try {
            socket?.close()
        } catch (_: Exception) {}
        job?.cancel()
    }
}
