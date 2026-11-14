#!/bin/sh
# Package an installed unn prefix as a release tarball.
#
#   packaging/package-release.sh <gnu|musl> [prefix] [version]
#
# <prefix> defaults to zig-out and must contain bin/unn plus share/. <version>
# defaults to the release_version in build.zig. Writes
# release/unn-<version>-linux-<arch>-<libc>.tar.gz.
set -eu

libc=${1:-}
prefix=${2:-zig-out}
version=${3:-}

case $libc in
    gnu | musl) ;;
    *)
        echo "usage: $0 <gnu|musl> [prefix] [version]" >&2
        exit 2
        ;;
esac

if [ -z "$version" ]; then
    version=$(sed -n 's/^const release_version: std\.SemanticVersion = \.{ \.major = \([0-9]*\), \.minor = \([0-9]*\), \.patch = \([0-9]*\) };$/\1.\2.\3/p' build.zig)
fi
if [ -z "$version" ]; then
    echo "cannot determine the version; pass it as the third argument" >&2
    exit 1
fi

if [ ! -x "$prefix/bin/unn" ]; then
    echo "no binary at $prefix/bin/unn; run zig build first" >&2
    exit 1
fi

name=unn-$version-linux-$(uname -m)-$libc
stage=release/$name

rm -rf "$stage"
mkdir -p "$stage"
cp -a "$prefix"/. "$stage"/

# Release artifacts carry no debug info.
if command -v strip >/dev/null 2>&1; then
    strip --strip-debug "$stage/bin/unn"
fi

tar -C release -czf "release/$name.tar.gz" "$name"
rm -rf "$stage"

echo "release/$name.tar.gz"