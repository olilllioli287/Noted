#!/bin/bash
# 建置並安裝 Noted（瀏海筆記＋音量＋截圖）
#   ./build.sh            編譯、安裝到 ~/Applications/Noted.app、重開
#   ./build.sh --no-open  安裝但不重開
#   ./build.sh --dev      只做測試版：build/Noted Dev.app（bundle id com.local.noted.suite-dev），不碰正式版、不重開
#   ./build.sh --out <資料夾>  只建到指定資料夾（<資料夾>/Noted.app）：不結束正在跑的 Noted、不安裝、不開 App
#
# 簽章（自簽憑證在鑰匙圈裡是「不受信任」狀態，所以找身分不加 -v）：環境變數 NOTED_SIGN_ID 指定憑證名稱（找不到就報錯中止；設成 - 就明確用 ad-hoc）；沒設時找「Toolbox Local Signing」，
# 還是找不到就用 ad-hoc 簽章（每次重建都要重新給權限）。
set -e
cd "$(dirname "$0")"
MODE="${1:-}"
case "$MODE" in
  ""|--no-open|--dev|--out) ;;
  *) echo "不認得的參數：${MODE}（可用：--no-open、--dev、--out <資料夾>）"; exit 1;;
esac
if [ "$MODE" != "--out" ] && [ $# -gt 1 ]; then echo "多餘的參數：${*:2}"; exit 1; fi
OUT_DIR=""
if [ "$MODE" = "--out" ]; then
  OUT_DIR="${2:-}"
  if [ -z "$OUT_DIR" ]; then echo "--out 後面要接資料夾。"; exit 1; fi
fi

# 找簽章身分（NOTED_FAKE_IDENTITIES 只給測試用：換掉 security 的輸出）
list_identities() {
  if [ -n "${NOTED_FAKE_IDENTITIES+x}" ]; then printf '%s\n' "$NOTED_FAKE_IDENTITIES"
  else security find-identity -p codesigning 2>/dev/null; fi
}
has_identity() { list_identities | grep -qF "\"$1\""; }
if [ "${NOTED_SIGN_ID:-}" = "-" ]; then
  IDENTITY="-"   # 明確要求 ad-hoc（發佈用）
elif [ -n "${NOTED_SIGN_ID:-}" ]; then
  if ! has_identity "$NOTED_SIGN_ID"; then echo "找不到簽章身分「${NOTED_SIGN_ID}」（NOTED_SIGN_ID）。中止。"; exit 1; fi
  IDENTITY="$NOTED_SIGN_ID"
elif has_identity "Toolbox Local Signing"; then
  IDENTITY="Toolbox Local Signing"
else
  IDENTITY="-"
  echo "找不到簽章憑證，改用 ad-hoc 簽章（每次重建都要重新授權輔助使用、螢幕錄製等權限）。"
fi

echo "編譯…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

if [ "$MODE" = "--dev" ]; then
  APP="build/Noted Dev.app"
  BUNDLE_ID="com.local.noted.suite-dev"
elif [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  APP="$OUT_DIR/Noted.app"
  BUNDLE_ID="com.local.noted"
else
  APP="$HOME/Applications/Noted.app"
  BUNDLE_ID="com.local.noted"
  # 送 SIGTERM 讓它走正常結束（還原截圖設定與裝置靜音），等它真的結束再換檔
  pkill -x Noted 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -x Noted >/dev/null || break; sleep 0.2; done
  if pgrep -x Noted >/dev/null; then echo "Noted 沒有在 6 秒內結束，先不安裝。"; exit 1; fi
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$BIN/Noted" "$APP/Contents/MacOS/Noted"

# ShotLine 的翻譯（L() 用英文原文當鍵）
rm -rf "$APP/Contents/Resources/"*.lproj
cp -R Resources/ShotLine/*.lproj "$APP/Contents/Resources/"
# SwiftPM 套件的資源包（KeyboardShortcuts 的翻譯）
for b in "$BIN"/*.bundle; do
  [ -e "$b" ] || continue
  rm -rf "$APP/Contents/Resources/$(basename "$b")"
  cp -R "$b" "$APP/Contents/Resources/"
done

rm -rf "$APP/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" "$APP"
echo "完成：$APP"
if [ "$MODE" = "" ]; then open "$APP"; fi
