#!/bin/bash
# RestReminder 一键发布脚本：构建 → tag → Release → 上传附件 → 端到端核验
# 用法: bash release.sh <版本号>
# 示例: bash release.sh 1.2
# 依赖: gh CLI（需已 gh auth login）、swiftc/hdiutil（由 package.sh 间接使用）
# 设计要点:
#   * token 运行时经 `gh auth token` 注入变量，仅进 curl 请求头，全程不落盘、不回显
#   * GitHub API/uploads 走 dig 解析固定 IP + curl --resolve 直连（网络自愈），一律 -m 限时（macOS 无 timeout 命令）
#   * tag 推送走 SSH 通道，不依赖 token
#   * fail-fast：任一步失败立即退出，不留半成品 Release
set -euo pipefail
cd "$(dirname "$0")" || exit 1

VERSION="${1:-}"
OWNER="xiweicheng"
REPO="RestReminder"
DMG="RestReminder-$VERSION.dmg"
API_IP_FALLBACK="20.205.243.168"   # dig 自愈失败时的兜底
TMP="$(mktemp -d /tmp/rr-release.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

step() { echo "▶ $*"; }
die()  { echo "!! $*" >&2; exit 1; }

[ -n "$VERSION" ] || { echo "用法: bash release.sh <版本号>   例: bash release.sh 1.2"; exit 1; }
[ -f package.sh ] || die "请在 RestReminder 仓库根目录运行"
command -v gh >/dev/null 2>&1 || die "未安装 gh CLI（brew install gh）"

# token：运行时获取，不回显、不写文件
TOKEN="$(gh auth token)" || die "gh 未登录：先运行 gh auth login"
[ -n "$TOKEN" ] || die "gh auth token 为空"
AUTH="Authorization: Bearer $TOKEN"

# 发布必须基于已提交代码（tag 指向与 DMG 来源一致）
git diff-index --quiet HEAD -- || die "工作区有未提交改动，请先运行 bash git-sync.sh"

# ---------- ① 构建 DMG ----------
step "① 构建安装包 $DMG"
bash package.sh "$VERSION"
[ -f "$DMG" ] || die "打包失败：未找到 $DMG"
SIZE="$(stat -f %z "$DMG")"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "   大小: $SIZE 字节 | SHA256: $SHA256"

# ---------- ② 打 tag 并推送（SSH 通道） ----------
step "② tag v$VERSION"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "   tag v$VERSION 已存在，复用"
else
  git tag -a "v$VERSION" -m "RestReminder v$VERSION"
  git push origin "v$VERSION"
fi

# ---------- ③ 网络自愈：固定 IP ----------
step "③ 解析 GitHub IP（dig 自愈，失败用兜底）"
API_IP="$(dig +time=2 +tries=1 +short api.github.com @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)"
[ -n "$API_IP" ] || API_IP="$API_IP_FALLBACK"
UP_IP="$(dig +time=2 +tries=1 +short uploads.github.com @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)"
[ -n "$UP_IP" ] || UP_IP="$API_IP_FALLBACK"
echo "   api: $API_IP | uploads: $UP_IP"
API() { curl -sS --resolve "api.github.com:443:$API_IP"    -m 30  "$@"; }
UP()  { curl -sS --resolve "uploads.github.com:443:$UP_IP" -m 600 "$@"; }

# ---------- ④ 创建 Release ----------
step "④ 创建 Release v$VERSION"
python3 - "$VERSION" "$SHA256" > "$TMP/rel_body.json" <<'PY'
import json, sys
ver, sha = sys.argv[1], sys.argv[2]
json.dump({
    "tag_name": f"v{ver}",
    "name": f"RestReminder v{ver}",
    "body": (
        f"## 📦 RestReminder v{ver}\n\n"
        f"- 安装包：RestReminder-{ver}.dmg\n"
        f"- SHA256：`{sha}`\n\n"
        f"### 安装\n\n"
        f"1. 下载下方附件 RestReminder-{ver}.dmg\n"
        f"2. 双击打开，将 RestReminder.app 拖入「应用程序」\n"
        f"3. 首次启动如被 Gatekeeper 拦截：右键点按 App → 打开\n"
    ),
    "draft": False,
    "prerelease": False,
}, sys.stdout, ensure_ascii=False)
PY
CODE="$(API -o "$TMP/rel.json" -w '%{http_code}' -X POST \
  -H "$AUTH" -H "Accept: application/vnd.github+json" \
  --data-binary @"$TMP/rel_body.json" \
  "https://api.github.com/repos/$OWNER/$REPO/releases")"
