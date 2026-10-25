#!/bin/bash
# =============================================================================
# RestReminder 一键发布脚本：构建 → tag → Release → 上传附件 → 端到端核验
#
# 用法:
#   bash release.sh <版本号> [--reuse-dmg]
# 示例:
#   bash release.sh 1.2              # 全新构建并发布 v1.2
#   bash release.sh 1.1 --reuse-dmg  # 复用已构建的 RestReminder-1.1.dmg 重发（幂等）
#
# 依赖: gh CLI（需 gh auth login）、swiftc/hdiutil（package.sh 内部使用）
#
# 设计要点（历史经验固化）:
#   * 通道策略: gh 优先（perl alarm 短超时探测，api.github.com 被污染时快速失败），
#     失败自动降级 curl + dig 多源钉 IP + --resolve 直连自愈（网络抖动根治法）；
#     gh 通道中途失败同样自动降级
#   * token fail-fast: 仅从 `gh auth token` 读取；为空立即终止；GET /user 校验
#     有效性且 login 必须等于 OWNER，防止把 Release 发到错误账号
#   * 输出脱敏: token 全程零明文 —— 只存内存变量 + TMP 头文件（umask 077），
#     curl 一律 `-H @文件` 携带（避开 argv/ps 泄露）；日志仅输出 len/mask
#   * 幂等: Release 已存在(422)→复用；同名附件→先删后传；每次运行 PATCH 补全标题/正文
#   * Release 正文: 优先复用 release_notes_v<版本>.md 模板，不存在则内置模板（含 SHA256）
#   * tag 推送走 SSH 通道，不依赖 token
#   * 核验收口: 资产 state=uploaded + size 一致 + API digest(sha256) 一致，
#     最后匿名零凭据下载实比 SHA256（私有仓 404 属预期，转公开后即闭环）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")" || exit 1

# ---------- 参数 ----------
VERSION="" SKIP_BUILD=0
for a in "$@"; do
  case "$a" in
    --reuse-dmg) SKIP_BUILD=1 ;;
    -h|--help)   sed -n '4,10p' "$0"; exit 0 ;;
    *)           VERSION="$a" ;;
  esac
done
[ -n "$VERSION" ] || { sed -n '4,10p' "$0"; exit 1; }

OWNER="xiweicheng"
REPO="RestReminder"
DMG="RestReminder-$VERSION.dmg"
NOTES_FILE="release_notes_v$VERSION.md"   # 存在则用作 Release 正文
TITLE="RestReminder v$VERSION"
API_FALLBACKS=("20.205.243.168" "140.82.121.6" "140.82.114.6")

TMP="$(mktemp -d /tmp/rr-release.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

step() { echo "▶ $*"; }
die()  { echo "!! $*" >&2; exit 1; }
mask() { local t="$1"; printf '%s****%s' "${t:0:4}" "${t: -4}"; }

# perl alarm 短超时执行（macOS 无 timeout 命令；alarm 跨 exec 保留）
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# ---------- dig 多源钉 IP（1.1.1.1/8.8.8.8/223.5.5.5/系统 取 ≥2 票众数，防单源污染） ----------
best_ip() {
  { local s
    for s in 1.1.1.1 8.8.8.8 223.5.5.5 ""; do
      if [ -n "$s" ]; then dig +time=2 +tries=1 +short "$1" A @"$s" 2>/dev/null || true
      else dig +time=2 +tries=1 +short "$1" A 2>/dev/null || true; fi
    done
  } | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort | uniq -c | sort -rn \
    | awk '$1>=2{print $2; exit}'
}
probe_ip() { curl -sS -o /dev/null --resolve "$1:443:$2" --connect-timeout 5 -m 8 "https://$1/zen" 2>/dev/null; }
pick_ip() {
  local c ip
  c="$(best_ip "$1" || true)"
  if [ -n "$c" ] && probe_ip "$1" "$c"; then echo "$c"; return 0; fi
  for ip in "${API_FALLBACKS[@]}"; do
    probe_ip "$1" "$ip" && { echo "$ip"; return 0; }
  done
  return 1
}

