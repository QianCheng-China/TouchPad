package com.example.touchpad

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface

class DecoderRenderer(private val surface: Surface) {
    private var decoder: MediaCodec? = null
    private var width = 1280
    private var height = 800

    fun start() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        // 实际项目中需设置 csd-0/csd-1 (SPS/PPS)
        // 这里为了简化，假设编码器已经处理好了或解码器能自愈
        decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        decoder?.configure(format, surface, null, 0)
        decoder?.start()
    }

    fun decode(data: ByteArray) {
        val decoderInstance = decoder ?: return
        val inputBufferIndex = decoderInstance.dequeueInputBuffer(10000)
        if (inputBufferIndex >= 0) {
            val inputBuffer = decoderInstance.getInputBuffer(inputBufferIndex)
            inputBuffer?.clear()
            inputBuffer?.put(data)
            decoderInstance.queueInputBuffer(inputBufferIndex, 0, data.size, System.nanoTime() / 1000, 0)
        }

        // 处理输出
        val bufferInfo = MediaCodec.BufferInfo()
        val outputIndex = decoderInstance.dequeueOutputBuffer(bufferInfo, 10000)
        if (outputIndex >= 0) {
            // 渲染到 Surface
            decoderInstance.releaseOutputBuffer(outputIndex, true)
        }
    }

    fun stop() {
        decoder?.stop()
        decoder?.release()
        decoder = null
    }
}
