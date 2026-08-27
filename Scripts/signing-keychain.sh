#!/bin/bash
#
# Builds a throwaway keychain holding the Developer ID Application identity, so
# codesign can run without a human clicking through an unlock dialog.
#
# Adapted from MAKi's apps/front/electron/scripts/signing-keychain.js -- same
# certificate, same proven openssl/security flags.
#
# The keychain has to join the user's search list and become the default: passing
# only --keychain to codesign looks sufficient, and it does let `find-identity`
# see the identity, but signing then fails with errSecInternalComponent. Measured,
# not assumed.
#
# That global mutation is exactly what went wrong on this machine -- MAKi's
# version restores the list when it finishes and skips the restore when a run
# dies, which is how ~70 dead keychains piled into the search list and the default
# keychain ended up pointing inside a deleted worktree. The difference here is
# that restore runs from an EXIT trap installed *before* anything is touched, so
# it survives failures and Ctrl-C too.
#
# Sourced by build-installer.sh, which installs the trap.

TROLLEY_KEYCHAIN=""
TROLLEY_KEYCHAIN_DIR=""
TROLLEY_SIGN_ID=""
TROLLEY_PREV_KEYCHAINS=""
TROLLEY_PREV_DEFAULT=""

# One place to repoint if these ever move accounts.
trolley_ssm() {
    aws ssm get-parameter --name "${TROLLEY_SSM_PREFIX:-/front/master}/$1" \
        --with-decryption --query Parameter.Value --output text 2>/dev/null
}

trolley_keychain_create() {
    local dir cert_src key_src pass p12
    # Captured before the first mutation so the trap can always put them back.
    TROLLEY_PREV_KEYCHAINS=$(security list-keychains -d user | sed 's/[" ]//g')
    TROLLEY_PREV_DEFAULT=$(security default-keychain -d user | sed 's/[" ]//g')

    dir=$(mktemp -d "${TMPDIR:-/tmp}/trolley-signing-XXXXXX")
    TROLLEY_KEYCHAIN_DIR="$dir"
    TROLLEY_KEYCHAIN="$dir/trolley-signing.keychain-db"

    # Explicit PEM paths win; otherwise SSM -- the same parameters the MAKi
    # desktop release already uses.
    if [ -n "${TROLLEY_CERT_PEM:-}" ] && [ -n "${TROLLEY_KEY_PEM:-}" ]; then
        cert_src="$TROLLEY_CERT_PEM"
        key_src="$TROLLEY_KEY_PEM"
    else
        trolley_ssm MAC_CERTIFICATE_BASE64 | base64 -d > "$dir/cert.der" 2>/dev/null || true
        trolley_ssm MAC_PRIVATE_KEY_BASE64 | base64 -d > "$dir/key.pem" 2>/dev/null || true
        if [ ! -s "$dir/cert.der" ] || [ ! -s "$dir/key.pem" ]; then
            echo "error: 서명 자산을 얻지 못했습니다." >&2
            echo "       AWS 자격증명(${TROLLEY_SSM_PREFIX:-/front/master})을 확인하거나," >&2
            echo "       TROLLEY_CERT_PEM / TROLLEY_KEY_PEM 으로 직접 지정하세요." >&2
            return 1
        fi
        cert_src="$dir/cert.der"
        key_src="$dir/key.pem"
    fi

    # SSM stores the certificate in DER; openssl pkcs12 wants PEM.
    if ! openssl x509 -in "$cert_src" -noout -subject >/dev/null 2>&1; then
        openssl x509 -inform DER -in "$cert_src" -out "$dir/cert.pem"
        cert_src="$dir/cert.pem"
    fi

    pass=$(openssl rand -hex 16)
    p12="$dir/signing.p12"
    openssl pkcs12 -export -inkey "$key_src" -in "$cert_src" -out "$p12" -passout "pass:$pass"

    security create-keychain -p "$pass" "$TROLLEY_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$TROLLEY_KEYCHAIN"
    security unlock-keychain -p "$pass" "$TROLLEY_KEYCHAIN"
    security import "$p12" -k "$TROLLEY_KEYCHAIN" -P "$pass" -f pkcs12 \
        -T /usr/bin/codesign -T /usr/bin/xcrun -T /usr/bin/security \
        -T /usr/bin/productbuild -T /usr/bin/productsign >/dev/null

    # shellcheck disable=SC2086 -- the previous list is intentionally re-split.
    security list-keychains -d user -s "$TROLLEY_KEYCHAIN" $TROLLEY_PREV_KEYCHAINS >/dev/null
    security default-keychain -d user -s "$TROLLEY_KEYCHAIN" >/dev/null
    # Without this, codesign stops to ask permission to use the key -- and with no
    # one to answer, the ask surfaces as errSecInternalComponent.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" \
        "$TROLLEY_KEYCHAIN" >/dev/null 2>&1

    TROLLEY_SIGN_ID=$(security find-identity -v -p codesigning "$TROLLEY_KEYCHAIN" \
        | awk -F'"' '/Developer ID Application/ { print $2 }' | sed -n '1p')
    if [ -z "$TROLLEY_SIGN_ID" ]; then
        echo "error: 임시 키체인에서 Developer ID Application 신원을 찾지 못했습니다." >&2
        return 1
    fi
    rm -f "$p12" "$dir/key.pem"
}

