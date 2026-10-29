#!/bin/sh
# Builds a universal (arm64 + x86_64) release binary into bin/ for the npm package.
set -eu
cd "$(dirname "$0")/.."

# The server reports its version to MCP clients; keep it in step with package.json.
pkg_version=$(node -p 'require("./package.json").version')
swift_version=$(sed -n 's/^let serverVersion = "\(.*\)"$/\1/p' Sources/macos-screencap-mcp/Version.swift)
if [ "$pkg_version" != "$swift_version" ]; then
    echo "Version mismatch: package.json $pkg_version, Version.swift $swift_version" >&2
    exit 1
fi

swift build -c release --arch arm64 --arch x86_64
bin_path=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
mkdir -p bin
cp "$bin_path/macos-screencap-mcp" bin/macos-screencap-mcp
chmod 755 bin/macos-screencap-mcp
echo "Built bin/macos-screencap-mcp ($(lipo -archs bin/macos-screencap-mcp)) v$pkg_version"
