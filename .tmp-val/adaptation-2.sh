set -o pipefail
chmod +x custom/scripts/build-adaptation-deb.sh
set +e
WORK="$PWD/work-adapt" OUT="$PWD/out-adapt" \
  bash -x ./custom/scripts/build-adaptation-deb.sh > adapt-build.log 2>&1
rc=$?
set -e
echo "=========== adaptation 构建日志（尾部 80 行） ==========="
tail -80 adapt-build.log || true
if [ "$rc" -ne 0 ]; then
  echo "::error::adaptation 编包失败 rc=$rc"
  grep -aE '^(E: |dh_|dpkg-|make|sed|cp:|.*error:|.*Error |Unmet|unmet|No such|cannot|not found)' \
    adapt-build.log | tail -8 | while IFS= read -r l; do
      echo "::error::${l//%/%%}"
    done || true
  exit "$rc"
fi
