#!/bin/bash

# ==========================================================
# TouchPad 自动打包脚本 (无需 Xcode IDE)
# 版本: 0.1.0
# ==========================================================

APP_NAME="TouchPad"
VERSION="0.1.0"
BUNDLE_ID="com.example.touchpad"

# 1. 准备目录结构
echo "正在准备打包环境..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# 2. 编译源代码
# -O 优化编译速度
# -module-name 设置模块名
# -emit-executable 输出可执行文件
# -target arm64-apple-macosx11.0 指定架构和最低系统版本 (通用二进制需要更复杂的命令，这里默认编译当前架构)
# -framework 链接必要的系统框架

echo "正在编译 Swift 源代码..."
swiftc -O \
       -module-name ${APP_NAME} \
       -emit-executable \
       -o "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
       *.swift \
       -framework Cocoa \
       -framework ApplicationServices \
       -framework Combine

if [ $? -ne 0 ]; then
    echo "编译失败！请检查源代码错误。"
    exit 1
fi

# 3. 生成 Info.plist (核心配置)
echo "正在生成配置文件 Info.plist..."
cat > "${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <!-- 关键配置：后台运行，无 Dock 图标，无主菜单 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>TouchPad 需要控制鼠标以实现数位板功能。</string>
</dict>
</plist>
EOF

# 4. 处理图标 (如果没图片，生成一个简单的默认图标)
ICON_PATH="${APP_NAME}.app/Contents/Resources/AppIcon.icns"
if [ ! -f "AppIcon.png" ]; then
    echo "未找到 AppIcon.png，正在生成默认图标..."
    # 创建一个 512x512 的纯色 PNG (深灰底，白字 T)
    # 使用 macOS 自带的 sips 工具或 python
    if command -v python3 &> /dev/null; then
        python3 << PYTHON_SCRIPT
from PIL import Image, ImageDraw, ImageFont
try:
    img = Image.new('RGBA', (512, 512), (60, 60, 60, 255))
    draw = ImageDraw.Draw(img)
    # 画一个简单的 T 字
    draw.rectangle([100, 100, 412, 160], fill='white') # 横
    draw.rectangle([230, 160, 282, 412], fill='white') # 竖
    img.save('AppIcon.png')
except ImportError:
    # 如果没有 PIL，创建空白图
    import subprocess
    subprocess.run(['sips', '-s', 'format', 'png', '--resampleWidth', '512', '-o', 'AppIcon.png', '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns'])
PYTHON_SCRIPT
    fi
fi

# 转换 PNG 为 icns (使用系统自带工具)
if [ -f "AppIcon.png" ]; then
    echo "正在转换图标..."
    mkdir -p icon.iconset
    sips -z 16 16     AppIcon.png --out icon.iconset/icon_16x16.png
    sips -z 32 32     AppIcon.png --out icon.iconset/icon_16x16@2x.png
    sips -z 32 32     AppIcon.png --out icon.iconset/icon_32x32.png
    sips -z 64 64     AppIcon.png --out icon.iconset/icon_32x32@2x.png
    sips -z 128 128   AppIcon.png --out icon.iconset/icon_128x128.png
    sips -z 256 256   AppIcon.png --out icon.iconset/icon_128x128@2x.png
    sips -z 256 256   AppIcon.png --out icon.iconset/icon_256x256.png
    sips -z 512 512   AppIcon.png --out icon.iconset/icon_256x256@2x.png
    sips -z 512 512   AppIcon.png --out icon.iconset/icon_512x512.png
    sips -z 1024 1024 AppIcon.png --out icon.iconset/icon_512x512@2x.png
    iconutil -c icns icon.iconset -o "${ICON_PATH}"
    rm -rf icon.iconset
fi

echo "=========================================="
echo "打包完成！"
echo "输出文件: $(pwd)/${APP_NAME}.app"
echo "双击即可运行。"
echo "=========================================="
