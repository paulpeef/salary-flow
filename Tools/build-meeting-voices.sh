#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
src=.build/meeting-fluid
revision=915a392a3b214205fcf4860cc3608bde35891d03
if [[ ! -d "$src" ]]; then
  git clone --quiet --depth 1 --branch v0.9.1 https://github.com/FluidInference/FluidAudio.git "$src"
fi
[[ "$(git -C "$src" rev-parse HEAD)" == "$revision" ]] || { echo "Unexpected FluidAudio revision" >&2; exit 1; }
swift build --disable-sandbox --package-path Tools/MeetingVoices --scratch-path .build/meeting-helper -c release --product MeetingVoices
