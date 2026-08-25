#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_name="Stay Awake"
temporary_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/stay-awake-build.XXXXXX")"
trap 'rm -rf "$temporary_build_dir"' EXIT

bundle_dir="$temporary_build_dir/$app_name.app"
contents_dir="$bundle_dir/Contents"
macos_dir="$contents_dir/MacOS"
binary_dir="$temporary_build_dir/Binaries"
output_dir="$project_dir/dist"
output_bundle_dir="$project_dir/dist/$app_name.app"
zip_path="$project_dir/dist/Stay-Awake.zip"
module_cache_dir="$project_dir/.build/ModuleCache"

mkdir -p "$macos_dir" "$binary_dir" "$output_dir" "$module_cache_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"

for architecture in arm64 x86_64; do
    xcrun swiftc \
        -O \
        -target "$architecture-apple-macosx13.0" \
        -module-cache-path "$module_cache_dir/$architecture" \
        -framework AppKit \
        -framework IOKit \
        "$project_dir/Sources/main.swift" \
        -o "$binary_dir/StayAwake-$architecture"
done

xcrun lipo -create \
    "$binary_dir/StayAwake-arm64" \
    "$binary_dir/StayAwake-x86_64" \
    -output "$macos_dir/StayAwake"

codesign --force --deep --sign - "$bundle_dir"

rm -rf "$output_bundle_dir"
ditto "$bundle_dir" "$output_bundle_dir"
xattr -cr "$output_bundle_dir" 2>/dev/null || true

rm -f "$zip_path"
ditto -c -k --sequesterRsrc --keepParent "$bundle_dir" "$zip_path"
xattr -d com.apple.FinderInfo "$output_bundle_dir" 2>/dev/null || true

echo "Built: $output_bundle_dir"
echo "Packaged: $zip_path"
