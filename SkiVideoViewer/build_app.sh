#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
build_cache="$script_dir/.build/module-cache"
bundle_path="$script_dir/SkiVideoViewer.app"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$build_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_cache"

mkdir -p "$build_cache"
cd "$script_dir"
swift build --disable-sandbox -c release
# Asked, not hard-coded: Swift 6.4's default build system (swiftbuild) puts
# products under .build/out/Products/Release, not the old
# .build/arm64-apple-macosx/release, and a fixed path broke this script.
bin_path=$(swift build --disable-sandbox -c release --show-bin-path)

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$script_dir/AppBundle/Info.plist" "$bundle_path/Contents/Info.plist"
cp "$bin_path/SkiVideoViewer" "$bundle_path/Contents/MacOS/SkiVideoViewer"
cp "$script_dir/AppBundle/AlbisViewerIcon.png" "$bundle_path/Contents/Resources/AlbisViewerIcon.png"
codesign --force --sign - "$bundle_path" >/dev/null
touch "$bundle_path"
print "$bundle_path"
