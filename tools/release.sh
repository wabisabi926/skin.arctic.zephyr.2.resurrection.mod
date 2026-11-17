#!/usr/bin/env bash
# 一键发布：本地打包 + 同步 Kodi + 打 tag + push 触发 GitHub Actions 发 Release
#
# 流程：
#   1. 校验工作区干净、版本合法、tag 未占用
#   2. 调用 tools/build.py 打包（--check + 生成 zip 到 dist/）
#   3. 可选：同步到本机 Kodi 插件目录（--sync-kodi）
#   4. 打 tag v<version> 并 push，触发 .github/workflows/release.yml
#   5. 可选：等待并确认 Release 创建成功（--wait-release）
#
# 用法：
#   bash tools/release.sh                       # 打包 + 打 tag + push（不同步 Kodi）
#   bash tools/release.sh --sync-kodi           # 打包并同步到本机 Kodi，再发布
#   bash tools/release.sh --no-push             # 只本地打包和打 tag，不 push
#   bash tools/release.sh --wait-release        # push 后等待并确认 Release
#   bash tools/release.sh --dry-run             # 只演练，不改动任何东西
#
# 凭证：沿用本机 git 凭证（GCM/OAuth），不额外写入 token 到配置文件。
# 说明：GitHub Actions 在云端无法写本机 Kodi 目录，因此同步 Kodi 由本脚本在本地完成。

set -euo pipefail

# ---------- 定位仓库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PYTHON_BIN="${PYTHON_BIN:-python}"
REMOTE="${REMOTE:-origin}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

SYNC_KODI=0
NO_PUSH=0
WAIT_RELEASE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --sync-kodi)    SYNC_KODI=1 ;;
        --no-push)      NO_PUSH=1 ;;
        --wait-release) WAIT_RELEASE=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,26p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *)
            echo "未知参数: $arg（用 --help 查看用法）" >&2
            exit 2 ;;
    esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { echo "错误: $*" >&2; exit 1; }

# ---------- 前置检查 ----------
say "前置检查"
command -v git >/dev/null 2>&1 || die "找不到 git"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 Python: $PYTHON_BIN"

if [ -n "$(git status --porcelain)" ]; then
    echo "工作区有未提交改动：" >&2
    git status --short >&2
    die "请先提交或暂存所有改动再发布"
fi

VERSION="$($PYTHON_BIN tools/build.py --print-version)"
[ -n "$VERSION" ] || die "无法读取版本号"
TAG="v$VERSION"
ADDON_ID="skin.arctic.zephyr.2.resurrection.mod"

echo "分支    : $BRANCH"
echo "版本    : $VERSION"
echo "Tag     : $TAG"
echo "远程    : $REMOTE"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG 已存在。若确需重发，请先删除本地和远程 tag"
fi

# ---------- 打包检查 ----------
say "打包前检查"
$PYTHON_BIN tools/build.py --check || die "打包前检查失败"

if [ "$DRY_RUN" -eq 1 ]; then
    say "演练模式：以下是将要执行的操作"
    echo "  1. python tools/build.py --out dist"
    [ "$SYNC_KODI" -eq 1 ] && echo "  2. python tools/build.py --sync-kodi（同步到本机 Kodi）"
    echo "  3. git tag -a $TAG -m 'Release $TAG'"
    [ "$NO_PUSH" -eq 0 ] && echo "  4. git push $REMOTE $BRANCH && git push $REMOTE $TAG"
    echo "演练结束，未做任何改动。"
    exit 0
fi

# ---------- 本地打包 ----------
say "本地打包"
$PYTHON_BIN tools/build.py --out dist || die "打包失败"
ZIP="dist/$ADDON_ID-$VERSION.zip"
[ -f "$ZIP" ] || die "未找到打包产物: $ZIP"
echo "产物: $ZIP"

# ---------- 同步到本机 Kodi（可选）----------
if [ "$SYNC_KODI" -eq 1 ]; then
    say "同步到本机 Kodi"
    $PYTHON_BIN tools/build.py --sync-kodi || die "同步 Kodi 失败"
fi

# ---------- 打 tag ----------
say "创建 tag $TAG"
git tag -a "$TAG" -m "Release $TAG"

# ---------- push 触发 Actions ----------
if [ "$NO_PUSH" -eq 0 ]; then
    say "推送分支和 tag 到 $REMOTE"
    # 网络偶发抖动，带重试（参考 fuse3 tools/gh.sh 的重试思路）
    push_with_retry() {
        local target="$1" attempt
        for attempt in 1 2 3 4 5; do
            if git push "$REMOTE" "$target"; then
                return 0
            fi
            echo "推送 $target 第 $attempt 次失败，重试..." >&2
            sleep 3
        done
        return 1
    }
    push_with_retry "$BRANCH" || die "推送分支失败"
    push_with_retry "$TAG"    || die "推送 tag 失败"

    say "已推送，等待 GitHub Actions 打包并发布 Release"
    echo "进度可在浏览器查看："
    echo "  https://github.com/wabisabi926/skin.arctic.zephyr.2.resurrection.mod/actions"
else
    say "跳过 push（--no-push），tag $TAG 已在本地创建"
fi

# ---------- 等待 Release（可选）----------
if [ "$WAIT_RELEASE" -eq 1 ] && [ "$NO_PUSH" -eq 0 ]; then
    say "等待 Release 创建"
    GH_BIN="${GH_BIN:-C:/Users/liwl/.workbuddy-ai/binaries/gh/bin/gh.exe}"
    if [ ! -f "$GH_BIN" ]; then
        echo "找不到 gh: $GH_BIN，跳过等待（用 GH_BIN 指定路径）" >&2
    else
        # 从本机 git 凭证注入 token，避免把 token 写进 gh 配置
        TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
        if [ -z "$TOKEN" ]; then
            echo "未取到 GitHub 凭证，跳过等待" >&2
        else
            ok=0
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                if out="$(GH_TOKEN="$TOKEN" "$GH_BIN" api "repos/wabisabi926/skin.arctic.zephyr.2.resurrection.mod/releases/tags/$TAG" 2>/dev/null)"; then
                    echo "Release 已创建: https://github.com/wabisabi926/skin.arctic.zephyr.2.resurrection.mod/releases/tag/$TAG"
                    echo "$out" | grep -o '"name": "[^"]*\.zip"' | head -3 || true
                    ok=1
                    break
                fi
                echo "Release 尚未出现，等待中 ($attempt/10)..."
                sleep 6
            done
            [ "$ok" -eq 1 ] || echo "等待超时，请到 GitHub Actions 页面确认构建状态" >&2
        fi
    fi
fi

say "完成"
echo "版本号 : $VERSION"
echo "本地包 : $ZIP"
echo "Tag    : $TAG"
