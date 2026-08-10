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
            Log.w("NetworkReceiver", "Already running, forcing restart")
            disconnect()
        }
        isRunning = true

        job = CoroutineScope(Dispatchers.IO).launch {
            var attempts = 0
            var connected = false

            // 【修改】加快重试速度，捕捉瞬态连接失败
            while (isRunning && attempts < 10) {
                try {
                    Log.d("NetworkReceiver", "Connecting to ${Constants.HOST}:${Constants.VIDEO_PORT} (Attempt ${attempts + 1})")

                    socket?.close()
                    socket = null

                    socket = Socket(Constants.HOST, Constants.VIDEO_PORT)
                    socket?.soTimeout = 5000

                    connected = true
                    Log.d("NetworkReceiver", "Connected successfully!")
                    break
                } catch (e: Exception) {
                    attempts++
                    socket?.close()
                    socket = null

                    if (isRunning && attempts < 10) {
                        Log.w("NetworkReceiver", "Connection failed: ${e.message}. Retrying in 100ms...")
                        delay(100) // 缩短延迟至 100ms
                    } else {
                        Log.e("NetworkReceiver", "Failed to connect after $attempts attempts")
                    }
                }
            }

            if (!connected) {
                disconnect()
                return@launch
            }

            try {
                val input = socket!!.getInputStream()
                while (isRunning) {
                    val packet = readPacket(input)
                    if (packet != null) {
                        onFrameReceived(packet)
                    } else {
                        Log.w("NetworkReceiver", "readPacket returned null (EOF or Error)")
                        break
                    }
                }
            } catch (e: Exception) {
                Log.e("NetworkReceiver", "Connection error: ${e.message}")
            } finally {
                disconnect()
            }
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray, len: Int): Boolean {
        var readTotal = 0
        while (readTotal < len) {
            val r = input.read(buf, readTotal, len - readTotal)
            if (r == -1) return false
            readTotal += r
        }
        return true
    }

    private fun readPacket(input: InputStream): ByteArray? {
        try {
            val type = input.read()
            if (type == -1) return null

            val lengthBytes = ByteArray(4)
            if (!readFully(input, lengthBytes, 4)) return null

            val length = ByteBuffer.wrap(lengthBytes).order(ByteOrder.BIG_ENDIAN).int
            if (length <= 0 || length > Constants.BUFFER_SIZE * 10) {
                Log.e("NetworkReceiver", "readPacket: Invalid packet length: $length")
                return null
            }

            val payload = ByteArray(length)
            if (!readFully(input, payload, length)) return null
            return payload
        } catch (e: Exception) {
            return null
        }
    }

    fun disconnect() {
        Log.d("NetworkReceiver", "Disconnecting...")
        isRunning = false
        try {
            socket?.close()
        } catch (_: Exception) {}
        socket = null
        job?.cancel()
        job = null
    }
}
