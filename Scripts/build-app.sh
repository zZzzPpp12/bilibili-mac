#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/package-cache --config-path .build/config --security-path .build/security
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/package-cache --config-path .build/config --security-path .build/security)"
app_dir="$project_dir/.build/BiliMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swift Scripts/make-icon.swift "$project_dir/.build/AppIcon.iconset"
python3 Scripts/package-icon.py "$project_dir/.build/AppIcon.iconset" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$bin_dir/BiliMac" "$app_dir/Contents/MacOS/BiliMac"
cp LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$app_dir/Contents/Resources/THIRD_PARTY.md"
cp Vendor/BiliKitCore/LICENSE "$app_dir/Contents/Resources/BiliKit-LICENSE.txt"
cp Vendor/BiliKitCore/BILIBILI-NEXT-LICENSE "$app_dir/Contents/Resources/BilibiliNEXT-LICENSE.txt"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>BiliMac</string>
<key>CFBundleDisplayName</key><string>BiliMac</string>
<key>CFBundleIdentifier</key><string>dev.zzpp.BiliMac</string>
<key>CFBundleExecutable</key><string>BiliMac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
"$app_dir/Contents/MacOS/BiliMac" --check-startup
printf '\nBuilt: %s\n' "$app_dir"