# curl 自愈通道初始化：钉 IP → token 头文件（umask 077）→ GET /user fail-fast
init_curl_channel() {
  API_IP="$(pick_ip api.github.com)"    || die "钉 IP 失败：api.github.com 多源解析+探活均不通"
  UP_IP="$(pick_ip uploads.github.com)" || die "钉 IP 失败：uploads.github.com 多源解析+探活均不通"
  api_curl() { curl -sS --resolve "api.github.com:443:$API_IP"    -m 30  "$@"; }
  up_curl()  { curl -sS --resolve "uploads.github.com:443:$UP_IP" -m 600 "$@"; }
  ( umask 077; printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/auth_hdr" )
  CODE="$(api_curl -o "$TMP/user.json" -w '%{http_code}' -H @"$TMP/auth_hdr" "https://api.github.com/user")"
  [ "$CODE" = "200" ] || die "token fail-fast：GET /user HTTP ${CODE}（token 无效或过期）"
  LOGIN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["login"])' "$TMP/user.json")"
  [ "$LOGIN" = "$OWNER" ] || die "token fail-fast：token 归属 $LOGIN ≠ ${OWNER}，拒绝发布"
  echo "   ✅ curl 通道就绪（api=$API_IP uploads=${UP_IP}，token 校验通过 login=${LOGIN}）"
}

# ---------- ⓪ 前置检查 + token fail-fast ----------
[ -f package.sh ] || die "请在 RestReminder 仓库根目录运行"
command -v gh >/dev/null 2>&1 || die "未安装 gh CLI（brew install gh）"
command -v dig >/dev/null 2>&1 || die "未安装 dig"
command -v python3 >/dev/null 2>&1 || die "未安装 python3"

TOKEN="$(gh auth token 2>/dev/null || true)"
[ -n "$TOKEN" ] || die "token fail-fast：gh auth token 为空 —— 请先 gh auth login"
TOKEN_LEN="$(printf '%s' "$TOKEN" | wc -c | tr -d ' ')"
step "⓪ token 就绪（len=$TOKEN_LEN mask=$(mask "$TOKEN")，全程不回显明文）"

git diff-index --quiet HEAD -- || die "工作区有未提交改动 —— 发布必须基于已提交代码，请先 bash git-sync.sh"

# ---------- ① 构建 DMG ----------
step "① 安装包 $DMG"
if [ "$SKIP_BUILD" = 1 ]; then
  [ -f "$DMG" ] || die "--reuse-dmg：未找到 ${DMG}，请先 bash package.sh $VERSION"
  echo "   复用现有 ${DMG}（跳过构建）"
else
  bash package.sh "$VERSION" >/dev/null
fi
[ -f "$DMG" ] || die "打包失败：未找到 $DMG"
SIZE="$(stat -f %z "$DMG")"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "   大小: $SIZE 字节 | SHA256: ${SHA256:0:16}…"

# ---------- ② tag（SSH 通道推送） ----------
step "② tag v$VERSION"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "   tag v$VERSION 已存在，复用"
else
  git tag -a "v$VERSION" -m "RestReminder v$VERSION"
  git push origin "v$VERSION"
  echo "   tag 已推送（SSH）"
fi

# ---------- ③ Release 正文（模板优先，内置兜底） ----------
python3 - "$VERSION" "$SHA256" "$NOTES_FILE" > "$TMP/notes.txt" <<'PY'
import os, sys
ver, sha, notes = sys.argv[1], sys.argv[2], sys.argv[3]
if os.path.isfile(notes):
    sys.stdout.write(open(notes, encoding="utf-8").read())
else:
    sys.stdout.write(f"""## 📦 RestReminder v{ver}

- 安装包：RestReminder-{ver}.dmg
- SHA256：`{sha}`

### 安装
1. 下载下方附件 RestReminder-{ver}.dmg
2. 双击打开，将 RestReminder.app 拖入「应用程序」
3. 首次启动如被 Gatekeeper 拦截：右键点按 App → 打开
""")
PY
echo "   正文来源: $([ -f "$NOTES_FILE" ] && echo "$NOTES_FILE 模板" || echo "内置模板")"

