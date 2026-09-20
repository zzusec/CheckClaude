#!/usr/bin/env bash
# Build the CheckClaude Linux CLI, tray applet, tarball and .deb.
# Run this on the Linux build host (see build-remote.sh for the remote driver).
set -euo pipefail

cd "$(dirname "$0")"
DIST=dist
STAGE=$DIST/stage
VERSION=$(grep -oP 'const Version = "\K[^"]+' internal/check/run.go)
ARCH=amd64

echo "==> CheckClaude $VERSION ($ARCH)"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> go test"
go test ./...

echo "==> build CLI"
CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH go build -trimpath -ldflags="-s -w" \
    -o "$DIST/checkclaude" ./cmd/checkclaude

TRAY_BUILT=0
if pkg-config --exists gtk+-3.0 ayatana-appindicator3-0.1 2>/dev/null; then
    echo "==> build tray"
    gcc -O2 -Wall -o "$DIST/checkclaude-tray" tray/main.c \
        $(pkg-config --cflags --libs gtk+-3.0 ayatana-appindicator3-0.1)
    TRAY_BUILT=1
else
    echo "!!  跳过托盘：缺少 gtk+-3.0 / ayatana-appindicator3-0.1 开发包"
    echo "!!  安装：apt install libgtk-3-dev libayatana-appindicator3-dev"
fi

echo "==> tarball"
rm -rf "$STAGE"
mkdir -p "$STAGE/checkclaude-$VERSION"
cp "$DIST/checkclaude" "$STAGE/checkclaude-$VERSION/"
if [ $TRAY_BUILT -eq 1 ]; then
    cp "$DIST/checkclaude-tray" "$STAGE/checkclaude-$VERSION/"
fi
cp packaging/checkclaude.desktop packaging/checkclaude-autostart.desktop \
    "$STAGE/checkclaude-$VERSION/"
cat > "$STAGE/checkclaude-$VERSION/install.sh" <<'EOF'
#!/bin/sh
# Manual install for systems without dpkg.
set -e
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
cd "$(dirname "$0")"
install -m 0755 checkclaude /usr/bin/checkclaude
if [ -f checkclaude-tray ]; then
    install -m 0755 checkclaude-tray /usr/bin/checkclaude-tray
fi
if [ -d /usr/share/applications ]; then
    install -m 0644 checkclaude.desktop /usr/share/applications/checkclaude.desktop
fi
if [ -d /etc/xdg/autostart ]; then
    install -m 0644 checkclaude-autostart.desktop /etc/xdg/autostart/checkclaude.desktop
fi
echo "已安装。运行 checkclaude --check 开始体检。"
EOF
chmod +x "$STAGE/checkclaude-$VERSION/install.sh"
tar -czf "$DIST/checkclaude-linux-$ARCH.tar.gz" -C "$STAGE" "checkclaude-$VERSION"

if command -v dpkg-deb >/dev/null 2>&1; then
    echo "==> deb"
    PKG=$STAGE/deb
    mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/applications" "$PKG/etc/xdg/autostart"
    sed "s/__VERSION__/$VERSION/" packaging/debian/control > "$PKG/DEBIAN/control"
    install -m 0755 packaging/debian/postinst "$PKG/DEBIAN/postinst"
    install -m 0755 "$DIST/checkclaude" "$PKG/usr/bin/checkclaude"
    if [ $TRAY_BUILT -eq 1 ]; then
        install -m 0755 "$DIST/checkclaude-tray" "$PKG/usr/bin/checkclaude-tray"
    fi
    install -m 0644 packaging/checkclaude.desktop "$PKG/usr/share/applications/checkclaude.desktop"
    install -m 0644 packaging/checkclaude-autostart.desktop "$PKG/etc/xdg/autostart/checkclaude.desktop"
    dpkg-deb --root-owner-group --build "$PKG" "$DIST/checkclaude_${VERSION}_${ARCH}.deb" >/dev/null
else
    echo "!!  跳过 .deb：缺少 dpkg-deb"
fi

rm -rf "$STAGE"
echo "==> 产物"
ls -lh "$DIST" | tail -n +2
