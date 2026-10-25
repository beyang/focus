#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_IMAGE="${1:-$SCRIPT_DIR/focus-shutter.png}"
APPICONSET_DIR="${2:-$SCRIPT_DIR/Focus/Assets.xcassets/AppIcon.appiconset}"

if [[ ! -f "$INPUT_IMAGE" ]]; then
  echo "Input image not found: $INPUT_IMAGE" >&2
  echo "Usage: $0 [input_png] [appiconset_dir]" >&2
  exit 1
fi

if [[ ! -d "$APPICONSET_DIR" ]]; then
  echo "AppIcon set directory not found: $APPICONSET_DIR" >&2
  echo "Usage: $0 [input_png] [appiconset_dir]" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "This script requires 'sips' (available on macOS)." >&2
  exit 1
fi

input_width="$(sips -g pixelWidth "$INPUT_IMAGE" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
input_height="$(sips -g pixelHeight "$INPUT_IMAGE" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"

if [[ -z "$input_width" || -z "$input_height" ]]; then
  echo "Could not read input image dimensions: $INPUT_IMAGE" >&2
  exit 1
fi

if [[ "$input_width" != "$input_height" ]]; then
  echo "Input image must be square to avoid distortion (got ${input_width}x${input_height})." >&2
  exit 1
fi

targets=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

echo "Generating app icon assets from: $INPUT_IMAGE"
echo "Writing to: $APPICONSET_DIR"

for target in "${targets[@]}"; do
  filename="${target%%:*}"
  size="${target##*:}"
  output_path="$APPICONSET_DIR/$filename"

  sips -z "$size" "$size" "$INPUT_IMAGE" --out "$output_path" >/dev/null
  echo "  wrote $filename (${size}x${size})"
done

echo "Done."
