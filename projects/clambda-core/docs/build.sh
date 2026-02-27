#!/bin/bash
# build.sh — Build Clawmacs docs site using pandoc
#
# Usage: bash docs/build.sh [output-dir]
# Default output: docs/_site/
#
# Requirements: pandoc (sudo apt install pandoc)

set -euo pipefail

DOCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$DOCS_DIR/_site}"
TEMPLATE="$DOCS_DIR/_template.html"

if ! command -v pandoc &>/dev/null; then
  echo "ERROR: pandoc not found. Install with: sudo apt install pandoc"
  exit 1
fi

echo "Building Clawmacs docs..."
echo "  Source: $DOCS_DIR"
echo "  Output: $OUTPUT_DIR"

# Clean and create output dir
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/{getting-started,configuration,architecture,channels,api,tools,deployment}

# Convert each markdown file
convert() {
  local src="$1"
  local dst="$2"
  local title
  title=$(head -1 "$src" | sed 's/^#* *//')
  mkdir -p "$(dirname "$dst")"
  pandoc \
    --from=markdown \
    --to=html5 \
    --standalone \
    --template="$TEMPLATE" \
    --metadata title="$title" \
    --highlight-style=zenburn \
    --wrap=none \
    -o "$dst" \
    "$src"
  echo "  ✓ $(basename "$src") → $(basename "$dst")"
}

# Root
convert "$DOCS_DIR/index.md"                          "$OUTPUT_DIR/index.html"

# Getting Started
convert "$DOCS_DIR/getting-started/README.md"          "$OUTPUT_DIR/getting-started/README.html"
convert "$DOCS_DIR/getting-started/installation.md"    "$OUTPUT_DIR/getting-started/installation.html"

# Configuration
convert "$DOCS_DIR/configuration/init-lisp.md"        "$OUTPUT_DIR/configuration/init-lisp.html"

# Architecture
convert "$DOCS_DIR/architecture/index.md"             "$OUTPUT_DIR/architecture/index.html"

# Channels
convert "$DOCS_DIR/channels/index.md"                 "$OUTPUT_DIR/channels/index.html"
convert "$DOCS_DIR/channels/telegram.md"              "$OUTPUT_DIR/channels/telegram.html"
convert "$DOCS_DIR/channels/irc.md"                   "$OUTPUT_DIR/channels/irc.html"

# API
convert "$DOCS_DIR/api/index.md"                      "$OUTPUT_DIR/api/index.html"
convert "$DOCS_DIR/api/tools.md"                      "$OUTPUT_DIR/api/tools.html"

# Tools
convert "$DOCS_DIR/tools/custom-tools.md"             "$OUTPUT_DIR/tools/custom-tools.html"

# Deployment
convert "$DOCS_DIR/deployment/index.md"               "$OUTPUT_DIR/deployment/index.html"

# Copy template CSS inline (already in HTML template)
# Add a .nojekyll file (required for GitHub Pages to serve files starting with _)
touch "$OUTPUT_DIR/.nojekyll"

echo ""
echo "Done! Site built in: $OUTPUT_DIR"
echo "Pages: $(find "$OUTPUT_DIR" -name '*.html' | wc -l) HTML files"
