set -uo pipefail
if [ -f gki-boot/boot.img ]; then
  cp gki-boot/boot.img boot-gki.img
  echo "GKI 内核来源: 本次 workflow 重编"
  echo "note=本次 workflow 重编" >> "$GITHUB_OUTPUT"
  exit 0
fi
TAG=$(gh release list --limit 200 --json tagName --jq '.[].tagName' 2>/dev/null \
        | grep -E '^gki-[0-9]+$' | head -1 || true)
if [ -z "$TAG" ]; then
  echo "::warning::没有 gki-* Release 可下载，整刷包里不带 GKI 内核（其余照常）"
  exit 0
fi
mkdir -p gki-dl
gh release download "$TAG" --pattern boot.img --dir gki-dl
cp gki-dl/boot.img boot-gki.img
echo "GKI 内核来源: Release $TAG"
echo "note=Release $TAG" >> "$GITHUB_OUTPUT"
