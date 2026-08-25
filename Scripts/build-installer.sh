#!/bin/bash
#
# Builds dist/trolley-<version>.dmg -- drag trolley.app to /Applications -- plus
# dist/trolley-app.zip, the archive `trolley update` downloads.
#
# Why an app bundle for a CLI: a flat package cannot be signed without a
# Developer ID *Installer* certificate, which this team does not have, and macOS
# refuses to open unsigned ones. Measured: productsign rejects the Application
# identity outright, and an unsigned pkg comes back Invalid from notarytool both
# bare and nested inside a signed dmg. Bundles and disk images sign with the
# certificate we do have.
#
# The bundle also lands in a directory the admin group can write, so both the
# install and every later `trolley update` finish without an admin prompt -- and
# TCC lists the app by name instead of showing a bare executable path.
set -euo pipefail

# Notarization is two round trips to Apple, several minutes each. Skipping it is
# for local builds only: the result installs and runs on this machine, but
# Gatekeeper will refuse it anywhere else.
SKIP_NOTARIZE=${TROLLEY_SKIP_NOTARIZE:-0}
for arg in "$@"; do
    case "$arg" in
        --skip-notarize|--no-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "error: 모르는 옵션 $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."
source Scripts/signing-keychain.sh

DIST=dist
DMGROOT="$DIST/dmgroot"
APP="$DMGROOT/trolley.app"

# Installed before the keychain is touched: the restore has to run even if the
# build dies halfway, or the user's keychain search list keeps the leftovers.
trap trolley_keychain_destroy EXIT

VERSION=$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' Sources/TrolleyKit/Version.swift)
if [ -z "$VERSION" ]; then
    echo "error: Sources/TrolleyKit/Version.swift에서 버전을 읽지 못했습니다." >&2
    exit 1
fi
echo "==> trolley $VERSION"

# --- 1. Universal release build ------------------------------------------------
echo "==> 유니버설 빌드 (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BINARY=.build/apple/Products/Release/trolley
[ -f "$BINARY" ] || { echo "error: $BINARY 가 없습니다." >&2; exit 1; }

# --- 2. Assemble and sign the bundle -------------------------------------------
echo "==> 서명용 임시 키체인 준비"
trolley_keychain_create
echo "==> 앱 번들 조립"
rm -rf "$DMGROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BINARY" "$APP/Contents/MacOS/trolley"
sed "s/@VERSION@/$VERSION/g" Scripts/app/Info.plist > "$APP/Contents/Info.plist"

# The icon is rendered by the binary we just built, from the same paths the
# widget draws -- so the icon and the folder pet cannot drift apart.
ICONSET="$DIST/trolley.iconset"
rm -rf "$ICONSET"
"$BINARY" export-icon --output "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/trolley.icns"
rm -rf "$ICONSET"

echo "==> 서명: $TROLLEY_SIGN_ID"
# Hardened runtime and a timestamp are both prerequisites for notarization.
# Signing the bundle signs its executable in place -- the code directory hashes
# Info.plist, which is why a binary signed on its own can never be dropped into
# a bundle later.
codesign --force --options runtime --timestamp \
    --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
TEAM=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
echo "==> TeamIdentifier=$TEAM"

# --- 3. Notarize --------------------------------------------------------------
if [ "$SKIP_NOTARIZE" = "1" ]; then
    APPLE_ID=""; APPLE_TEAM_ID=""; APPLE_APP_SPECIFIC_PASSWORD=""
else
    APPLE_ID="${APPLE_ID:-$(trolley_ssm APPLE_ID)}"
    APPLE_TEAM_ID="${APPLE_TEAM_ID:-$(trolley_ssm APPLE_TEAM_ID)}"
    APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-$(trolley_ssm APPLE_APP_SPECIFIC_PASSWORD)}"
fi

