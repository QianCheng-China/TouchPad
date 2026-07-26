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
                            } else { break }
                        } catch (_: Exception) { socket = null; outputStream = null; break }
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
                            onCommandSent = { action: String, tool: String, x: Int, y: Int ->
                                sendChannel.trySend("$action,$tool,$x,$y\n")
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
        // 【关键修复】如果当前逻辑上是锁定态，强制重置状态。
        // 这解决了用户手动上滑退出后，无法自动重新锁定的问题。
        if (isLocked) {
            isLocked = false
            // 延迟一会让同步机制重新触发锁定
            scope.launch {
                delay(500)
                requestSync()
            }
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
                usbSocket.connect(InetSocketAddress("127.0.0.1", 9527), 500)
                socket = usbSocket
                outputStream = socket!!.getOutputStream()
                println("[Android] USB 连接成功")
                initializeConnection(socket!!.getInputStream())
                return
            } catch (_: Exception) { usbSocket.close() }

            val serverIp = discoverServerIp()
            if (serverIp != null) {
                try {
                    val wifiSocket = Socket()
                    wifiSocket.tcpNoDelay = true
                    wifiSocket.soTimeout = 5000
                    wifiSocket.connect(InetSocketAddress(serverIp, 9527), 1000)
                    socket = wifiSocket
                    outputStream = socket!!.getOutputStream()
                    println("[Android] WiFi 连接成功: $serverIp")
                    initializeConnection(socket!!.getInputStream())
                } catch (_: Exception) { socket = null; outputStream = null }
            } else { socket = null; outputStream = null }
        } catch (_: Exception) { socket = null; outputStream = null }
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
        // 【关键修复】如果已经锁定，直接返回，防止重复调用 startLockTask 导致弹窗
        if (isLocked) return

        isLocked = true
        println("[Android] 进入锁定模式")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN
                            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    )
        }

        try {
            if (isDeviceOwner) {
                dpm.setLockTaskFeatures(adminName, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
            }
            startLockTask()
        } catch (e: Exception) { println("[Android] Lock Error: ${e.message}") }
    }

    private fun disableLockMode() {
        if (!isLocked) return
        isLocked = false
        println("[Android] 退出锁定模式")

        try { stopLockTask() } catch (_: Exception) {}

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            window.insetsController?.systemBarsBehavior = WindowInsetsController.BEHAVIOR_DEFAULT
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    private fun discoverServerIp(): String? {
        val socket = DatagramSocket()
        socket.broadcast = true
        socket.soTimeout = 2000
        return try {
            socket.send(DatagramPacket("TABLET_DISCOVER".toByteArray(), 18, InetAddress.getByName("255.255.255.255"), 9528))
            val receiveData = ByteArray(1024)
            val receivePacket = DatagramPacket(receiveData, receiveData.size)
            socket.receive(receivePacket)
            if (String(receivePacket.data, 0, receivePacket.length) == "TABLET_SERVER_ACK") receivePacket.address.hostAddress
            else null
        } catch (_: Exception) { null }
        finally { socket.close() }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        try { outputStream?.close(); socket?.close() } catch (_: Exception) {}
    }
}
