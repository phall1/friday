#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED_SVG="151a2d26500c5c56201887add75c7d5a974506a1a93b3e31393f10468ca6417a"
EXPECTED_PNG="f2ad99d498e16646197d09bbb2d1b337994e1db788cadec38728dd251637fef1"

[[ "$(shasum -a 256 assets/icon.svg | cut -d' ' -f1)" == "$EXPECTED_SVG" ]]
[[ "$(shasum -a 256 assets/icon.png | cut -d' ' -f1)" == "$EXPECTED_PNG" ]]
[[ "$(sips -g pixelWidth assets/icon.png 2>/dev/null | awk '/pixelWidth:/{print $2}')" == "1024" ]]
[[ "$(sips -g pixelHeight assets/icon.png 2>/dev/null | awk '/pixelHeight:/{print $2}')" == "1024" ]]
printf 'Verified canonical Friday icon source and 1024x1024 PNG\n'
