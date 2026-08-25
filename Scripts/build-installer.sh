#!/bin/bash
#
# Builds dist/trolley-<version>.pkg -- the double-clickable installer -- plus
# dist/trolley-universal, the signed binary `trolley update` downloads.
#
# The install path is fixed at /usr/local/trolley/bin/trolley on purpose:
# Accessibility and Screen Recording grants are keyed to the executable path, so
# a moving or versioned path would make users re-approve on every update.
#
# Signing reuses the Developer ID Application certificate the MAKi desktop
# release already ships with, pulled from the same SSM parameters. See
# Scripts/signing-keychain.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
source Scripts/signing-keychain.sh

PREFIX=/usr/local/trolley
IDENTIFIER=ink.markhub.trolley
DIST=dist
STAGE="$DIST/root"

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

# --- 2. Sign -------------------------------------------------------------------
echo "==> 서명용 임시 키체인 준비"
trolley_keychain_create
echo "==> 서명: $TROLLEY_SIGN_ID"
# Hardened runtime and a timestamp are both prerequisites for notarization.
codesign --force --options runtime --timestamp \
    --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$BINARY"
codesign --verify --strict --verbose=2 "$BINARY"
TEAM=$(codesign -dv --verbose=4 "$BINARY" 2>&1 | sed -n 's/^TeamIdentifier=//p')
echo "==> TeamIdentifier=$TEAM"

# --- 3. Notarize the binary ----------------------------------------------------
# The updater downloads this file directly, so it is worth notarizing on its own.
# A bare executable cannot be stapled -- there is nowhere to attach the ticket --
# so Gatekeeper checks it online when it checks at all.
APPLE_ID="${APPLE_ID:-$(trolley_ssm APPLE_ID)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-$(trolley_ssm APPLE_TEAM_ID)}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-$(trolley_ssm APPLE_APP_SPECIFIC_PASSWORD)}"

notarize() {
    local artifact="$1" label="$2"
    if [ -z "$APPLE_ID" ] || [ -z "$APPLE_TEAM_ID" ] || [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
        echo "==> $label 공증 건너뜀: APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD 를 얻지 못했습니다."
        return 0
    fi
    echo "==> $label 공증 제출 (수 분 걸립니다)"
    xcrun notarytool submit "$artifact" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
}

mkdir -p "$DIST"
ditto -c -k --keepParent "$BINARY" "$DIST/trolley-universal.zip"
notarize "$DIST/trolley-universal.zip" "바이너리"

# --- 4. Stage the payload ------------------------------------------------------
echo "==> 스테이징"
rm -rf "$STAGE"
mkdir -p "$STAGE$PREFIX/bin" "$STAGE/etc/paths.d"
install -m 755 "$BINARY" "$STAGE$PREFIX/bin/trolley"
# Puts trolley on PATH for new login shells without a symlink -- a symlink would
# make TCC key on the resolved path while the CLI reports the link.
echo "$PREFIX/bin" > "$STAGE/etc/paths.d/trolley"

# --- 5. Build the package ------------------------------------------------------
echo "==> pkgbuild"
pkgbuild \
    --root "$STAGE" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location / \
    --scripts Scripts/pkg/scripts \
    "$DIST/trolley-component.pkg" >/dev/null

echo "==> productbuild"
PKG="$DIST/trolley-$VERSION.pkg"
productbuild \
    --distribution Scripts/pkg/distribution.xml \
    --resources Scripts/pkg/resources \
    --package-path "$DIST" \
    "$PKG" >/dev/null

cp "$BINARY" "$DIST/trolley-universal"
rm -f "$DIST/trolley-component.pkg"
rm -rf "$STAGE"

# --- 6. Sign and notarize the package ------------------------------------------
# A pkg needs a Developer ID *Installer* certificate -- a different certificate
# from the Application one used above, and one this team does not have yet.
# notarytool rejects unsigned packages, so both steps wait on it together.
INSTALLER_ID=$(security find-identity -v "$TROLLEY_KEYCHAIN" 2>/dev/null \
    | awk -F'"' '/Developer ID Installer/ { print $2 }' | sed -n '1p')
if [ -n "$INSTALLER_ID" ]; then
    echo "==> productsign: $INSTALLER_ID"
    productsign --keychain "$TROLLEY_KEYCHAIN" --sign "$INSTALLER_ID" "$PKG" "$PKG.signed"
    mv "$PKG.signed" "$PKG"
    notarize "$PKG" "설치파일"
    xcrun stapler staple "$PKG"
else
    echo "==> pkg 서명·공증 건너뜀: Developer ID Installer 인증서가 없습니다."
    echo "    developer.apple.com 에서 한 번 발급해 SSM 에 넣으면 이 블록이 그대로 동작합니다."
    echo "    그전까지는 다른 맥에서 첫 실행 시 우클릭 → 열기가 필요합니다."
fi

echo
echo "완성: $PKG"
echo "      $DIST/trolley-universal      (trolley update 용 자산)"
echo "      $DIST/trolley-universal.zip  (공증 제출본)"
