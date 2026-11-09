#!/bin/zsh
# Builds FingerprintHelper/build/olaz-fingerprint-helper as a universal (arm64 + amd64) binary.
# make-app.sh copies it into the app bundle; without it Olaz falls back to URLSession.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v go >/dev/null || { echo "warning: Go toolchain not found — the fingerprint helper is not built; Olaz will use URLSession" >&2; exit 0; }

cd FingerprintHelper
export CGO_ENABLED=0
mkdir -p build
go build -trimpath -ldflags="-s -w" -o build/helper-arm64 .
GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o build/helper-amd64 .
lipo -create -output build/olaz-fingerprint-helper build/helper-arm64 build/helper-amd64
rm build/helper-arm64 build/helper-amd64
echo "Built FingerprintHelper/build/olaz-fingerprint-helper ($(du -h build/olaz-fingerprint-helper | cut -f1))"
