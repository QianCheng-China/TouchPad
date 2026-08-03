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

    init {
        gridPaint.color = Color.parseColor("#EEEEEE")
        gridPaint.strokeWidth = 1f
        // 【修复】确保 View 能接收悬停事件
        isFocusable = true
        isFocusableInTouchMode = true
    }

    // 【修复】View附加到窗口时请求焦点，确保启动时即可接收悬停事件
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestFocus()
    }

    fun setTrackpadMode(enabled: Boolean) {
        isTrackpadMode = enabled
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        var x = 0f
        while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint); x += 80f }
        var y = 0f
        while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, gridPaint); y += 80f }
    }

    // 处理点击和滑动 (触笔接触屏幕时)
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

    // 【修复】处理悬停事件 (触笔靠近屏幕但未接触时)
    // 始终返回 true 保持悬停事件流活跃，避免系统停止投递事件
    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
            handleStylus(event)
        }
        return true
    }

    // 【修复4】添加 onGenericMotionEvent 作为悬停事件的备用接收器
    // 某些 Android 设备会将触笔悬停事件投递到 onGenericMotionEvent 而非 onHoverEvent
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_HOVER_MOVE ||
            action == MotionEvent.ACTION_HOVER_ENTER ||
            action == MotionEvent.ACTION_HOVER_EXIT) {
            if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
                handleStylus(event)
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    private fun handleStylus(event: MotionEvent) {
        val normX = (event.x / width * 10000f).toInt()
        val normY = (event.y / height * 10000f).toInt()

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> onCommandSent?.invoke("PEN_DOWN,$normX,$normY")
            MotionEvent.ACTION_MOVE -> onCommandSent?.invoke("PEN_MOVE,$normX,$normY")
            MotionEvent.ACTION_UP -> onCommandSent?.invoke("PEN_UP,$normX,$normY")
            // 捕获悬停动作 - 光标处于松开状态随触笔移动
            MotionEvent.ACTION_HOVER_ENTER,
            MotionEvent.ACTION_HOVER_MOVE -> onCommandSent?.invoke("PEN_HOVER,$normX,$normY")
            MotionEvent.ACTION_HOVER_EXIT -> {
                // 悬停离开时也发送最后一个位置，确保光标跟随到最终位置
                onCommandSent?.invoke("PEN_HOVER,$normX,$normY")
            }
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
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_POINTER_DOWN,
            MotionEvent.ACTION_MOVE,
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_POINTER_UP,
            MotionEvent.ACTION_CANCEL -> onCommandSent?.invoke(sb.toString())
        }
    }
}
