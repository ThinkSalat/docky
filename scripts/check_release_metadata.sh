#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repository_root/Docky.xcodeproj/project.pbxproj"
info_plist="$repository_root/Config/Info.plist"
expected_version="${1:-${EXPECTED_MARKETING_VERSION:-}}"

fail() {
    echo "release metadata check failed: $1" >&2
    exit 1
}

unique_setting_values() {
    local setting="$1"
    sed -nE "s/^[[:space:]]*${setting}[[:space:]]*=[[:space:]]*\"?([^\";]+)\"?;.*/\\1/p" \
        "$project_file" \
        | sed -E 's/[[:space:]]+$//' \
        | sort -u
}

nonempty_line_count() {
    awk 'NF { count += 1 } END { print count + 0 }'
}

marketing_versions="$(unique_setting_values MARKETING_VERSION)"
marketing_version_count="$(printf '%s\n' "$marketing_versions" | nonempty_line_count)"
[[ "$marketing_version_count" == "1" ]] \
    || fail "expected one MARKETING_VERSION across app targets; found: ${marketing_versions:-none}"
project_marketing_version="$marketing_versions"

[[ "$project_marketing_version" =~ ^[0-9]+([.][0-9]+){2}([.-][0-9A-Za-z.-]+)?$ ]] \
    || fail "MARKETING_VERSION is not a release version: $project_marketing_version"

build_versions="$(unique_setting_values CURRENT_PROJECT_VERSION)"
build_version_count="$(printf '%s\n' "$build_versions" | nonempty_line_count)"
[[ "$build_version_count" == "1" ]] \
    || fail "expected one CURRENT_PROJECT_VERSION across app targets; found: ${build_versions:-none}"
[[ "$build_versions" =~ ^[0-9]+$ ]] \
    || fail "CURRENT_PROJECT_VERSION must be numeric: $build_versions"

plist_marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
plist_build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
[[ "$plist_marketing_version" == '$(MARKETING_VERSION)' ]] \
    || fail "CFBundleShortVersionString must use \$(MARKETING_VERSION)"
[[ "$plist_build_version" == '$(CURRENT_PROJECT_VERSION)' ]] \
    || fail "CFBundleVersion must use \$(CURRENT_PROJECT_VERSION)"

if [[ -z "$expected_version" ]] && command -v git >/dev/null 2>&1; then
    exact_tag_versions="$(
        git -C "$repository_root" tag --points-at HEAD \
            | sed -nE 's/^v([0-9]+([.][0-9]+){2}([.-][0-9A-Za-z.-]+)?)$/\1/p' \
            | sort -u
    )"
    exact_tag_count="$(printf '%s\n' "$exact_tag_versions" | nonempty_line_count)"
    if [[ "$exact_tag_count" -gt 1 ]]; then
        fail "HEAD has multiple version tags: $exact_tag_versions"
    fi
    if [[ "$exact_tag_count" == "1" ]]; then
        expected_version="$exact_tag_versions"
    fi
fi

if [[ -n "$expected_version" && "$project_marketing_version" != "$expected_version" ]]; then
    fail "MARKETING_VERSION $project_marketing_version does not match expected $expected_version"
fi

"$repository_root/scripts/check_release_workflow.sh"

echo "Release metadata valid: version $project_marketing_version, build $build_versions."