# 로컬 dev dmg 전용. trolley_keychain_create 와 다른 점은 검색 목록 한 줄뿐이다:
# 이전 키체인(로그인 키체인 포함)을 다시 넣지 않고 임시 키체인만 남긴다.
#
# 이 맥의 로그인 키체인에 이미 같은 Developer ID Application 인증서가 들어있으면
# codesign 이 신원 이름을 "ambiguous (matches ... in A and ... in B)" 로 거부한다 --
# 실측. 인증서가 완전히 같으니 SHA-1 로 지정해도 해시가 같아 소용없고, 유일한
# 해법은 서명하는 동안 검색 목록에 이 키체인만 두는 것. trolley_keychain_destroy
# 가 원래 목록을 복원하므로 그쪽은 그대로 재사용한다.
trolley_keychain_create_dev() {
    local dir cert_src key_src pass p12
    TROLLEY_PREV_KEYCHAINS=$(security list-keychains -d user | sed 's/[" ]//g')
    TROLLEY_PREV_DEFAULT=$(security default-keychain -d user | sed 's/[" ]//g')

    dir=$(mktemp -d "${TMPDIR:-/tmp}/trolley-signing-XXXXXX")
    TROLLEY_KEYCHAIN_DIR="$dir"
    TROLLEY_KEYCHAIN="$dir/trolley-signing.keychain-db"

    if [ -n "${TROLLEY_CERT_PEM:-}" ] && [ -n "${TROLLEY_KEY_PEM:-}" ]; then
        cert_src="$TROLLEY_CERT_PEM"
        key_src="$TROLLEY_KEY_PEM"
    else
        trolley_ssm MAC_CERTIFICATE_BASE64 | base64 -d > "$dir/cert.der" 2>/dev/null || true
        trolley_ssm MAC_PRIVATE_KEY_BASE64 | base64 -d > "$dir/key.pem" 2>/dev/null || true
        if [ ! -s "$dir/cert.der" ] || [ ! -s "$dir/key.pem" ]; then
            echo "error: 서명 자산을 얻지 못했습니다." >&2
            echo "       AWS 자격증명(${TROLLEY_SSM_PREFIX:-/front/master})을 확인하거나," >&2
            echo "       TROLLEY_CERT_PEM / TROLLEY_KEY_PEM 으로 직접 지정하세요." >&2
            return 1
        fi
        cert_src="$dir/cert.der"
        key_src="$dir/key.pem"
    fi

    if ! openssl x509 -in "$cert_src" -noout -subject >/dev/null 2>&1; then
        openssl x509 -inform DER -in "$cert_src" -out "$dir/cert.pem"
        cert_src="$dir/cert.pem"
    fi

    pass=$(openssl rand -hex 16)
    p12="$dir/signing.p12"
    openssl pkcs12 -export -inkey "$key_src" -in "$cert_src" -out "$p12" -passout "pass:$pass"

    security create-keychain -p "$pass" "$TROLLEY_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$TROLLEY_KEYCHAIN"
    security unlock-keychain -p "$pass" "$TROLLEY_KEYCHAIN"
    security import "$p12" -k "$TROLLEY_KEYCHAIN" -P "$pass" -f pkcs12 \
        -T /usr/bin/codesign -T /usr/bin/xcrun -T /usr/bin/security \
        -T /usr/bin/productbuild -T /usr/bin/productsign >/dev/null

    # 여기가 trolley_keychain_create 와 갈리는 지점: 이전 목록을 뒤에 붙이지 않는다.
    security list-keychains -d user -s "$TROLLEY_KEYCHAIN" >/dev/null
    security default-keychain -d user -s "$TROLLEY_KEYCHAIN" >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" \
        "$TROLLEY_KEYCHAIN" >/dev/null 2>&1

    TROLLEY_SIGN_ID=$(security find-identity -v -p codesigning "$TROLLEY_KEYCHAIN" \
        | awk -F'"' '/Developer ID Application/ { print $2 }' | sed -n '1p')
    if [ -z "$TROLLEY_SIGN_ID" ]; then
        echo "error: 임시 키체인에서 Developer ID Application 신원을 찾지 못했습니다." >&2
        return 1
    fi
    rm -f "$p12" "$dir/key.pem"
}

trolley_keychain_destroy() {
    if [ -n "$TROLLEY_PREV_KEYCHAINS" ]; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $TROLLEY_PREV_KEYCHAINS >/dev/null 2>&1
    fi
    if [ -n "$TROLLEY_PREV_DEFAULT" ]; then
        security default-keychain -d user -s "$TROLLEY_PREV_DEFAULT" >/dev/null 2>&1
    fi
    [ -n "$TROLLEY_KEYCHAIN" ] && security delete-keychain "$TROLLEY_KEYCHAIN" 2>/dev/null
    [ -n "$TROLLEY_KEYCHAIN_DIR" ] && rm -rf "$TROLLEY_KEYCHAIN_DIR"
    TROLLEY_KEYCHAIN=""
    TROLLEY_KEYCHAIN_DIR=""
    TROLLEY_PREV_KEYCHAINS=""
    TROLLEY_PREV_DEFAULT=""
}
