set -euo pipefail
LAST=$(git log -1 --format=%ct)
NOW=$(date +%s)
DAYS=$(( (NOW - LAST) / 86400 ))
{
  echo "### 活跃度闸门"
  echo "- 事件: ${GITHUB_EVENT_NAME}"
  echo "- main 最后一次提交: $(date -u -d @$LAST '+%F %T UTC') → **${DAYS} 天前**"
  echo "- 阈值: ${THRESHOLD} 天"
} >> "$GITHUB_STEP_SUMMARY"
if [ "$FORCE" = "true" ]; then
  echo "手动强制构建 → 忽略闸门"; echo "active=true" >> "$GITHUB_OUTPUT"
elif [ "$DAYS" -le "$THRESHOLD" ]; then
  echo "项目活跃（${DAYS} ≤ ${THRESHOLD}）→ 继续构建"
  echo "active=true" >> "$GITHUB_OUTPUT"
else
  echo "项目 ${DAYS} 天无提交（> ${THRESHOLD}）→ 本次不编译"
  echo "active=false" >> "$GITHUB_OUTPUT"
fi
