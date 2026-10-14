#!/bin/bash
# VolumeWheel 构建脚本
set -e
cd "$(dirname "$0")"

APP=build/VolumeWheel.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码..."
swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/VolumeWheel" \
  Sources/main.swift \
  -framework Cocoa -framework CoreAudio -framework ApplicationServices

echo "==> 写入 Info.plist 与语言资源..."
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp -R Sources/en.lproj "$APP/Contents/Resources/"
cp -R Sources/zh-Hans.lproj "$APP/Contents/Resources/"

echo "==> 签名..."
codesign --force --deep -s - "$APP" 2>/dev/null || echo "(ad-hoc 签名跳过)"

echo "==> 完成: $(pwd)/$APP"
