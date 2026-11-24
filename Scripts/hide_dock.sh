#!/bin/bash
# Hides the Dock on a CI runner for the UI tests, the screenshots and the demo
# video: the runner's screen is small, and the Dock would cover the bottom of
# a tall window.
#   Scripts/hide_dock.sh
set -euo pipefail

defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock
sleep 2
