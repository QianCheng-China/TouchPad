package com.example.touchpad

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue

class DecoderRenderer(private val surface: Surface) {
    private var decoder: MediaCodec? = null
    private var isConfigured = false
    private var width = 0
    private var height = 0
    var onVideoSizeChanged: ((Int, Int) -> Unit)? = null

    private val pendingPackets = ConcurrentLinkedQueue<ByteArray>()

    fun start() {
        try {
            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            Log.d("Decoder", "Decoder created.")
        } catch (e: Exception) {
            Log.e("Decoder", "Failed to create decoder", e)
        }
    }

    fun decode(data: ByteArray) {
        if (!isConfigured) {
            // 扫描原始数据，提取 SPS/PPS 字节用于配置解码器
            scanAndCacheConfig(data)

            // 只有当 SPS 和 PPS 都准备好时才配置
            if (spsBuffer != null && ppsBuffer != null) {
                configureDecoder()
            }

            pendingPackets.add(data)
            return
        }

        while (pendingPackets.isNotEmpty()) {
            val pending = pendingPackets.poll()
            feedToDecoder(pending)
        }

        feedToDecoder(data)
    }

    private fun feedToDecoder(data: ByteArray) {
        try {
            val decoderInstance = decoder ?: return
            val inputIndex = decoderInstance.dequeueInputBuffer(10000)
            if (inputIndex >= 0) {
                val inputBuffer = decoderInstance.getInputBuffer(inputIndex)
                inputBuffer?.clear()
                inputBuffer?.put(data)
                decoderInstance.queueInputBuffer(inputIndex, 0, data.size, System.nanoTime() / 1000, 0)
            }

            val bufferInfo = MediaCodec.BufferInfo()
            var outputIndex = decoderInstance.dequeueOutputBuffer(bufferInfo, 10000)

            while (outputIndex >= 0 || outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED || outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val newFormat = decoderInstance.outputFormat
                    val w = newFormat.getInteger(MediaFormat.KEY_WIDTH)
                    val h = newFormat.getInteger(MediaFormat.KEY_HEIGHT)

                    // 仅更新硬件解码器确认的尺寸
                    if (w > 100 && h > 100) {
                        Log.d("Decoder", "Output format changed event: ${w}x${h}")
                        width = w
                        height = h
                        onVideoSizeChanged?.invoke(w, h)
                    }
                } else if (outputIndex >= 0) {
                    decoderInstance.releaseOutputBuffer(outputIndex, true)
                } else if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    break
                }

                outputIndex = decoderInstance.dequeueOutputBuffer(bufferInfo, 0)
            }
        } catch (e: Exception) {
            Log.e("Decoder", "Decode error", e)
        }
    }

    private var spsBuffer: ByteArray? = null
    private var ppsBuffer: ByteArray? = null

    private fun scanAndCacheConfig(data: ByteArray) {
        var i = 0
        while (i < data.size - 3) {
            // 查找 00 00 00 01 起始码
            if (data[i] == 0.toByte() && data[i+1] == 0.toByte() && data[i+2] == 0.toByte() && data[i+3] == 1.toByte()) {
                val start = i
                var end = start + 4
                while (end < data.size - 3) {
                    if (data[end] == 0.toByte() && data[end+1] == 0.toByte() && data[end+2] == 0.toByte() && data[end+3] == 1.toByte()) break
                    end++
                }
                if (end >= data.size) end = data.size

                if (start + 4 < data.size) {
                    val nalType = data[start + 4].toInt() and 0x1F
                    // SPS = 7, PPS = 8
                    if (nalType == 7 && spsBuffer == null) {
                        spsBuffer = data.copyOfRange(start + 4, end)
                        Log.d("Decoder", "SPS found (Raw size: ${spsBuffer!!.size})")
                    } else if (nalType == 8 && ppsBuffer == null) {
                        ppsBuffer = data.copyOfRange(start + 4, end)
                        Log.d("Decoder", "PPS found (Raw size: ${ppsBuffer!!.size})")
                    }
                }
                i = end
            } else {
                i++
            }
        }
    }

    private fun configureDecoder() {
        try {
            val decoderInstance = decoder ?: return

            // 1. 传入占位尺寸 (1920x1080)，防止报错
            // 2. 传入 SPS/PPS 原始字节，帮助解码器快速初始化
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080)

            spsBuffer?.let { format.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
            ppsBuffer?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }

            decoderInstance.configure(format, surface, null, 0)
            decoderInstance.start()
            isConfigured = true

            Log.d("Decoder", "Decoder started with CSD headers.")

            // 注意：这里不再手动解析尺寸，也不提前查询 outputFormat
            // 等待硬件解码器的 INFO_OUTPUT_FORMAT_CHANGED 事件

        } catch (e: Exception) {
            Log.e("Decoder", "Config error", e)
        }
    }

    fun stop() {
        try {
            if (isConfigured) decoder?.stop()
            decoder?.release()
        } catch (e: Exception) {
            Log.e("Decoder", "Stop error", e)
        }
        decoder = null
        isConfigured = false
        pendingPackets.clear()
    }
}
