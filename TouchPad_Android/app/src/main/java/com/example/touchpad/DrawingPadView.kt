package com.example.touchpad

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.Log
import android.view.MotionEvent
import android.view.View

class DrawingPadView(context: Context) : View(context) {
    private val gridPaint = Paint()
    private val gridSize = 80f
    var onCommandSent: ((action: String, tool: String, x: Int, y: Int) -> Unit)? = null

    init {
        gridPaint.color = Color.parseColor("#EEEEEE")
        gridPaint.strokeWidth = 1f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        var x = 0f
        while (x < width) {
            canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint)
            x += gridSize
        }
        var y = 0f
        while (y < height) {
            canvas.drawLine(0f, y, width.toFloat(), y, gridPaint)
            y += gridSize
        }
    }

    private fun getToolType(event: MotionEvent): String {
        return if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) "STYLUS" else "FINGER"
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        handleEvent(event)
        return true
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        handleEvent(event)
        // 必须返回 true 才能持续接收悬停事件
        return true
    }

    private fun handleEvent(event: MotionEvent) {
        val tool = getToolType(event)
        // 仅处理触控笔
        if (tool != "STYLUS") return

        val normX = (event.x / width * 10000f).toInt()
        val normY = (event.y / height * 10000f).toInt()

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                onCommandSent?.invoke("DOWN", tool, normX, normY)
            }
            MotionEvent.ACTION_MOVE -> {
                // 发送历史位置以保证平滑
                val historySize = event.historySize
                for (i in 0 until historySize) {
                    val histX = (event.getHistoricalX(i) / width * 10000f).toInt()
                    val histY = (event.getHistoricalY(i) / height * 10000f).toInt()
                    onCommandSent?.invoke("MOVE", tool, histX, histY)
                }
                onCommandSent?.invoke("MOVE", tool, normX, normY)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                onCommandSent?.invoke("UP", tool, normX, normY)
            }

            // 关键：处理 HOVER_ENTER 和 HOVER_MOVE
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> {
                // 发送历史位置
                val historySize = event.historySize
                for (i in 0 until historySize) {
                    val histX = (event.getHistoricalX(i) / width * 10000f).toInt()
                    val histY = (event.getHistoricalY(i) / height * 10000f).toInt()
                    onCommandSent?.invoke("HOVER", tool, histX, histY)
                }

                // 发送当前位置
                onCommandSent?.invoke("HOVER", tool, normX, normY)
            }
        }
    }
}
