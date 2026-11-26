#!/bin/bash
# Public identifiers for both signing layers. The private keys are stored separately.
set -euo pipefail
app=${1:?Expected extracted SalaryFlow.app}
version=${2:?Expected release version}
bundle=io.github.paulpeef.salaryflow
cert_sha256=a084918dabf0360a9fc93ca8137ea8244ff8f7e509cb3f4e3d51ae3134aef008
requirement='identifier "io.github.paulpeef.salaryflow" and certificate leaf = H"1cb03d6ed5ab64beee55290083a510a4c8f9b42b"'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
codesign --verify --deep --strict "$app"
codesign --verify -R="$requirement" "$app"
codesign -d --extract-certificates="$work/cert" "$app"
[[ "$(shasum -a 256 "$work/cert0" | cut -d' ' -f1)" == "$cert_sha256" ]]
# Check the rule the NEXT version will be measured against as well.
dr=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
[[ "$dr" == "$requirement" ]]
info="$app/Contents/Info.plist"
field() { /usr/libexec/PlistBuddy -c "Print :$1" "$info"; }
[[ "$(field CFBundleIdentifier)" == "$bundle" ]]
[[ "$(field CFBundleVersion)" == "$version" && "$(field CFBundleShortVersionString)" == "$version" ]]
[[ "$(field SUPublicEDKey)" == 'oHSDimtXW5KkFmck6f786b9x//NPa6Zgat0oSw0qzOE=' ]]
[[ "$(field SUFeedURL)" == 'https://raw.githubusercontent.com/paulpeef/salary-flow/main/appcast.xml' ]]
echo "Verified Salary Flow $version and its signing identity."