if [ "$CODE" = "422" ]; then
  echo "   Release 已存在，复用"
  API -H "$AUTH" -o "$TMP/rel.json" "https://api.github.com/repos/$OWNER/$REPO/releases/tags/v$VERSION"
else
  [ "$CODE" = "201" ] || die "创建 Release 失败 HTTP $CODE"
fi
REL_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/rel.json")"
echo "   release id: $REL_ID"

# ---------- ⑤ 上传附件（同名先删再传，可重跑） ----------
step "⑤ 上传附件 $DMG"
API -H "$AUTH" -o "$TMP/assets.json" "https://api.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets"
OLD_ID="$(python3 -c '
import json, sys
ver, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
print(next((str(a["id"]) for a in d if a["name"] == "RestReminder-" + ver + ".dmg"), ""))' "$VERSION" "$TMP/assets.json")"
if [ -n "$OLD_ID" ]; then
  echo "   同名附件已存在(#$OLD_ID)，删除后重传"
  API -f -X DELETE -H "$AUTH" -o /dev/null "https://api.github.com/repos/$OWNER/$REPO/releases/assets/$OLD_ID"
fi
UCODE="$(UP -o "$TMP/asset.json" -w '%{http_code}' -X POST \
  -H "$AUTH" -H "Content-Type: application/octet-stream" \
  --data-binary @"$DMG" \
  "https://uploads.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets?name=$DMG")"
[ "$UCODE" = "201" ] || die "上传附件失败 HTTP $UCODE"

# ---------- ⑥ 核验：资产 state=uploaded 且 size 与本地一致 ----------
step "⑥ 核验云端资产"
API -H "$AUTH" -o "$TMP/rel2.json" "https://api.github.com/repos/$OWNER/$REPO/releases/tags/v$VERSION"
python3 - "$TMP/rel2.json" "$SIZE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = int(sys.argv[2])
a = next((a for a in d["assets"] if a["name"].endswith(".dmg")), None)
assert a, "云端未找到 DMG 附件"
assert a["state"] == "uploaded", f"附件 state={a['state']}（非 uploaded）"
assert a["size"] == want, f"size 不一致: 云端 {a['size']} vs 本地 {want}"
print(f"   ✅ {a['name']} state=uploaded size={a['size']} 与本地一致")
PY

# ---------- ⑦ 匿名端到端核验（模拟公众用户，零凭据下载） ----------
step "⑦ 匿名下载核验（无 token，验证全世界可下载）"
URL="https://github.com/$OWNER/$REPO/releases/download/v$VERSION/$DMG"
if curl -sSfL --retry 2 -m 60 -o "$TMP/anon.dmg" "$URL"; then
  ANON_SHA="$(shasum -a 256 "$TMP/anon.dmg" | awk '{print $1}')"
  [ "$ANON_SHA" = "$SHA256" ] || die "匿名下载 SHA256 与本地不一致"
  echo "   ✅ 匿名下载 SHA256 一致 — 发布闭环"
else
  echo "   ⚠️ 匿名下载失败（仓库可能仍为私有）；API 层核验已通过，仓库转公开后可补验"
fi

echo ""
echo "🎉 v$VERSION 发布完成"
echo "   Release: https://github.com/$OWNER/$REPO/releases/tag/v$VERSION"
echo "   下载:    $URL"
echo "   SHA256:  $SHA256"
