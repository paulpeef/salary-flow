#!/bin/bash
# Build precisely the tagged source on the Mac holding the signing identity.
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?Expected a release tag, e.g. v1.19.2}
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]]
version=${tag#v}
repo=paulpeef/salary-flow
# Resolve both annotated and lightweight tags and build the commit GitHub serves.
remote_commit=$(gh api "repos/$repo/commits/$tag" --jq .sha)
[[ "$(git rev-parse "refs/tags/$tag^{commit}")" == "$remote_commit" ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive "refs/tags/$tag" | tar -x -C "$work"
cd "$work"
VERSION="$version" SALARYFLOW_SIGN_IDENTITY=1CB03D6ED5AB64BEEE55290083A510A4C8F9B42B ./build.sh
asset="SalaryFlow-$version.zip"
ditto -c -k --keepParent .build/SalaryFlow.app "$asset"
ditto -x -k "$asset" unpacked
./Tools/verify-release-app.sh unpacked/SalaryFlow.app "$version"
digest=$(shasum -a 256 "$asset" | cut -d' ' -f1)
echo "SHA-256 $asset: $digest"
gh release create "$tag" "$asset" --repo "$repo" --draft --verify-tag \
  --title "Salary Flow $tag" --notes-file "releases/$tag.md"
gh workflow run release.yml --repo "$repo" --ref "$tag" -f "sha256=$digest"
