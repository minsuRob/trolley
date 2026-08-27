#!/bin/bash
#
# dist/trolley-<version>-dev.dmg -- 이 맥의 아키텍처만, 공증 없이, 빠르게.
#
# build-installer.sh(배포용)와 다른 파일로 둔 이유: 저쪽은 trolley_keychain_create
# 를 쓰는데, 이 맥의 로그인 키체인에 이미 같은 Developer ID Application 인증서가
# 들어있으면 codesign 이 신원을 찾을 때 "ambiguous" 로 거부한다 -- 실측. 유일한
# 해법은 서명하는 동안 키체인 검색 목록에 임시 키체인만 두는 것인데, 그건
# 배포 빌드에서 검증된 적 없는 경로라 trolley_keychain_create 자체는 건드리지
# 않고 signing-keychain.sh 에 trolley_keychain_create_dev 를 나란히 추가해 여기서만
# 쓴다. 유니버설 빌드·공증 왕복·Finder 창 배치도 로컬 확인엔 필요 없어 뺐다.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/signing-keychain.sh

DIST=dist
DMGROOT="$DIST/dev-dmgroot"
APP="$DMGROOT/trolley.app"

trap trolley_keychain_destroy EXIT

VERSION=$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' Sources/TrolleyKit/Version.swift)
if [ -z "$VERSION" ]; then
    echo "error: Sources/TrolleyKit/Version.swift에서 버전을 읽지 못했습니다." >&2
    exit 1
fi
COMMIT="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"
fi
echo "==> trolley $VERSION ($COMMIT) -- dev dmg (공증 없음)"

echo "==> 빌드 ($(uname -m))"
swift build -c release
BINARY=$(swift build -c release --show-bin-path)/trolley
[ -f "$BINARY" ] || { echo "error: $BINARY 가 없습니다." >&2; exit 1; }

echo "==> 서명용 임시 키체인 준비"
trolley_keychain_create_dev

echo "==> 앱 번들 조립"
rm -rf "$DMGROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BINARY" "$APP/Contents/MacOS/trolley"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$COMMIT/g" \
    Scripts/app/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$DIST/trolley.iconset"
rm -rf "$ICONSET"
"$BINARY" export-icon --output "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/trolley.icns"
rm -rf "$ICONSET"

echo "==> 서명: $TROLLEY_SIGN_ID"
codesign --force --options runtime --timestamp \
    --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> dmg 생성"
ln -s /Applications "$DMGROOT/Applications"
VOLUME="trolley $VERSION dev"
DMG="$DIST/trolley-$VERSION-dev.dmg"
STAGING_DMG="$DIST/.trolley-dev-rw.dmg"
rm -f "$DMG" "$STAGING_DMG"
hdiutil detach "/Volumes/$VOLUME" -force >/dev/null 2>&1 || true
hdiutil create -volname "$VOLUME" -srcfolder "$DMGROOT" -ov -format UDRW "$STAGING_DMG" >/dev/null
hdiutil convert "$STAGING_DMG" -format UDZO -imagekey zlib-level=1 -o "$DMG" >/dev/null
rm -f "$STAGING_DMG"
codesign --force --timestamp --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$DMG"
rm -rf "$DMGROOT"

echo
echo "완성: $DMG   (로컬 확인용 -- 공증 없음, 배포 불가)"
