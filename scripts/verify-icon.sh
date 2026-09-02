#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED_SVG="f4641d70847800c663c0db41a49d8bd001e3b8129b34ce3cf744197a610ccd1b"
EXPECTED_PNG="f6f49cc70a1185f3867d3605b85b62de5cc1e74293d51ecea85b755adca41ba0"

[[ "$(shasum -a 256 assets/icon.svg | cut -d' ' -f1)" == "$EXPECTED_SVG" ]]
[[ "$(shasum -a 256 assets/icon.png | cut -d' ' -f1)" == "$EXPECTED_PNG" ]]
[[ "$(sips -g pixelWidth assets/icon.png 2>/dev/null | awk '/pixelWidth:/{print $2}')" == "1024" ]]
[[ "$(sips -g pixelHeight assets/icon.png 2>/dev/null | awk '/pixelHeight:/{print $2}')" == "1024" ]]
printf 'Verified canonical Friday icon source and 1024x1024 PNG\n'
