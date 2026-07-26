#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

fail() {
    echo "security invariant failed: $1" >&2
    exit 1
}

if git grep -n -E 'Bundle[.]load[(]|[.]load[(][)]' -- 'Docky/*.swift' \
    'Docky/**/*.swift'; then
    fail "Docky's main process must not dynamically load executable bundles"
fi

if git grep -n -E 'DockyWidgetPlugin|ExternalWidgetRegistration|ExternalWidgetRegistry' \
    -- 'Docky/*.swift' 'Docky/**/*.swift'; then
    fail "the legacy in-process executable-widget ABI must remain absent"
fi

if git grep -n -E 'xattr.*(-c|-d)|arguments[[:space:]]*=[[:space:]]*\\[[[:space:]]*\"-cr\"' \
    -- 'Docky/*.swift' 'Docky/**/*.swift'; then
    fail "Docky must not strip quarantine or other extended attributes"
fi

if git grep -n 'RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES;' \
    -- Docky.xcodeproj/project.pbxproj; then
    fail "library validation must remain enabled"
fi

if git grep -n 'RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION = YES;' \
    -- Docky.xcodeproj/project.pbxproj; then
    fail "executable-page protection must remain enabled"
fi

if git grep -n -E 'install-widget[^A-Za-z].*(url=|download)|download.*install-widget' \
    -- 'Docky/*.swift' 'Docky/**/*.swift'; then
    fail "widget deep links must not carry download URLs"
fi

echo "Security invariants passed."
