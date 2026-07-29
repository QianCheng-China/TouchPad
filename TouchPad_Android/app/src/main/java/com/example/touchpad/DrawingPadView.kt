package com.example.touchpad

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import kotlin.math.abs

class DrawingPadView(context: Context) : View(context) {
    private val gridPaint = Paint()
    private val gridSize = 80f
    var onCommandSent: ((action: String, tool: String, x: Int, y: Int) -> Unit)? = null
    var onGestureCommand: ((type: String, dx: Float, dy: Float) -> Unit)? = null

    private var gestureMode = false
    private var lastFingerX = 0f
    private var lastFingerY = 0f
    private var isGestureActive = false
    private var isZooming = false

    private val scaleDetector: ScaleGestureDetector by lazy {
        ScaleGestureDetector(context, ScaleListener())
    }

    init {
        gridPaint.color = Color.parseColor("#EEEEEE")
        gridPaint.strokeWidth = 1f
    }

    fun setGestureMode(enabled: Boolean) {
        gestureMode = enabled
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        var x = 0f
        while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint); x += gridSize }
        var y = 0f
        while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, gridPaint); y += gridSize }
    }

    private fun getToolType(event: MotionEvent): String {
        return if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) "STYLUS" else "FINGER"
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val tool = getToolType(event)
        if (tool == "STYLUS") {
            handleStylusEvent(event)
            return true
        }

        if (gestureMode) {
            scaleDetector.onTouchEvent(event)
            handleFingerGesture(event)
            return true
        } else {
            handleStylusEvent(event)
            return true
        }
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        handleStylusEvent(event)
        return true
    }

    private fun handleStylusEvent(event: MotionEvent) {
        val tool = getToolType(event)
        val normX = (event.x / width * 10000f).toInt()
        val normY = (event.y / height * 10000f).toInt()

        when (event.action) {
            MotionEvent.ACTION_DOWN -> onCommandSent?.invoke("DOWN", tool, normX, normY)
            MotionEvent.ACTION_MOVE -> {
                val historySize = event.historySize
                for (i in 0 until historySize) {
                    val histX = (event.getHistoricalX(i) / width * 10000f).toInt()
                    val histY = (event.getHistoricalY(i) / height * 10000f).toInt()
                    onCommandSent?.invoke("MOVE", tool, histX, histY)
                }
                onCommandSent?.invoke("MOVE", tool, normX, normY)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> onCommandSent?.invoke("UP", tool, normX, normY)
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> {
                val historySize = event.historySize
                for (i in 0 until historySize) {
                    val histX = (event.getHistoricalX(i) / width * 10000f).toInt()
                    val histY = (event.getHistoricalY(i) / height * 10000f).toInt()
                    onCommandSent?.invoke("HOVER", tool, histX, histY)
                }
                onCommandSent?.invoke("HOVER", tool, normX, normY)
            }
        }
    }

    private fun handleFingerGesture(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastFingerX = event.x
                lastFingerY = event.y
                isGestureActive = true
                isZooming = false
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                isZooming = true
                lastFingerX = event.x
                lastFingerY = event.y
            }
            MotionEvent.ACTION_MOVE -> {
                // 【关键修复】如果手指数量<=1，强制禁止进入缩放逻辑
                if (event.pointerCount <= 1) {
                    isZooming = false
                }

                // 如果是缩放模式，直接返回，不再处理滚动
                if (isZooming) return

                if (!scaleDetector.isInProgress && isGestureActive) {
                    val dx = event.x - lastFingerX
                    val dy = event.y - lastFingerY
                    if (abs(dx) > 2 || abs(dy) > 2) {
                        onGestureCommand?.invoke("SCROLL", dx * 1.5f, dy * 1.5f)
                    }
                }
                lastFingerX = event.x
                lastFingerY = event.y
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                isGestureActive = false
                isZooming = false
            }
        }
    }

    private inner class ScaleListener : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            isZooming = true
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val factor = detector.scaleFactor
            // 只有当确实有两个手指时才发送指令
            if (detector.currentSpan > 0 && factor != 1.0f) {
                onGestureCommand?.invoke("ZOOM", factor, 0f)
            }
            return true
        }
        override fun onScaleEnd(detector: ScaleGestureDetector) {}
    }
}
