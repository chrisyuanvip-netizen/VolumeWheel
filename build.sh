#!/bin/bash
# VolumeWheel 构建脚本（本地开发用）
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
# 可用环境变量覆盖：
#   SIGN_IDENTITY="Developer ID Application: ..."  指定签名身份
#   SIGN_ARGS="--options runtime --timestamp"      额外签名参数（正式发行需要，见 release.sh）
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # 关键：优先使用**稳定的证书身份**。
  # TCC（输入监控 / 辅助功能）授权是按代码签名身份记录的：
  #   · 用同一张证书重新构建 → “指定要求”不变 → 授权继续有效
  #   · ad-hoc 签名（-s -）→ 指定要求是 cdhash → 每次构建都变 → 每次都要重新授权
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -m1 -E "Developer ID Application|Apple Development" \
             | sed -E 's/.*"(.*)"/\1/')
fi

if [ -n "$IDENTITY" ]; then
  # shellcheck disable=SC2086  # SIGN_ARGS 需要按空格拆成多个参数
  codesign --force --deep ${SIGN_ARGS:-} -s "$IDENTITY" "$APP"
  echo "    已签名: $IDENTITY"
else
  codesign --force --deep -s - "$APP" 2>/dev/null || echo "(ad-hoc 签名跳过)"
  echo "    !! 未找到可用证书，已退回 ad-hoc 签名（会导致每次构建后都需要重新授权）"
fi

echo "==> 完成: $(pwd)/$APP"
