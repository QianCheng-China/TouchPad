package com.example.touchpad

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View

class DrawingPadView(context: Context) : View(context) {
    private val gridPaint = Paint()
    var onCommandSent: ((cmd: String) -> Unit)? = null
    private var isTrackpadMode = false
    private var isMirroring = false

    init {
        gridPaint.color = Color.parseColor("#EEEEEE")
        gridPaint.strokeWidth = 1f
        isFocusable = true
        isFocusableInTouchMode = true
        // 【关键修复】设置背景为透明，确保视频层可见
        setBackgroundColor(Color.TRANSPARENT)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
    }

    fun setTrackpadMode(enabled: Boolean) {
        isTrackpadMode = enabled
    }

    fun setMirrorMode(enabled: Boolean) {
        isMirroring = enabled
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // 只有在非镜像模式下才绘制网格
        if (!isMirroring) {
            var x = 0f
            while (x < width) {
                canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint)
                x += 80f
            }
            var y = 0f
            while (y < height) {
                canvas.drawLine(0f, y, width.toFloat(), y, gridPaint)
                y += 80f
            }
        }
    }

    // ... (onTouchEvent, onHoverEvent, handleStylus, handleMultiTouch 保持原样) ...
    // 为了节省篇幅，这里省略未修改的触摸处理代码，请保留原文件中的实现
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
            handleStylus(event)
            return true
        }
        if (isTrackpadMode) {
            handleMultiTouch(event)
            return true
        }
        return false
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
            handleStylus(event)
        }
        return true
    }

    private fun handleStylus(event: MotionEvent) {
        val normX = (event.x / width * 10000f).toInt()
        val normY = (event.y / height * 10000f).toInt()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> onCommandSent?.invoke("PEN_DOWN,$normX,$normY")
            MotionEvent.ACTION_MOVE -> onCommandSent?.invoke("PEN_MOVE,$normX,$normY")
            MotionEvent.ACTION_UP -> onCommandSent?.invoke("PEN_UP,$normX,$normY")
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> onCommandSent?.invoke("PEN_HOVER,$normX,$normY")
            MotionEvent.ACTION_HOVER_EXIT -> onCommandSent?.invoke("PEN_HOVER,$normX,$normY")
        }
    }

    private fun handleMultiTouch(event: MotionEvent) {
        if (event.pointerCount > 4) return
        val count = event.pointerCount
        val sb = StringBuilder("TOUCH,$count")
        for (i in 0 until count) {
            val id = event.getPointerId(i)
            val x = (event.getX(i) / width * 10000f).toInt()
            val y = (event.getY(i) / height * 10000f).toInt()
            sb.append(",$id,$x,$y")
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> onCommandSent?.invoke(sb.toString())
        }
    }
}
