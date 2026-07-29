package com.example.touchpad

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.io.BufferedReader
import java.io.InputStream
import java.io.OutputStream
import java.net.*

class MainActivity : ComponentActivity() {
    private var socket: Socket? = null
    private var outputStream: OutputStream? = null
    private val scope = MainScope()
    private val sendChannel = Channel<String>(capacity = Channel.UNLIMITED)
    private var isLocked = false
    private var syncJob: Job? = null
    private var isDeviceOwner = false
    private lateinit var dpm: DevicePolicyManager
    private lateinit var adminName: ComponentName
    private var drawingPadView: DrawingPadView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        adminName = ComponentName(this, MyDeviceAdminReceiver::class.java)
        isDeviceOwner = dpm.isDeviceOwnerApp(packageName)

        window.setFlags(
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        )

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (isLocked) println("[Android] 已锁定，拦截返回键")
                else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })

        scope.launch(Dispatchers.IO) {
            while (true) {
                try {
                    connectToMac()
                    if (syncJob == null || !syncJob!!.isActive) startSyncPolling()
                    for (msg in sendChannel) {
                        try {
                            if (outputStream != null) {
                                outputStream!!.write(msg.toByteArray())
                                outputStream!!.flush()
                            } else {
                                break
                            }
                        } catch (_: Exception) {
                            socket = null; outputStream = null; break
                        }
                    }
                } catch (_: Exception) {}
                delay(1000)
            }
        }

        setContent {
            Box(modifier = Modifier.fillMaxSize()) {
                AndroidView(
                    factory = { context ->
                        DrawingPadView(context).apply {
                            drawingPadView = this
                            // 原有指令回调
                            onCommandSent = { action: String, tool: String, x: Int, y: Int ->
                                sendChannel.trySend("$action,$tool,$x,$y\n")
                            }
                            // 新增手势指令回调
                            onGestureCommand = { type: String, dx: Float, dy: Float ->
                                // 格式: GESTURE,type,dx,dy
                                // 保留两位小数避免过长
                                sendChannel.trySend("GESTURE,$type,${"%.2f".format(dx)},${"%.2f".format(dy)}\n")
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (isLocked) {
            isLocked = false
            scope.launch { delay(500); requestSync() }
        }
    }

    private fun requestSync() { sendChannel.trySend("SYNC_REQ\n") }

    private fun startSyncPolling() {
        syncJob = scope.launch(Dispatchers.IO) {
            while (true) {
                if (outputStream != null) sendChannel.trySend("SYNC_REQ\n")
                delay(1000)
            }
        }
    }

    private suspend fun connectToMac() {
        if (socket != null && socket!!.isConnected && outputStream != null) return
        try {
            val usbSocket = Socket()
            usbSocket.tcpNoDelay = true
            usbSocket.soTimeout = 5000
            try {
                usbSocket.connect(InetSocketAddress("127.0.0.1", 9527), 500)
                socket = usbSocket
                outputStream = socket!!.getOutputStream()
                println("[Android] USB 连接成功")
                initializeConnection(socket!!.getInputStream())
            } catch (e: Exception) {
                usbSocket.close()
                println("[Android] USB 连接失败: ${e.message}")
            }
        } catch (_: Exception) {}
    }

    private fun initializeConnection(inputStream: InputStream) {
        sendIdentity()
        Thread { startCommandListener(inputStream) }.start()
    }

    private fun sendIdentity() {
        try {
            val deviceName = Settings.Secure.getString(contentResolver, "bluetooth_name") ?: Build.MODEL
            outputStream?.write("IDENT,$deviceName\n".toByteArray(Charsets.UTF_8))
            outputStream?.flush()
        } catch (_: Exception) {}
    }

    private fun startCommandListener(inputStream: InputStream) {
        try {
            val reader = BufferedReader(inputStream.reader())
            while (true) {
                val line = reader.readLine() ?: break
                when {
                    line == "CMD_LOCK" -> runOnUiThread { enableLockMode() }
                    line == "CMD_UNLOCK" -> runOnUiThread { disableLockMode() }
                    // 新增手势开关
                    line == "CMD_GESTURE_ON" -> runOnUiThread { drawingPadView?.setGestureMode(true) }
                    line == "CMD_GESTURE_OFF" -> runOnUiThread { drawingPadView?.setGestureMode(false) }
                    line.startsWith("SYNC_RESP:") -> {
                        val state = line.split(":").getOrNull(1)
                        if (state == "LOCKED") runOnUiThread { enableLockMode() }
                        else runOnUiThread { disableLockMode() }
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun enableLockMode() {
        if (isLocked) return
        isLocked = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                            View.SYSTEM_UI_FLAG_FULLSCREEN or
                            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    )
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                if (isDeviceOwner) {
                    dpm.setLockTaskFeatures(adminName, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
                }
            }
            startLockTask()
        } catch (e: Exception) { println("[Android] Lock Error: ${e.message}") }
    }

    private fun disableLockMode() {
        if (!isLocked) return
        isLocked = false
        try { stopLockTask() } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_DEFAULT
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        try { outputStream?.close(); socket?.close() } catch (_: Exception) {}
    }
}
