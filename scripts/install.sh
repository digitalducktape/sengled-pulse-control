#!/bin/zsh
# Build PulseBar and install it to ~/Applications (no admin rights needed), then launch it.
set -euo pipefail
cd "${0:A:h}/.."
app=$(scripts/bundle.sh PulseBar)
mkdir -p ~/Applications
pkill -x PulseBar 2>/dev/null || true
rm -rf ~/Applications/PulseBar.app
cp -R "$app" ~/Applications/
open ~/Applications/PulseBar.app
echo "Installed ~/Applications/PulseBar.app"
