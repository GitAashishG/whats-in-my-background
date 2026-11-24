#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name='What’s in My Background.app'
destination="$root/dist/$name"
mkdir -p "$root/dist"
stage="$(mktemp -d "$root/dist/.package-XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/$name"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/BackgroundDesk.iconset"
swift build --package-path "$root" -c release
install -m 755 "$root/.build/release/BackgroundDesk" "$app/Contents/MacOS/BackgroundDesk"
install -m 644 "$root/Resources/Info.plist" "$app/Contents/Info.plist"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale)); suffix=''; [[ $scale -eq 1 ]] || suffix='@2x'
        /usr/bin/sips -s format png -z "$pixels" "$pixels" "$root/Resources/CurtainFox.svg" \
            --out "$stage/BackgroundDesk.iconset/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
install -m 644 "$stage/BackgroundDesk.iconset/icon_128x128@2x.png" "$app/Contents/Resources/CurtainFox.png"
/usr/bin/iconutil -c icns "$stage/BackgroundDesk.iconset" -o "$app/Contents/Resources/BackgroundDesk.icns"
/usr/bin/codesign --force --sign - "$app"
if [[ -e "$destination" || -L "$destination" ]]; then
    [[ ! -L "$destination" && "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist")" == 'local.whatsinmybackground.app' ]] || { echo 'Unexpected destination; refusing to replace it.' >&2; exit 1; }
    mv "$destination" "$stage/previous.app"
fi
if ! mv "$app" "$destination"; then
    [[ ! -d "$stage/previous.app" ]] || mv "$stage/previous.app" "$destination"
    exit 1
fi
printf 'Built %s\n' "$destination"
