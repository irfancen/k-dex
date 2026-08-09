#!/bin/sh
# Xcode Cloud hook (runs after clone, before the build): fetch the kubectl
# that the "Bundle kubectl" build phase copies into Contents/Helpers.
#
# Pinned and checksummed: the shipped kubectl must be a property of the
# commit, not of whatever a package manager served that day — the binary
# ends up Developer ID-signed and notarized inside the app.
# On bumping KUBECTL_VERSION, refresh the hash from
#   https://dl.k8s.io/release/<version>/bin/darwin/arm64/kubectl.sha256
set -eu

KUBECTL_VERSION="v1.36.3"
KUBECTL_SHA256="fc8582acde13869a606730a79379d6515f30c68afcced0b5ac8789d5d002b7d6"

# Xcode Cloud runners are Apple silicon; the pinned hash is darwin/arm64.
if [ "$(uname -m)" != "arm64" ]; then
    echo "error: expected an arm64 runner; add a hash for $(uname -m) before building here" >&2
    exit 1
fi

TMP=$(mktemp -d)
curl -fsSLo "$TMP/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl"
echo "${KUBECTL_SHA256}  $TMP/kubectl" | shasum -a 256 -c -
install -m 0755 "$TMP/kubectl" /opt/homebrew/bin/kubectl
rm -rf "$TMP"
/opt/homebrew/bin/kubectl version --client
