#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:-}"

if [[ -z "${VERSION}" ]]; then
  echo "Usage: $0 <plotly-version>"
  echo "Example: $0 2.35.2"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_PATH="${ROOT_DIR}/web/assets/plotly.min.js"
VERSION_PATH="${ROOT_DIR}/web/assets/plotly.version"
TMP_PATH="${ASSET_PATH}.tmp"
URL="https://cdn.plot.ly/plotly-${VERSION}.min.js"

echo "Downloading Plotly ${VERSION}..."
curl -fL "${URL}" -o "${TMP_PATH}"
mv "${TMP_PATH}" "${ASSET_PATH}"
printf '%s\n' "${VERSION}" > "${VERSION_PATH}"

echo "Updated ${ASSET_PATH}"
echo "Recorded version in ${VERSION_PATH}"
