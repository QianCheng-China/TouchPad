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
        if (isRunning) return
        isRunning = true
        job = CoroutineScope(Dispatchers.IO).launch {
            try {
                socket = Socket(Constants.HOST, Constants.PORT)
                val input = socket!!.getInputStream()
                Log.d("TabletDisplay", "Connected to Mac")

                while (isRunning) {
                    // 读取数据包逻辑
                    val packet = readPacket(input)
                    if (packet != null) {
                        withContext(Dispatchers.Main) {
                            onFrameReceived(packet)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("TabletDisplay", "Connection error", e)
                // 简单重连逻辑可以加在这里
            }
        }
    }

    private fun readPacket(input: InputStream): ByteArray? {
        // 读取类型 (1字节)
        val typeByte = input.read()
        if (typeByte == -1) return null // 连接关闭
        // val type = typeByte.toByte()

        // 读取长度 (4字节)
        val lengthBytes = ByteArray(4)
        input.read(lengthBytes)
        val length = ByteBuffer.wrap(lengthBytes).order(ByteOrder.BIG_ENDIAN).int

        // 读取负载数据
        if (length > Constants.BUFFER_SIZE * 100 || length < 0) return null // 安全检查

        val payload = ByteArray(length)
        var bytesRead = 0
        while (bytesRead < length) {
            val read = input.read(payload, bytesRead, length - bytesRead)
            if (read == -1) return null
            bytesRead += read
        }

        return payload
    }

    fun disconnect() {
        isRunning = false
        socket?.close()
        job?.cancel()
    }
}
