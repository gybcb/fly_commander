#!/bin/bash
# FlyCommander 一键发布（自动无人值守）：bump → commit → push → tag → push tag → 盯 CI 到出 release。
#
# 存在意义（2026-10-10）：发布链曾断在「改完忘提交」——代码测绿后停在未提交，
# tag 从未创建 → Release workflow 从未触发，用户以为「打包没成功」。本脚本把
# 五步锁成原子动作 + 前置校验，任一步失败即中止。
#
# 用法:  ./scripts/release.sh 0.0.14
# 自动发布（2026-10-14 拍板）：确认闸已撤——前置校验全绿即一路推到 tag + 盯 CI。
# 安全全压在第 1 步：脏树 / 非 main / 落后分叉 / 版本格式 / 不高于最大 tag /
# tag 占用，任一命中即在任何对外副作用之前中止。
# CI 事实（.github/workflows/release.yml）：构建版本取自 tag（xcodebuild 位置参数
# 覆盖 MARKETING_VERSION），project.yml 的值只是本地默认——bump 它 = 维持仓库惯例
# （每版一笔 chore(release) commit），非发布必需但保持本地产物与线上默认一致。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { echo "release: $*" >&2; exit 1; }
info() { echo "==> $*"; }

VERSION="${1:-}"

# ---- 1) 前置校验（全绿前零副作用）----
[ -n "$VERSION" ] || die "用法: ./scripts/release.sh <X.Y.Z>（例: 0.0.14）"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "版本号格式非法: '$VERSION'（须 X.Y.Z，与 CI Resolve version 步同正则）"

# 工作树干净（含未跟踪新文件 = 会漏提交的改动）
DIRTY="$(git status --porcelain)"
[ -z "$DIRTY" ] || { echo "工作树不干净（先提交或还原这些改动再发布）:" >&2; echo "$DIRTY" >&2; exit 1; }

BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "main" ] || die "必须在 main 发布（当前: $BRANCH）"

git fetch origin main --quiet
LOCAL="$(git rev-parse main)"
REMOTE="$(git rev-parse origin/main)"
if [ "$LOCAL" != "$REMOTE" ]; then
  # 允许「本地领先远端」（未推的 commit = 本脚本要发布的正主，第 4 步推）；
  # 落后或分叉必须人工先处理（自动 rebase/merge = 拿发布链做合并，风险不对等）。
  git merge-base --is-ancestor "$REMOTE" "$LOCAL" \
    || die "main 落后或与 origin/main 分叉（本地 $LOCAL ≠ 远端 $REMOTE 且非快进）——先 pull/rebase 理顺再发布"
  info "main 领先 origin/main $(git rev-list --count "$REMOTE".."$LOCAL") 个 commit（第 4 步推送）"
fi

# 新版本必须严格高于远端最大 tag（防重发/降级；CI 侧无此闸，靠这里补）
git fetch origin --tags --quiet
LAST_TAG="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
if [ -n "$LAST_TAG" ]; then
  LAST="${LAST_TAG#v}"
  # 语义比较（X.Y.Z 逐段数字，无 sort -V 依赖的 awk 实现）
  HIGHER="$(awk -v a="$LAST" -v b="$VERSION" 'BEGIN{
    n=split(a,x,"."); m=split(b,y,".");
    if(n>3)n=3; if(m>3)m=3; k=(n>m)?n:m;
    for(i=1;i<=k;i++){ xi=i<=n?x[i]+0:0; yi=i<=m?y[i]+0:0;
      if(xi<yi){print "new";exit} if(xi>yi){print "old";exit} }
    print "same"}')"
  [ "$HIGHER" = "new" ] || die "版本 $VERSION 不高于已发布最大 tag $LAST_TAG（same/old=$HIGHER）"
fi

# gh 可用（第 7 步盯 CI 依赖）
command -v gh >/dev/null || die "需要 gh CLI（盯 CI 结果用）"
command -v xcodegen >/dev/null || info "提示: 本机无 xcodegen（不影响发布，CI 自装）"

# 幂等闸：同版本 tag 已存在 → 中止（防 bump 提交白做）
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
  && die "tag v$VERSION 本地已存在"
git ls-remote origin "refs/tags/v$VERSION" | grep -q . \
  && die "tag v$VERSION 已在远端（重发请升版本号）"

# ---- 2) bump project.yml（惯例: CURRENT_PROJECT_VERSION = patch 数）----
PATCH="${VERSION##*.}"
MARKETING_LINE="        MARKETING_VERSION: \"$VERSION\""
CURRENT_LINE="        CURRENT_PROJECT_VERSION: \"$PATCH\""
grep -Eq '^        MARKETING_VERSION: "[0-9]+\.[0-9]+\.[0-9]+"$' project.yml \
  || die "project.yml MARKETING_VERSION 行形态异常，拒绝机器改写"
grep -Eq '^        CURRENT_PROJECT_VERSION: "[0-9]+"$' project.yml \
  || die "project.yml CURRENT_PROJECT_VERSION 行形态异常，拒绝机器改写"
# 已是目标值（如上一轮中断残留）→ 视为无事发生，继续
if ! grep -Fxq "$MARKETING_LINE" project.yml || ! grep -Fxq "$CURRENT_LINE" project.yml; then
  perl -pi -e "s/^        MARKETING_VERSION: \".*\"\$/        MARKETING_VERSION: \"$VERSION\"/; s/^        CURRENT_PROJECT_VERSION: \".*\"\$/        CURRENT_PROJECT_VERSION: \"$PATCH\"/" project.yml
  git add project.yml
  # ---- 3) commit ----
  git commit -m "chore(release): bump version to $VERSION (MARKETING_VERSION/CURRENT_PROJECT_VERSION)"
  info "bump 已提交: $(git log -1 --oneline)"
else
  info "project.yml 已是 $VERSION（跳过 bump 提交）"
fi

# ---- 4) push main ----
git push origin main
info "main 已推送"

# ---- 5) tag + push（发布触发点，自动无人值守）----
# 自动发布（2026-10-14 改）：前置校验全绿即直打 tag，无 tty 人工确认闸。
# 安全全压在第 1 步——脏树/错版/降级/tag 占用/落后远端任一命中即已在此中止。
git tag -a "v$VERSION" -m "Release v$VERSION"
git push origin "v$VERSION"
info "tag v$VERSION 已推送 → Release workflow 触发"

# ---- 6) 盯 CI 到出结果（触发成功 ≠ 打包成功，一次验完）----
info "等待 Release run 出现（tag 触发有秒级延迟）…"
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --workflow=Release --branch "v$VERSION" --limit 1 \
            --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
  sleep 5
done
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || die "3 分钟内未见 Release run（去 Actions 页人工核）"
info "Release run: $RUN_ID（gh run watch $RUN_ID 可看实时日志）"
gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1 \
  || { echo "!! Release run 未成功，失败日志尾部：" >&2
       gh run view "$RUN_ID" --log-failed 2>&1 | tail -40
       die "run $RUN_ID 失败（上为日志）"
     }

# 产物核验：release 页 + 双 dmg 资产
gh release view "v$VERSION" --json tagName,publishedAt,assets \
  --jq '"发布成功: \(.tagName) @ \(.publishedAt)  资产: \([.assets[].name] | join(", "))"'
info "完成: https://github.com/gybcb/fly_commander/releases/tag/v$VERSION"
