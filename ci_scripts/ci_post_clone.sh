#!/bin/sh
# Xcode Cloud hook (runs after clone, before the build): install kubectl so
# the "Bundle kubectl" build phase has a binary to copy into Contents/Helpers.
# Without it the phase just warns and the app falls back to PATH lookup.
set -e
brew install kubectl
