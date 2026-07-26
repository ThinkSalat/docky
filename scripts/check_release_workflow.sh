#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_script="${1:-$repository_root/scripts/release_sparkle_update.sh}"

fail() {
    echo "release workflow check failed: $1" >&2
    exit 1
}

line_number() {
    local pattern="$1"
    local line
    line="$(
        awk -v pattern="$pattern" \
            'index($0, pattern) { print NR; exit }' \
            "$release_script"
    )"
    [[ -n "$line" ]] || fail "missing required command: $pattern"
    printf '%s\n' "$line"
}

if grep -Fq 'notarytool submit "$APP_PATH"' "$release_script"; then
    fail "notarytool cannot submit an .app bundle directly"
fi

submission_archive_line="$(
    line_number 'create_update_archive "$NOTARIZATION_ZIP_PATH"'
)"
notary_submit_line="$(
    line_number 'notarytool submit "$NOTARIZATION_ZIP_PATH"'
)"
staple_line="$(line_number 'stapler staple "$APP_PATH"')"
staple_validation_line="$(line_number 'stapler validate "$APP_PATH"')"
gatekeeper_line="$(
    line_number 'spctl --assess --type execute --verbose=4 "$APP_PATH"'
)"
final_archive_line="$(line_number 'create_update_archive "$ZIP_PATH"')"
signature_validation_line="$(
    line_number 'codesign --verify --deep --strict --verbose=2 "$APP_PATH"'
)"

line_number \
    'ZIP_NAME="$APP_NAME-$MARKETING_VERSION-$BUILD_VERSION.zip"' \
    >/dev/null
(( signature_validation_line < submission_archive_line )) \
    || fail "the exported signature must be verified before notarization"
(( submission_archive_line < notary_submit_line )) \
    || fail "the ZIP submission archive must be created before notarization"
(( notary_submit_line < staple_line )) \
    || fail "the app must be stapled only after notarization succeeds"
(( staple_line < staple_validation_line )) \
    || fail "the stapled ticket must be validated"
(( staple_validation_line < gatekeeper_line )) \
    || fail "Gatekeeper assessment must follow staple validation"
(( gatekeeper_line < final_archive_line )) \
    || fail "the final Sparkle ZIP must be created from the stapled app"

echo "Release workflow valid: ZIP submission, staple, validation, final ZIP."
