
# TouchPad

将你的 Android 平板变成 Mac 绘图板

Turn your Android tablet into a Mac graphics tablet, just like an iPad.

## 特性

TouchPad 是一套轻量级、跨平台的数位板解决方案，相较于同类产品有明显优势。

- 安全：通过USB隧道连接，不上传任何数据到Internet。源代码开放，可随时对其进行审计。
- 低延迟：通过 USB 隧道直连，延迟极低，适合绘图与手写。
- 轻量：资源占用少，ADB软件包随附，无需繁杂配置。
- 悬停：触笔悬停在平板上方时即可了解笔尖对准的位置。
- 锁定屏幕：去除状态栏并防止在绘制时无意退出TouchPad。
- 触控板手势：将Android平板作为Mac的触控板使用，接近原生体验。
- 屏幕镜像：将Mac屏幕镜像到平板，就像Apple连续互通的“随航”一般。

## 兼容

TouchPad具有广泛的兼容性。

#### Mac

macOS 11.0/Big Sur及更新版本。支持Intel芯片和Apple芯片。

#### Android

Android 10.0 /API 29及更新版本。

## 安装

通过一下几个步骤快速安装TouchPad并使其就绪。

#### Mac

1. 将下载的TouchPad.app文件拖入“应用程序”文件夹；
2. 授予“辅助功能”权限，以允许TouchPad控制光标。如果你需要使用“屏幕镜像”功能，请授予“录屏与系统录音”权限。

#### Android

1. 下载 TouchPad.apk并安装；
2. 在Android平板上开启“开发者选项”，并打开“USB调试”。
3. 连接Android平板与Mac，并在TouchPad菜单栏中的“设备列表”中轻点“扫描新设备”并连接你的设备。

#### 需要注意

- 使用数据线连接Android平板与 Mac 而非仅充电线。
- 由于Android限制，在某些设备上，“锁定屏幕”无法屏蔽上滑返回桌面手势。除非获取设备所有权。如果你需要，请按以下方法操作：

在 Mac 上打开终端，执行以下命令授权：

```Shell
adb shell dpm set-device-owner com.example.touchpad/.MyDeviceAdminReceiver
```

当提示 "Success: set active admin" 时，表示授权成功。此后点击“锁定”，应用将进入强力锁定模式，无法通过手势退出，只能通过Mac 端解锁。此后，如果你需要卸载Android平板上的TouchPad，需要先使用如下命令解除该权限，否则可能无法卸载。

```Shell
adb shell dpm remove-active-admin com.example.touchpad/.MyDeviceAdminReceiver
```

## 快速指南

* 使用“输入模式”菜单来选择仅接收主动式触控笔的输入还是同时接收手指的触摸输入；
* 使用“将手指输入作为触控板”来将Android平板作为Mac的触控板使用，接近macOS原生体验；
  *由于macOS限制，原生缩放在一些macOS上不可用。你可根据当前使用的App选择不同的缩放模式。
  **选项“将手指输入作为触控板”不可与“屏幕镜像”同时启用。
  ***你可以调整TouchPad对于手势识别的灵敏度，同时自行决定启用哪些手势。
* 使用“屏幕镜像”将Mac屏幕投射到Android平板上以便更好定位落笔位置；
  *当Mac分辨率与Android平板分辨率相差过大时，“屏幕镜像”可能不会正常工作。此时请利用“悬停”功能定位落笔位置。
* 使用“锁定屏幕”防止在绘制时无意间退出TouchPad。
