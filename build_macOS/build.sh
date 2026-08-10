#!/bin/bash

# 配置变量
APP_NAME="TouchPad"
EXECUTABLE_NAME="TouchPad" # swift build 生成的二进制文件名
ADB_SOURCE="./adb"
ICON_SOURCE="./icon.png"

echo "开始构建 $APP_NAME..."

# 1. 编译项目
echo "正在编译..."
swift build -c release
if [ $? -ne 0 ]; then
    echo "编译失败"
    exit 1
fi

# 2. 定义 App 包结构路径
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 3. 清理旧的构建
rm -rf "$APP_BUNDLE"

# 4. 创建目录结构
echo "创建应用包结构..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 5. 复制主程序二进制文件
cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$APP_NAME"
if [ $? -ne 0 ]; then
    echo "复制二进制文件失败"
    exit 1
fi

# 6. 嵌入 ADB 并处理权限
echo "嵌入 ADB 工具..."
    if [ -f "$ADB_SOURCE" ]; then
        cp "$ADB_SOURCE" "$RESOURCES_DIR/adb"
        
        # A. 赋予可执行权限 (必需)
        chmod +x "$RESOURCES_DIR/adb"
        
        # B. 移除 macOS 隔离属性
        xattr -cr "$RESOURCES_DIR/adb"
        
        # C. 【修复关键】移除原有签名并进行 Ad-hoc 重签名
        # 如果不签名，macOS 会直接杀死进程
        codesign --remove-signature "$RESOURCES_DIR/adb" 2>/dev/null
        codesign -s - "$RESOURCES_DIR/adb"
        
        echo "ADB 已嵌入并签名"
    else
        echo "警告: 未在当前目录找到 adb 文件，跳过嵌入。"
    fi

# 7. 处理图标 (PNG 转 ICNS)
echo "处理图标..."
if [ -f "$ICON_SOURCE" ]; then
    # 创建临时 iconset 目录
    ICONSET_DIR="AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    
    # 使用 sips 工具生成不同尺寸的图标
    sips -z 16 16     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png"
    sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png"
    sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png"
    sips -z 64 64     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png"
    sips -z 128 128   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png"
    sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png"
    sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png"
    sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png"
    sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png"
    sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png"
    
    # 转换为 icns
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    
    # 清理临时目录
    rm -rf "$ICONSET_DIR"
else
    echo "警告: 未找到 icon.png，跳过图标生成。"
fi

# 8. 创建 Info.plist
echo "生成 Info.plist..."
# 定义版本号
VERSION="0.1.1"
BUILD_NUMBER="2"

cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.touchpad</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2024 User. All rights reserved.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>This app requires access to control other applications.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>需要屏幕录制权限以进行屏幕镜像。</string>
</dict>
</plist>
EOF

# 9. 签名应用 (必需)
echo "正在签名应用..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "构建成功: $APP_BUNDLE"
echo "您可以双击运行，或拖拽到应用程序文件夹。"
