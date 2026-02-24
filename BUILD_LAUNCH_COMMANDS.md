# Build and Launch Commands (iOS Simulator)

## 1) Find the currently booted simulator

```sh
xcrun simctl list devices booted
```

## 2) Get the booted iPhone 17 device ID

```sh
DEVICE_ID=$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone 17 .*Booted/ {print $2; exit}')
echo "$DEVICE_ID"
```

## 3) Build for the currently booted iPhone 17

```sh
xcodebuild -project AwesomeApp.xcodeproj -scheme AwesomeApp -destination "id=$DEVICE_ID" build
```

## 4) Install and launch on that simulator

```sh
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug-iphonesimulator/AwesomeApp.app' -print0 | xargs -0 ls -td | head -n 1)

xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl launch "$DEVICE_ID" org.video.ai.VideoDownloader
```

## 5) One-shot command (build + install + launch)

```sh
set -euo pipefail
DEVICE_ID=$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone 17 .*Booted/ {print $2; exit}')
xcodebuild -project AwesomeApp.xcodeproj -scheme AwesomeApp -destination "id=$DEVICE_ID" build
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug-iphonesimulator/AwesomeApp.app' -print0 | xargs -0 ls -td | head -n 1)
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
xcrun simctl launch "$DEVICE_ID" org.video.ai.VideoDownloader
```

## 6) Capture build log

```sh
set -o pipefail && xcodebuild -project AwesomeApp.xcodeproj -scheme AwesomeApp -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tee /tmp/xcodebuild.log
```
