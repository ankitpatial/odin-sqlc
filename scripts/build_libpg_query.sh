#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor/libpg_query"
VERSION="17-6.2.0"

if [ -f "$VENDOR_DIR/lib/libpg_query.a" ]; then
    echo "libpg_query already built at $VENDOR_DIR/lib/libpg_query.a"
    exit 0
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Cloning libpg_query $VERSION..."
git clone --depth 1 --branch "$VERSION" https://github.com/pganalyze/libpg_query.git "$TEMP_DIR/libpg_query"

echo "Building..."
cd "$TEMP_DIR/libpg_query"
make build

echo "Installing to $VENDOR_DIR..."
mkdir -p "$VENDOR_DIR/lib" "$VENDOR_DIR/include"
cp libpg_query.a "$VENDOR_DIR/lib/"
cp pg_query.h "$VENDOR_DIR/include/"

echo "Done. Library: $VENDOR_DIR/lib/libpg_query.a"
echo "Done. Header:  $VENDOR_DIR/include/pg_query.h"
