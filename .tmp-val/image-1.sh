sudo rm -rf /opt/hostedtoolcache /usr/share/dotnet /usr/local/lib/android \
            /usr/share/swift /usr/local/share/boost 2>/dev/null || true
df -h / | tail -1
