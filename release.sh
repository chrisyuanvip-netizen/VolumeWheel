#!/bin/bash
# VolumeWheel 正式发行：Developer ID 签名 + 公证（notarize）+ 装订（staple）
#
# 用法：
#   ./release.sh                      构建 + Developer ID 签名 + 公证 + 装订 + 校验
#   ./release.sh --sign-only          只做签名与自检，不提交公证
#   ./release.sh --setup-credentials  保存公证凭据到钥匙串（只需做一次）
#
# 可用环境变量：
#   TEAM_ID=XXXXXXXXXX                 你的 Team ID（默认从证书里自动读取）
#   NOTARY_PROFILE=volumewheel-notary  钥匙串里的凭据档案名
#   SKIP_BUILD=1                       跳过编译，直接对现有 build/VolumeWheel.app 签名
#   SIGN_IDENTITY="..."                手动指定签名身份（默认自动找 Developer ID Application）
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-volumewheel-notary}"
APP=build/VolumeWheel.app
ZIP=build/VolumeWheel-notarize.zip
TEAM_ID="${TEAM_ID:-}"

# 从证书里读 Team ID（证书 subject 的 OU 字段），避免把个人 Team ID 写进仓库
detect_team_id() {
  security find-certificate -c "$1" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's|.*/OU=\([A-Z0-9]\{10\}\).*|\1|p' | head -1
}

# ---------------------------------------------------------------- 凭据
if [ "${1:-}" = "--setup-credentials" ]; then
  cat <<'EOF'
公证需要「Apple ID」+「App 专用密码」（不是你的登录密码）：
  生成地址：https://appleid.apple.com → 登录与安全性 → App 专用密码 → 生成
EOF
  read -r -p "Apple ID (邮箱): " APPLE_ID
  if [ -z "$TEAM_ID" ]; then
    CANDIDATE=$(security find-identity -v -p codesigning 2>/dev/null \
                | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
    [ -n "$CANDIDATE" ] && TEAM_ID=$(detect_team_id "$CANDIDATE")
  fi
  read -r -p "Team ID${TEAM_ID:+ [$TEAM_ID]}: " INPUT_TEAM
  TEAM_ID="${INPUT_TEAM:-$TEAM_ID}"
  if [ -z "$TEAM_ID" ]; then
    echo "!! 拿不到 Team ID，请用 TEAM_ID=XXXXXXXXXX ./release.sh --setup-credentials 显式指定"
    exit 1
  fi
  read -r -s -p "App 专用密码: " APP_PASSWORD; echo
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
      --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
  echo "✓ 凭据已存入钥匙串档案: $NOTARY_PROFILE"
  echo "  （也可改用 App Store Connect API Key：--key *.p8 --key-id … --issuer …）"
  exit 0
fi

SIGN_ONLY=0
[ "${1:-}" = "--sign-only" ] && SIGN_ONLY=1

# ---------------------------------------------------------------- 证书
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi

if [ -z "$IDENTITY" ]; then
  cat <<'EOF'
✗ 没找到 “Developer ID Application” 证书，无法做正式发行签名。

  它需要**付费**的 Apple Developer Program 会员资格（US$99/年），免费账号签不出来。
  获取步骤：
    1. 加入会员：https://developer.apple.com/programs/
    2. 创建证书（二选一）：
       · Xcode → Settings → Accounts 登录 Apple ID →
         Manage Certificates… → 左下 “+” → Developer ID Application
       · 或 https://developer.apple.com/account/resources/certificates
         → “+” → Developer ID Application → 下载 .cer → 双击导入「登录」钥匙串
    3. 校验：security find-identity -v -p codesigning
       应能看到 “Developer ID Application: <你的名字> (<TEAMID>)”

  在拿到证书之前：
    · 本地构建/自用请直接用 ./build.sh
      （它已改用你现有的 Apple Development 证书签名，指定要求是稳定的，
        重新构建通常**不需要**重新授权 —— 原先每次都要重新授权，
        是因为旧版 build.sh 用的是 ad-hoc 签名）
    · 想先验证「重建后授权是否保留」，见 README 的 “A note on signing and re-granting”
EOF
  exit 1
fi
[ -z "$TEAM_ID" ] && TEAM_ID=$(detect_team_id "$IDENTITY")
echo "==> 签名身份: $IDENTITY"
echo "==> Team ID : ${TEAM_ID:-(未读到，仅影响公证凭据)}"

# ---------------------------------------------------------------- 构建 + 签名
# hardened runtime 与安全时间戳是公证的硬性要求
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> 构建"
  SIGN_IDENTITY="$IDENTITY" SIGN_ARGS="--options runtime --timestamp" bash build.sh
else
  echo "==> 跳过编译，直接签名现有 bundle"
  codesign --force --deep --options runtime --timestamp -s "$IDENTITY" "$APP"
fi

# ---------------------------------------------------------------- 公证前自检
echo "==> 公证前自检"
codesign --verify --deep --strict --verbose=2 "$APP"
# 注意：这里不能用 `codesign ... | grep -q`。grep -q 一命中就提前退出，
# 会把 codesign 打成 SIGPIPE；配合 set -o pipefail 会把成功误判成失败。
CODESIGN_DUMP=$(codesign -d --verbose=4 "$APP" 2>&1 || true)
if [[ "$CODESIGN_DUMP" == *"runtime)"* ]]; then
  echo "    hardened runtime ✓"
else
  echo "!! 没有启用 hardened runtime，公证一定会被拒 —— 检查 SIGN_ARGS"
  exit 1
fi

if [ "$SIGN_ONLY" = "1" ]; then
  echo "✓ 仅签名完成: $(pwd)/$APP"
  exit 0
fi

# ---------------------------------------------------------------- 公证
echo "==> 打包并提交公证（通常 1~5 分钟，--wait 会等结果）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
  cat <<EOF

✗ 公证提交失败。常见原因：
  · 还没保存凭据        → 先执行  ./release.sh --setup-credentials
  · App 专用密码已失效  → 重新生成后再次 store-credentials
  · Team ID 不匹配      → 当前 TEAM_ID=$TEAM_ID
  · 签名缺少 hardened runtime / 安全时间戳
  也可以手动看提交历史：  xcrun notarytool history --keychain-profile $NOTARY_PROFILE
EOF
  exit 1
fi

# ---------------------------------------------------------------- 装订 + 校验
echo "==> 把公证结果装订进 App（离线也能通过 Gatekeeper）"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper 最终校验"
spctl -a -vvv -t exec "$APP" || true
rm -f "$ZIP"

echo
echo "✓ 发行完成: $(pwd)/$APP"
echo "  已签名(Developer ID + hardened runtime) + 已公证 + 已装订。"
echo "  这种签名下 TCC 授权按「指定要求」匹配，重新构建后授权不会失效。"
