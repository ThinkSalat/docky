#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repository_root/scripts/check_release_workflow.sh"
release_script="$repository_root/scripts/release_sparkle_update.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/docky-release-test.XXXXXX")"

cleanup() {
    find "$fixture_root" -depth -delete
}
trap cleanup EXIT

"$checker" "$release_script" >/dev/null

direct_app_fixture="$fixture_root/direct-app.sh"
sed \
    's/notarytool submit "$NOTARIZATION_ZIP_PATH"/notarytool submit "$APP_PATH"/' \
    "$release_script" >"$direct_app_fixture"
if "$checker" "$direct_app_fixture" >/dev/null 2>&1; then
    echo "expected direct .app notarization submission to fail" >&2
    exit 1
fi

unstapled_final_fixture="$fixture_root/unstapled-final.sh"
sed \
    's/create_update_archive "$ZIP_PATH"/: # final archive removed/' \
    "$release_script" >"$unstapled_final_fixture"
if "$checker" "$unstapled_final_fixture" >/dev/null 2>&1; then
    echo "expected missing post-staple Sparkle archive to fail" >&2
    exit 1
fi

echo "Release workflow tests passed."