notarize() {
    local artifact="$1" label="$2"
    if [ "$SKIP_NOTARIZE" = "1" ]; then
        echo "==> $label 공증 생략 (--skip-notarize)"
        return 1
    fi
    if [ -z "$APPLE_ID" ] || [ -z "$APPLE_TEAM_ID" ] || [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
        echo "==> $label 공증 건너뜀: APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD 를 얻지 못했습니다."
        return 1
    fi
    echo "==> $label 공증 제출 (수 분 걸립니다)"
    xcrun notarytool submit "$artifact" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
}

# Stapling routinely fails for a while after Accepted, and on this machine it
# fails outright -- see README. Never fatal: without a staple Gatekeeper just
# checks notarization online instead.
staple_with_retry() {
    local artifact="$1"
    for attempt in 1 2 3 4 5; do
        if xcrun stapler staple "$artifact" >/dev/null 2>&1; then
            echo "==> 스테이플 완료: $(basename "$artifact")"
            return 0
        fi
        [ "$attempt" -lt 5 ] && sleep 60
    done
    echo "==> 스테이플 실패: $(basename "$artifact") — 공증 자체는 유효합니다."
    echo "    나중에 다시: xcrun stapler staple $artifact"
    return 1
}

# ditto rather than zip: everything in a bundle but the Mach-O carries its seal
# in extended attributes, and zip drops them.
mkdir -p "$DIST"
ZIP="$DIST/trolley-app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP" "앱" || true

# --- 4. Disk image ------------------------------------------------------------
echo "==> dmg 생성"
# The /Applications alias is what makes the window a drag target.
ln -s /Applications "$DMGROOT/Applications"
VOLUME="trolley $VERSION"
DMG="$DIST/trolley-$VERSION.dmg"
STAGING_DMG="$DIST/.trolley-rw.dmg"
rm -f "$DMG" "$STAGING_DMG"

# Built read-write first: the window layout lives in the volume's .DS_Store, so
# Finder has to be able to write to it before the image is compressed.
# Detach a leftover of the same name first, so this image gets the plain name.
hdiutil detach "/Volumes/$VOLUME" -force >/dev/null 2>&1 || true
hdiutil create -volname "$VOLUME" -srcfolder "$DMGROOT" -ov -format UDRW "$STAGING_DMG" >/dev/null
# grep rather than the last line: hdiutil prints a tab-separated table whose
# trailing line is not reliably the mount point, and an empty capture here fails
# silently -- the volume icon simply went missing the first time.
MOUNT=$(hdiutil attach "$STAGING_DMG" -nobrowse -noverify | grep -o '/Volumes/.*' | tail -1)
if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo "error: dmg 마운트 지점을 찾지 못했습니다." >&2
    exit 1
fi

# The name Finder is told must come from the mount point, not from what we asked
# for. A volume of the same name already attached -- a leftover from an earlier
# build or a manual check -- makes this one mount as "trolley 0.1.0 1", and
# scripting the requested name then decorates the stale volume instead. Measured:
# the layout silently went missing exactly that way.
VOLNAME=$(basename "$MOUNT")
# Cosmetic only: Finder scripting needs Automation permission, and a build on a
# machine that has not granted it should still produce a working image.
if ! osascript Scripts/dmg-layout.applescript "$VOLNAME" >/dev/null 2>&1; then
    echo "    창 배치 건너뜀: Finder 자동화 권한이 없거나 실패했습니다(기능에는 영향 없음)."
fi

# After the layout, never before: Finder deletes .VolumeIcon.icns while it works
# on the window, so an icon written first silently disappears -- measured.
cp "$APP/Contents/Resources/trolley.icns" "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT"
else
    echo "    볼륨 아이콘 플래그 건너뜀: SetFile 이 없습니다."
fi
sync
hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1

hdiutil convert "$STAGING_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$STAGING_DMG"
codesign --force --timestamp --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$DMG"

if notarize "$DMG" "dmg"; then
    staple_with_retry "$DMG" || true
fi
rm -rf "$DMGROOT"

echo
if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "완성: $DMG   (로컬 확인용 — 공증 없음, 배포 불가)"
else
    echo "완성: $DMG   (배포용 — 끌어다 놓기)"
fi
echo "      $ZIP        (trolley update 용 자산)"
