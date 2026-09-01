#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
UPDATES_DIR="$ROOT/updates"
NOTES="$UPDATES_DIR/release-notes.md"
SKIP_BUILD=0
TEMP_DIR=""

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "${TEMP_DIR:t}" == drivegauge-release.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
elif [[ $# -gt 0 ]]; then
  print -ru2 -- "Использование: scripts/prepare-release.sh [--skip-build]"
  exit 2
fi

[[ "$SKIP_BUILD" == "1" ]] || bash "$ROOT/scripts/build-app.sh"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$PLIST")"
VERSIONED_DMG="$ROOT/dist/DriveGauge-${APP_VERSION}-arm64.dmg"
STABLE_DMG="$ROOT/dist/DriveGauge-stable.dmg"
[[ -s "$VERSIONED_DMG" && -s "$STABLE_DMG" ]] || { print -ru2 -- "DMG не найден"; exit 1; }
[[ -s "$NOTES" ]] || { print -ru2 -- "Описание релиза не найдено"; exit 1; }

SPARKLE_ROOT="$(zsh "$ROOT/scripts/fetch-sparkle.sh")"
TEMP_DIR="$(mktemp -d -t drivegauge-release.XXXXXX)"
ARCHIVES="$TEMP_DIR/archives"
mkdir -p "$ARCHIVES" "$UPDATES_DIR"
cp "$STABLE_DMG" "$ARCHIVES/DriveGauge-stable.dmg"
cp "$NOTES" "$ARCHIVES/DriveGauge-stable.md"

"$SPARKLE_ROOT/bin/generate_appcast" \
  --account drivegauge \
  --download-url-prefix "https://github.com/Coloded/DriveGauge/releases/latest/download/" \
  --link "https://github.com/Coloded/DriveGauge" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$TEMP_DIR/appcast.xml" \
  "$ARCHIVES"

grep -Fq "sparkle:edSignature=" "$TEMP_DIR/appcast.xml"
grep -Fq "<sparkle:version>$BUILD_VERSION</sparkle:version>" "$TEMP_DIR/appcast.xml"
grep -Fq "<sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>" "$TEMP_DIR/appcast.xml"
cp "$TEMP_DIR/appcast.xml" "$UPDATES_DIR/appcast.xml"
print -r -- "Релиз DriveGauge ${APP_VERSION} (build ${BUILD_VERSION}) подготовлен"
print -r -- "$UPDATES_DIR/appcast.xml"
