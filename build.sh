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

# 优先级：显式指定 > VolumeWheel Local Signing > Apple 证书 > ad-hoc
#
# TCC（输入监控 / 辅助功能）授权按代码签名身份记录：
#   · 稳定证书身份 → 重新构建后「指定要求」不变 → 授权继续有效
#   · ad-hoc 签名   → 指定要求是 cdhash → 每次构建都变 → 每次都要重新授权
# 注意：自签名证书不出现在 `security find-identity -p codesigning` 里，
# 但只要 codesign 能用它签，就说明可用，所以这里直接试签。
LOCAL_CERT="VolumeWheel Local Signing"
APP_SIGNED=0

if [ -n "$IDENTITY" ]; then
  # shellcheck disable=SC2086
  if codesign --force --deep ${SIGN_ARGS:-} -s "$IDENTITY" "$APP" 2>/dev/null; then
    echo "    已签名: $IDENTITY"; APP_SIGNED=1
  fi
fi

if [ "$APP_SIGNED" = "0" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  if codesign --force --deep ${SIGN_ARGS:-} -s "$LOCAL_CERT" "$APP" 2>/dev/null; then
    echo "    已签名: $LOCAL_CERT（本机专属稳定证书）"; APP_SIGNED=1
  fi
fi

if [ "$APP_SIGNED" = "0" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  FALLBACK=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -m1 -E "Developer ID Application|Apple Development" \
             | sed -E 's/.*"(.*)"/\1/')
  if [ -n "$FALLBACK" ] && codesign --force --deep ${SIGN_ARGS:-} -s "$FALLBACK" "$APP" 2>/dev/null; then
    echo "    已签名: $FALLBACK"; APP_SIGNED=1
  fi
fi

if [ "$APP_SIGNED" = "0" ]; then
  codesign --force --deep -s - "$APP" 2>/dev/null || true
  echo "    !! 未找到可用证书，已退回 ad-hoc 签名（每次重建后都需要重新授权）"
fi

echo "==> 完成: $(pwd)/$APP"
