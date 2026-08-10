package com.example.touchpad

import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
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
import java.net.InetSocketAddress
import java.net.Socket

class MainActivity : ComponentActivity() {
    private var socket: Socket? = null
    private var outputStream: java.io.OutputStream? = null
    private val scope = MainScope()
    private val sendChannel = Channel<String>(capacity = Channel.UNLIMITED)
    private var isLocked = false
    private var syncJob: Job? = null
    private var isDeviceOwner = false
    private lateinit var dpm: android.app.admin.DevicePolicyManager
    private lateinit var adminName: android.content.ComponentName
    private var drawingPadView: DrawingPadView? = null

    // 视频相关
    private var networkReceiver: NetworkReceiver? = null
    private var decoderRenderer: DecoderRenderer? = null
    private var textureView: TextureView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        dpm = getSystemService(android.content.Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
        adminName = android.content.ComponentName(this, MyDeviceAdminReceiver::class.java)
        isDeviceOwner = dpm.isDeviceOwnerApp(packageName)

        window.setFlags(
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        )

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (isLocked) {
                    println("[Android] 已锁定，拦截返回键")
                } else {
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
                        // 核心修复 1：强制 View 占据全屏，忽略纹理大小
                        object : TextureView(context) {
                            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                                val width = MeasureSpec.getSize(widthMeasureSpec)
                                val height = MeasureSpec.getSize(heightMeasureSpec)
                                setMeasuredDimension(width, height)
                            }
                        }.apply {
                            textureView = this
                            visibility = View.GONE
                            Log.d("MainActivity", "TextureView created")
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )
                AndroidView(
                    factory = { context ->
                        DrawingPadView(context).apply {
                            drawingPadView = this
                            onCommandSent = { cmd: String -> sendChannel.trySend("$cmd\n") }
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

    private fun requestSync() {
        sendChannel.trySend("SYNC_REQ\n")
    }

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
                usbSocket.connect(InetSocketAddress("127.0.0.1", Constants.COMMAND_PORT), 500)
                socket = usbSocket
                outputStream = socket!!.getOutputStream()
                Log.d("MainActivity", "USB 连接成功")
                initializeConnection(socket!!.getInputStream())
            } catch (e: Exception) {
                usbSocket.close()
                Log.e("MainActivity", "USB 连接失败: ${e.message}")
            }
        } catch (_: Exception) {}
    }

    @Suppress("SpellCheckingInspection")
    private fun initializeConnection(inputStream: java.io.InputStream) {
        sendIdentity()
        Thread { startCommandListener(inputStream) }.start()
    }

    @Suppress("SpellCheckingInspection")
    private fun sendIdentity() {
        try {
            val deviceName = Settings.Secure.getString(contentResolver, "bluetooth_name") ?: Build.MODEL
            outputStream?.write("IDENT,$deviceName\n".toByteArray(Charsets.UTF_8))
            outputStream?.flush()
        } catch (_: Exception) {}
    }

    private fun startCommandListener(inputStream: java.io.InputStream) {
        try {
            val reader = java.io.BufferedReader(inputStream.reader())
            while (true) {
                val line = reader.readLine() ?: break
                Log.d("MainActivity", "Received cmd: $line")
                when {
                    line == "CMD_LOCK" -> runOnUiThread { enableLockMode() }
                    line == "CMD_UNLOCK" -> runOnUiThread { disableLockMode() }
                    line == "CMD_TRACKPAD_ON" -> runOnUiThread { drawingPadView?.setTrackpadMode(true) }
                    line == "CMD_TRACKPAD_OFF" -> runOnUiThread { drawingPadView?.setTrackpadMode(false) }
                    line == "CMD_MIRROR_ON" -> runOnUiThread { enableMirrorMode() }
                    line == "CMD_MIRROR_OFF" -> runOnUiThread { disableMirrorMode() }
                    line.startsWith("SYNC_RESP:") -> {
                        val state = line.split(":").getOrNull(1)
                        if (state == "LOCKED") runOnUiThread { enableLockMode() }
                        else runOnUiThread { disableLockMode() }
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun enableMirrorMode() {
        Log.d("MainActivity", "enableMirrorMode called")
        if (networkReceiver != null) {
            Log.w("MainActivity", "Mirror already running")
            return
        }
        if (textureView == null) {
            Log.e("MainActivity", "TextureView is null!")
            return
        }
        textureView?.visibility = View.VISIBLE
        drawingPadView?.setMirrorMode(true)

        textureView?.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                Log.d("MainActivity", "TextureView Surface Available")
                startVideoStream(surface)
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
                // 什么都不做，让系统自动处理
            }
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                disableMirrorMode()
                return true
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }

        if (textureView?.isAvailable == true) {
            Log.d("MainActivity", "TextureView is already available, starting stream immediately")
            textureView?.surfaceTexture?.let { startVideoStream(it) }
        }
    }

    private fun startVideoStream(surfaceTexture: SurfaceTexture) {
        val surface = Surface(surfaceTexture)
        decoderRenderer = DecoderRenderer(surface)
        // 核心修复 2：当视频尺寸回调时，设置缓冲区大小
        // 由于我们现在发送的是物理像素 (2560x1600)，View 也是 (2560x1600)
        // 设置相同的尺寸，TextureView 会完美呈现 1:1 画面，不需要 Matrix 变换
        decoderRenderer?.onVideoSizeChanged = { vW, vH ->
            Log.d("MainActivity", "!!!!!! Video size changed: ${vW}x${vH}")
            runOnUiThread {
                textureView?.surfaceTexture?.setDefaultBufferSize(vW, vH)
                // 注意：这里不再调用 updateTextureViewTransform()
                // 不再调用 setTransform()
                // TextureView 默认会把纹理拉伸到 View 大小，两者一致即完美显示
            }
        }
        decoderRenderer?.start()

        networkReceiver = NetworkReceiver(
            onFrameReceived = { data ->
                decoderRenderer?.decode(data)
            },
            onDisconnected = {
                // 【新增】连接断开时，在主线程恢复白屏视图
                runOnUiThread {
                    disableMirrorMode()
                }
            }
        )
        networkReceiver?.connect()
        println("[Android] 屏幕镜像开启")
    }

    private fun disableMirrorMode() {
        networkReceiver?.disconnect()
        networkReceiver = null
        decoderRenderer?.stop()
        decoderRenderer = null
        textureView?.visibility = View.GONE
        drawingPadView?.setMirrorMode(false)
        println("[Android] 屏幕镜像关闭")
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
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                if (isDeviceOwner) dpm.setLockTaskFeatures(adminName, android.app.admin.DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
            }
            startLockTask()
        } catch (e: Exception) {
            println("[Android] Lock Error: ${e.message}")
        }
    }

    private fun disableLockMode() {
        if (!isLocked) return
        isLocked = false
        try {
            stopLockTask()
        } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_DEFAULT
            } else {
                window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        try {
            outputStream?.close(); socket?.close()
        } catch (_: Exception) {}
    }
}
