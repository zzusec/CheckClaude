#!/usr/bin/env bash
# Drive build.sh on the Ubuntu amd64 build host and pull the artifacts back.
# Host defaults to the us2 build box; override with LINUX_HOST=...
set -euo pipefail

cd "$(dirname "$0")"
HOST=${LINUX_HOST:-root@us2.llkan.com}
REMOTE_DIR=${LINUX_BUILD_DIR:-/tmp/checkclaude-build}

echo "==> 同步源码到 $HOST:$REMOTE_DIR"
ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
rsync -az --delete \
    --exclude dist/ --exclude '*.tar.gz' --exclude '*.deb' \
    ./ "$HOST:$REMOTE_DIR/"

echo "==> 远端构建"
ssh "$HOST" "cd '$REMOTE_DIR' && PATH=/usr/local/go/bin:\$PATH bash build.sh"

echo "==> 回拉产物"
mkdir -p dist
rsync -az "$HOST:$REMOTE_DIR/dist/" dist/

ls -lh dist