# ---------- ④ 通道探测：gh 优先 → curl+钉IP 兜底 ----------
step "③ 通道探测（gh 优先，8s 短超时）"
MODE=""
if LOGIN="$(with_timeout 8 gh api user -q .login 2>/dev/null)" && [ "$LOGIN" = "$OWNER" ]; then
  MODE="gh"; echo "   ✅ gh 通道可用（login=${LOGIN}）"
else
  echo "   ⚠️ gh 通道不可用 → 降级 curl + dig 多源钉 IP 自愈"
  init_curl_channel
  MODE="curl"
fi

# ---------- ⑤ 发布（按通道执行，均幂等） ----------
patch_release() { # PATCH 标题+正文（幂等重跑/补全 body 统一走这里）
  if [ "$MODE" = "gh" ]; then
    gh release edit "v$VERSION" --title "$TITLE" --notes-file "$TMP/notes.txt" >/dev/null || return 1
  else
    python3 - "$TITLE" "$TMP" > "$TMP/patch.json" <<'PY'
import json, sys
title, tmp = sys.argv[1], sys.argv[2]
json.dump({"name": title, "body": open(tmp + "/notes.txt", encoding="utf-8").read()},
          sys.stdout, ensure_ascii=False)
PY
    CODE="$(api_curl -o /dev/null -w '%{http_code}' -X PATCH \
      -H @"$TMP/auth_hdr" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
      --data-binary @"$TMP/patch.json" \
      "https://api.github.com/repos/$OWNER/$REPO/releases/$REL_ID")"
    [ "$CODE" = "200" ] || { echo "PATCH Release 失败 HTTP $CODE" >&2; return 1; }
  fi
}

publish_gh() {
  step "④⑤ gh 通道：创建/复用 Release + 上传附件"
  if gh release view "v$VERSION" --json databaseId -q .databaseId >/dev/null 2>&1; then
    echo "   Release v$VERSION 已存在 → 编辑正文 + --clobber 覆盖上传"
    patch_release || return 1
    gh release upload "v$VERSION" "$DMG" --clobber || return 1
  else
    if ! with_timeout 120 gh release create "v$VERSION" --title "$TITLE" --notes-file "$TMP/notes.txt" "$DMG"; then
      return 1
    fi
    echo "   Release v$VERSION 已创建并上传"
  fi
}

publish_curl() {
  step "④⑤ curl 通道（钉 IP）：创建/复用 Release + 上传附件"
  python3 - "$VERSION" > "$TMP/rel_body.json" <<'PY'
import json, sys
ver = sys.argv[1]
json.dump({"tag_name": f"v{ver}", "name": f"RestReminder v{ver}",
           "body": "placeholder", "draft": False, "prerelease": False},
          sys.stdout, ensure_ascii=False)
PY
  CODE="$(api_curl -o "$TMP/rel.json" -w '%{http_code}' -X POST \
    -H @"$TMP/auth_hdr" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
    --data-binary @"$TMP/rel_body.json" \
    "https://api.github.com/repos/$OWNER/$REPO/releases")"
  case "$CODE" in
    201) echo "   Release v$VERSION 已创建" ;;
    422) echo "   Release v$VERSION 已存在(422)，复用"
         api_curl -H @"$TMP/auth_hdr" -o "$TMP/rel.json" \
           "https://api.github.com/repos/$OWNER/$REPO/releases/tags/v$VERSION" ;;
    *)   die "创建 Release 失败 HTTP $CODE" ;;
  esac
  REL_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$TMP/rel.json")"
  echo "   release id: $REL_ID"

  patch_release

  api_curl -H @"$TMP/auth_hdr" -o "$TMP/assets.json" \
    "https://api.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets?per_page=100"
  OLD_ID="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(next((str(a["id"]) for a in d if a["name"] == sys.argv[2]), ""))' "$TMP/assets.json" "$DMG")"
  if [ -n "$OLD_ID" ]; then
    echo "   同名附件 #$OLD_ID 已存在 → 先删后传（幂等）"
    C="$(api_curl -o /dev/null -w '%{http_code}' -X DELETE -H @"$TMP/auth_hdr" \
      "https://api.github.com/repos/$OWNER/$REPO/releases/assets/$OLD_ID")"
    [ "$C" = "204" ] || die "删除旧附件失败 HTTP $C"
  fi
  UCODE="$(up_curl -o "$TMP/asset.json" -w '%{http_code}' -X POST \
    -H @"$TMP/auth_hdr" -H "Content-Type: application/octet-stream" --data-binary @"$DMG" \
    "https://uploads.github.com/repos/$OWNER/$REPO/releases/$REL_ID/assets?name=$DMG")"
  [ "$UCODE" = "201" ] || die "上传附件失败 HTTP $UCODE"
  echo "   附件已上传"
}

