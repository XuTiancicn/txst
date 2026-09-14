set -o pipefail
chmod +x scripts/build_gki_aosp.sh scripts/compile_kernel.sh
set +e
bash scripts/build_gki_aosp.sh > gki-build.log 2>&1
rc=$?
set -e
grep -nE '^I: |^W: |^E: ' gki-build.log | tail -70 || true
if [ "$rc" -ne 0 ]; then
  echo "===== 关键错误行 ====="
  grep -nE "error:|Error [0-9]+|Killed|fatal|No space left|undefined reference|E: " gki-build.log | head -40 || true
  tail -60 gki-build.log
  echo "::error::AOSP GKI 内核构建失败 rc=$rc"
fi
exit "$rc"
