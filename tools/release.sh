#!/usr/bin/env bash
# 一键发布：打 tag + push，触发 GitHub Actions 云端打包并发布 Release
#
# 打包和发布完全交给 .github/workflows/release.yml 在云端完成，
# 本脚本只负责更新 tag 并推送，不做本地打包、不同步本机 Kodi。
#
# 流程：
#   1. 校验工作区干净、版本合法、tag 未占用
#   2. 快速检查（调用 build.py --check 校验 XML 与包结构）
#   3. 打 tag v<version> 并 push，触发云端 workflow
#   4. 可选：等待并确认云端 Release 创建成功（--wait-release）
#
# 用法：
#   bash tools/release.sh                       # 打 tag + push 触发云端发布
#   bash tools/release.sh --no-push             # 只在本地打 tag，不 push
#   bash tools/release.sh --wait-release        # push 后等待并确认 Release
#   bash tools/release.sh --dry-run             # 只演练，不改动任何东西
#
# 凭证：沿用本机 git 凭证（GCM/OAuth），不额外写入 token 到配置文件。

set -euo pipefail

# ---------- 定位仓库 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PYTHON_BIN="${PYTHON_BIN:-python}"
REMOTE="${REMOTE:-origin}"
LOCAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# 本地分支名可能与远程不同（如本地 Piers-douban → 远程 douban-Piers），
# 用 upstream 的远程分支名作为推送目标，避免误建同名新分支。
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
if [ -n "$UPSTREAM" ] && [[ "$UPSTREAM" == "$REMOTE/"* ]]; then
    REMOTE_BRANCH="${UPSTREAM#"$REMOTE/"}"
else
    REMOTE_BRANCH="$LOCAL_BRANCH"
fi

NO_PUSH=0
WAIT_RELEASE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --no-push)      NO_PUSH=1 ;;
        --wait-release) WAIT_RELEASE=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
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
    die "请先提交所有改动再发布"
fi

VERSION="$($PYTHON_BIN tools/build.py --print-version)"
[ -n "$VERSION" ] || die "无法读取版本号"
TAG="v$VERSION"

echo "分支    : $LOCAL_BRANCH -> $REMOTE/$REMOTE_BRANCH"
echo "版本    : $VERSION"
echo "Tag     : $TAG"
echo "远程    : $REMOTE"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG 已存在。若确需重发，请先删除本地和远程 tag"
fi

# ---------- 快速检查（云端会再打包，这里只提前拦截明显错误）----------
say "发布前检查"
$PYTHON_BIN tools/build.py --check || die "发布前检查失败"

if [ "$DRY_RUN" -eq 1 ]; then
    say "演练模式：以下是将要执行的操作"
    echo "  1. git tag -a $TAG -m 'Release $TAG'"
    [ "$NO_PUSH" -eq 0 ] && echo "  2. git push $REMOTE HEAD:$REMOTE_BRANCH && git push $REMOTE $TAG"
    echo "  3. 云端 Actions 打包并创建 Release（下载 zip 作为安装资产）"
    echo "演练结束，未做任何改动。"
    exit 0
fi

# ---------- 打 tag ----------
say "创建 tag $TAG"
git tag -a "$TAG" -m "Release $TAG"

# ---------- push 触发云端 ----------
if [ "$NO_PUSH" -eq 0 ]; then
    say "推送分支和 tag 到 $REMOTE（触发云端打包发布）"
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
    # 用 HEAD:远程分支 的写法，兼容本地/远程分支名不一致的情况
    push_with_retry "HEAD:$REMOTE_BRANCH" || die "推送分支失败"
    push_with_retry "$TAG"                || die "推送 tag 失败"

    say "已推送，等待 GitHub Actions 云端打包并发布 Release"
    echo "进度可在浏览器查看："
    echo "  https://github.com/wabisabi926/skin.arctic.zephyr.2.resurrection.mod/actions"
else
    say "跳过 push（--no-push），tag $TAG 已在本地创建"
fi

# ---------- 等待 Release（可选）----------
if [ "$WAIT_RELEASE" -eq 1 ] && [ "$NO_PUSH" -eq 0 ]; then
    say "等待云端 Release 创建"
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
echo "Tag    : $TAG"
echo "发布地址: https://github.com/wabisabi926/skin.arctic.zephyr.2.resurrection.mod/releases"
