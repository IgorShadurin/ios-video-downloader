#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="org.icorpvideo.VideoDownloader"
SCHEME="VideoDownloader"
PROJECT_FILE="$PROJECT_ROOT/VideoDownloader.xcodeproj"
DERIVED_DATA="/tmp/VideoDownloaderShowcaseDD"
FRAME_SCRIPT="/Users/test/XCodeProjects/APPLE_HELPERS/iphone17-frame.sh"
RAW_DIR="/tmp/video_downloader_showcase_raw"

if [[ ! -x "$FRAME_SCRIPT" ]]; then
  echo "Frame script not found or not executable: $FRAME_SCRIPT" >&2
  exit 1
fi

if [[ -z "${UDID:-}" ]]; then
  UDID=$(xcrun simctl list devices available | awk '
    BEGIN { in26_2 = 0 }
    /^-- iOS 26\.2 --$/ { in26_2 = 1; next }
    /^-- / { in26_2 = 0 }
    in26_2 && / iPhone 17 \(/ {
      if (match($0, /\(([A-F0-9-]+)\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ')
fi

if [[ -z "${UDID:-}" ]]; then
  UDID=$(xcrun simctl list devices available | awk '
    / iPhone 17 \(/ {
      if (match($0, /\(([A-F0-9-]+)\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ')
fi

if [[ -z "${UDID:-}" ]]; then
  echo "Could not find an available iPhone 17 simulator." >&2
  exit 1
fi

echo "Using simulator UDID: $UDID"

mkdir -p "$PROJECT_ROOT/showcase/high" "$PROJECT_ROOT/showcase/preview" "$RAW_DIR"

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true

rm -rf "$DERIVED_DATA"
xcodebuild -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Debug -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA" build -quiet

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/VideoDownloader.app"

capture_one() {
  local mode="$1"
  local step="$2"
  local name="$3"
  local wait_s="${4:-2.2}"
  local raw="$RAW_DIR/${name}_raw.png"

  xcrun simctl ui "$UDID" appearance "$mode"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -uiShowcaseStep "$step" >/dev/null

  sleep "$wait_s"
  xcrun simctl io "$UDID" screenshot "$raw" >/dev/null
  sips -g pixelWidth -g pixelHeight "$raw" >/dev/null

  "$FRAME_SCRIPT" "$raw" "$PROJECT_ROOT/showcase/high/${name}.png"
  magick "$PROJECT_ROOT/showcase/high/${name}.png" -filter Lanczos -resize 220x -strip \
    "$PROJECT_ROOT/showcase/preview/${name}.png"

  echo "Captured $name"
}

capture_one light main-videos main-videos 2.1
capture_one light demo-link demo-link 2.1
capture_one light downloading-process downloading-process 2.3
capture_one light video-menu-opened video-menu-opened 2.4
capture_one light video-export-opened video-export-opened 2.4
capture_one light rename-file rename-file 2.6
capture_one light paywall paywall-window 3.0
capture_one light vault-unlock-modal vault-unlock-modal 2.8
capture_one light vault-unlocked-videos vault-unlocked-videos 2.3

capture_one dark main-videos main-videos-dark 2.1
capture_one dark demo-link demo-link-dark 2.1
capture_one dark downloading-process downloading-process-dark 2.3
capture_one dark video-menu-opened video-menu-opened-dark 2.4
capture_one dark video-export-opened video-export-opened-dark 2.4
capture_one dark rename-file rename-file-dark 2.6
capture_one dark paywall paywall-window-dark 3.0
capture_one dark vault-unlock-modal vault-unlock-modal-dark 2.8
capture_one dark vault-unlocked-videos vault-unlocked-videos-dark 2.3

echo "High screenshots:"
ls -1 "$PROJECT_ROOT/showcase/high" | rg '^(main-videos|demo-link|downloading-process|video-menu-opened|video-export-opened|rename-file|paywall-window|vault-unlock-modal|vault-unlocked-videos)(-dark)?\.png$' | wc -l

echo "Preview screenshots:"
ls -1 "$PROJECT_ROOT/showcase/preview" | rg '^(main-videos|demo-link|downloading-process|video-menu-opened|video-export-opened|rename-file|paywall-window|vault-unlock-modal|vault-unlocked-videos)(-dark)?\.png$' | wc -l
