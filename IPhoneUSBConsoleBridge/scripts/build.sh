#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA="${PROJECT_DIR}/build/DerivedData"
OUTPUT_DIR="${PROJECT_DIR}/build/Release"
# A stable Apple-issued signature preserves macOS capture permissions across
# rebuilds. Deployment may pin a specific hash with IUSC_SIGNING_IDENTITY.
SIGNING_IDENTITY="${IUSC_SIGNING_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning |
      /usr/bin/sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development:.*/\1/p' |
      /usr/bin/head -n 1
  )"
fi
if [[ -z "${SIGNING_IDENTITY}" ]] ||
   ! security find-identity -v -p codesigning | grep -Fq "${SIGNING_IDENTITY}"; then
  echo "A valid Apple Development signing identity is required." >&2
  exit 1
fi

cd "${PROJECT_DIR}"
xcodegen generate --spec project.yml
xcodebuild \
  -project IPhoneUSBConsole.xcodeproj \
  -scheme IPhoneUSBConsole \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

mkdir -p "${OUTPUT_DIR}"
RELEASE_APP="${OUTPUT_DIR}/iPhone USB Driver.app"
EXPECTED_RELEASE_APP="${PROJECT_DIR}/build/Release/iPhone USB Driver.app"
if [[ "${RELEASE_APP}" != "${EXPECTED_RELEASE_APP}" ]]; then
  echo "Refusing to replace unexpected Release path: ${RELEASE_APP}" >&2
  exit 1
fi
rm -rf -- "${RELEASE_APP}"
ditto \
  "${DERIVED_DATA}/Build/Products/Release/iPhone USB Driver.app" \
  "${RELEASE_APP}"

codesign \
  --force \
  --sign "${SIGNING_IDENTITY}" \
  --entitlements "${PROJECT_DIR}/IPhoneUSBConsole/Resources/IPhoneUSBConsole.entitlements" \
  --timestamp=none \
  "${RELEASE_APP}"
codesign --verify --deep --strict "${RELEASE_APP}"
echo "${RELEASE_APP}"
