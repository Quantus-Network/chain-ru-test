#!/bin/bash

# This script generates the 'live-resonance.json' chain specification from a specific git release tag.
# This ensures that the genesis state is transparently and reproducibly built from a known version of the runtime code.
# The script uses the WASM runtime artifacts from GitHub releases (built with srtool) instead of local builds.

set -e

# Check if a release tag is provided
if [ -z "$1" ]; then
  echo "❌ Error: No release tag provided."
  echo "Usage: $0 <release_tag>"
  echo "Example: $0 v0.0.7-test-genesis"
  exit 1
fi

RELEASE_TAG=$1
OUTPUT_FILE="node/src/chain-specs/live-resonance.json" # Directly overwrite the existing spec file
QUANTUS_NODE_BIN="./target/release/quantus-node"
# This is the chain spec identifier that builds the genesis state from code, rather than loading from a file.
CHAIN_ID="live_resonance_local"
GITHUB_REPO="Quantus-Network/chain-ru-test"
WBUILD_DIR="target/release/wbuild/quantus-runtime"

echo "🔄 Checking current git status..."
if ! git diff-index --quiet HEAD --; then
    echo "❌ Error: Your working directory is not clean. Please commit or stash your changes before running this script."
    exit 1
fi

echo "⬇️ Fetching latest tags from origin..."
git fetch --all --tags

BRANCH_NAME="genesis_t2/$RELEASE_TAG"
echo "✨ Creating and switching to new branch '$BRANCH_NAME'..."
git checkout -b "$BRANCH_NAME" "tags/$RELEASE_TAG"

echo "📁 Creating wbuild directory if it doesn't exist..."
mkdir -p "$WBUILD_DIR"

echo "🌐 Fetching runtime spec_version from GitHub release..."
# First, get the list of release assets to find the spec_version
RELEASE_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/tags/$RELEASE_TAG"
ASSETS_JSON=$(curl -fsSL "$RELEASE_API_URL" | jq -r '.assets[] | select(.name | contains("quantus-runtime-v")) | .name' | head -1)
if [ -z "$ASSETS_JSON" ]; then
    echo "❌ Error: Could not find runtime assets in release $RELEASE_TAG."
    exit 1
fi

SPEC_VERSION=$(echo "$ASSETS_JSON" | grep -o 'v[0-9]\+' | sed 's/v//')

# Now try to download the srtool output JSON to get additional metadata
TEMP_JSON=$(mktemp)
if curl -fsSL "https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/quantus-runtime-srtool-output-v${SPEC_VERSION}.json" -o "$TEMP_JSON" 2>/dev/null; then
    echo "✅ Downloaded srtool output for additional metadata."
else
    echo "⚠️  Warning: Could not download srtool output, continuing with spec_version from asset names."
fi

rm -f "$TEMP_JSON"

if [ -z "$SPEC_VERSION" ] || [ "$SPEC_VERSION" = "null" ]; then
    echo "❌ Error: Could not determine spec_version from release."
    exit 1
fi

echo "📋 Using spec_version: $SPEC_VERSION"

echo "⬇️ Downloading runtime WASM files from GitHub release..."

# Download compact WASM
COMPACT_WASM_URL="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/quantus-runtime-v${SPEC_VERSION}.compact.wasm"
echo "Downloading: $COMPACT_WASM_URL"
if ! curl -fsSL "$COMPACT_WASM_URL" -o "$WBUILD_DIR/quantus_runtime.compact.wasm"; then
    echo "❌ Error: Failed to download compact WASM runtime."
    exit 1
fi

# Download compressed WASM
COMPRESSED_WASM_URL="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/quantus-runtime-v${SPEC_VERSION}.compact.compressed.wasm"
echo "Downloading: $COMPRESSED_WASM_URL"
if ! curl -fsSL "$COMPRESSED_WASM_URL" -o "$WBUILD_DIR/quantus_runtime.compact.compressed.wasm"; then
    echo "❌ Error: Failed to download compressed WASM runtime."
    exit 1
fi

# Copy compact WASM as the main WASM (since we don't have uncompressed in releases)
cp "$WBUILD_DIR/quantus_runtime.compact.wasm" "$WBUILD_DIR/quantus_runtime.wasm"

echo "✅ Runtime WASM files downloaded and placed in $WBUILD_DIR"

echo "🚀 Building quantus-node with downloaded runtime WASM at release '$RELEASE_TAG'..."
# Build without cleaning to preserve the WASM files we just downloaded
# Skip WASM build since we're using the downloaded ones
SKIP_WASM_BUILD=1 cargo build --release

if [ ! -f "$QUANTUS_NODE_BIN" ]; then
    echo "❌ Build failed. Quantus node binary not found."
    exit 1
fi

echo "✅ Node built successfully with downloaded runtime WASM."

echo "🔧 Generating raw chain spec from '$CHAIN_ID'..."
$QUANTUS_NODE_BIN build-spec --chain "$CHAIN_ID" --raw > "$OUTPUT_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "❌ Failed to generate chain spec. The output file is empty."
  exit 1
fi

echo "✅ Chain spec generated successfully."
echo "📄 The chain spec at '$OUTPUT_FILE' has been updated."
echo "🎉 Genesis generation complete."
echo ""
echo "ℹ️ You are now on a new branch named '$BRANCH_NAME'."
echo "   Please review and commit the changes to '$OUTPUT_FILE'."
echo "   Example: git add $OUTPUT_FILE && git commit -m \"feat: generate genesis spec from $RELEASE_TAG\"" 