REL_ID=""
if [ "$MODE" = "gh" ]; then
  if publish_gh; then
    echo "   ✅ gh 通道发布成功"
  else
    RC=$?
    echo "   ⚠️ gh 通道失败(rc=$RC) → 自动降级 curl + 钉 IP 自愈"
    init_curl_channel
    MODE="curl"
    publish_curl
  fi
else
  publish_curl
fi

# ---------- ⑥ 端到端核验：state/size/digest ----------
step "⑥ 核验云端资产（state + size + digest）"
if [ "$MODE" = "gh" ]; then
  gh api "repos/$OWNER/$REPO/releases/tags/v$VERSION" > "$TMP/rel_final.json"
else
  api_curl -H @"$TMP/auth_hdr" -o "$TMP/rel_final.json" \
    "https://api.github.com/repos/$OWNER/$REPO/releases/tags/v$VERSION"
fi
python3 - "$TMP/rel_final.json" "$SIZE" "$SHA256" "$DMG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want_size, want_sha, dmg = int(sys.argv[2]), sys.argv[3], sys.argv[4]
a = next((x for x in d["assets"] if x["name"] == dmg), None)
assert a, f"云端未找到附件 {dmg}"
assert a["state"] == "uploaded", f"附件 state={a['state']}（非 uploaded）"
assert a["size"] == want_size, f"size 不一致: 云端 {a['size']} vs 本地 {want_size}"
print(f"   ✅ {a['name']} state=uploaded size={a['size']}")
dig = a.get("digest", "")
if dig:
    assert dig == f"sha256:{want_sha}", f"digest 不一致: {dig}"
    print(f"   ✅ API digest = {dig}")
else:
    print("   ⚠️ API 未返回 digest 字段，由下方匿名下载实比补强")
PY

# ---------- ⑦ 匿名下载核验（零凭据；私有仓 404 属预期） ----------
URL="https://github.com/$OWNER/$REPO/releases/download/v$VERSION/$DMG"
step "⑦ 匿名下载核验（无 token，模拟公众用户）"
anon_ok=0
if curl -sSfL --retry 2 -m 90 -o "$TMP/anon.dmg" "$URL" 2>/dev/null; then
  anon_ok=1
else
  GH_IP="$(best_ip github.com || true)"
  if [ -n "$GH_IP" ] && curl -sSfL --resolve "github.com:443:$GH_IP" -m 90 -o "$TMP/anon.dmg" "$URL" 2>/dev/null; then
    anon_ok=1
  fi
fi
if [ "$anon_ok" = 1 ]; then
  ANON_SHA="$(shasum -a 256 "$TMP/anon.dmg" | awk '{print $1}')"
  [ "$ANON_SHA" = "$SHA256" ] || die "匿名下载 SHA256 与本地不一致"
  echo "   ✅ 匿名下载成功且 SHA256 一致 —— 公开可下载闭环"
else
  echo "   ⚠️ 匿名下载失败 —— 仓库为 Private 属预期：Release 仅所有者/协作者可见，"
  echo "      转为 Public 后全世界可下载；此前 API 层核验已全部通过"
fi

echo ""
echo "🎉 v$VERSION 发布完成"
echo "   Release: https://github.com/$OWNER/$REPO/releases/tag/v$VERSION"
echo "   下载:    $URL"
echo "   SHA256:  $SHA256"
