set -x
DEB=$(ls out-adapt/*.deb | head -1)
dpkg-deb -I "$DEB" | head -20
dpkg-deb -c "$DEB" | grep -E 'droidian-perf|perf-guard|droid-vendor-overlay' || true
T=$(mktemp -d); dpkg-deb -x "$DEB" "$T"
grep -n 'performance\|pkill\|ctl.stop' "$T/usr/bin/droidian-perf.sh" | head
cat "$T/usr/lib/droid-vendor-overlay/etc/thermal-engine.conf"
