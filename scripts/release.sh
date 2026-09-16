#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a release from this Mac, then updates the Homebrew tap.
# The version comes from Sources/AutorecordCore/Product.swift. See docs/releasing.md.
#
# Environment overrides:
#   SIGN_IDENTITY   codesign identity, default: the first "Developer ID Application" identity in the keychain
#   NOTARY_PROFILE  notarytool keychain profile, default: tg-granola-autorecord
#   TAP_REPO        Homebrew tap repository, default: leplik/homebrew-tap
#   DRY_RUN=1       build, sign, notarize and staple, but do not tag, publish or touch the tap
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

product_value() {
  sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" Sources/AutorecordCore/Product.swift | head -1
}
NAME="$(product_value name)"
COMMAND="$(product_value command)"
VERSION="$(product_value version)"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-tg-granola-autorecord}"
TAP_REPO="${TAP_REPO:-leplik/homebrew-tap}"
DRY_RUN="${DRY_RUN:-0}"
OUT=".build/release"
APP="$OUT/$NAME.app"
ZIP="$OUT/$COMMAND-$VERSION.zip"

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Preflight for $NAME $VERSION"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[[ -n "$SIGN_IDENTITY" ]] || fail "no Developer ID Application identity in the keychain"
echo "identity: $SIGN_IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notarytool profile '$NOTARY_PROFILE' is missing or invalid, see docs/releasing.md"
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION"

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree is not clean"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "releases are cut from main"
  git fetch --quiet origin main --tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in"
fi

step "Tests"
swift test

step "Build and sign"
rm -rf "$OUT"
scripts/build-app.sh --sign "$SIGN_IDENTITY" --arch universal --output "$OUT"

step "Notarize"
SUBMISSION="$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMISSION"
if ! xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notary.json"; then
  cat "$OUT/notary.json" >&2 || true
  fail "notarization request failed"
fi
STATUS="$(plutil -extract status raw -o - "$OUT/notary.json")"
SUBMISSION_ID="$(plutil -extract id raw -o - "$OUT/notary.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fail "notarization status: $STATUS"
fi
rm -f "$SUBMISSION"

step "Staple and verify"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"
echo "$ZIP"
echo "sha256 $SHA256"

if [[ "$DRY_RUN" == "1" ]]; then
  step "Dry run: stopping before tagging and publishing"
  exit 0
fi

step "Tag and publish $TAG"
NOTES="$OUT/notes.md"
awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { printing = 1; next }
  printing && /^## \[/ { exit }
  printing && /^\[.*\]: / { exit }
  printing { print }
' CHANGELOG.md > "$NOTES"
git tag -a "$TAG" -m "$NAME $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "$NAME $VERSION" --notes-file "$NOTES"

step "Update the Homebrew tap"
TAP_DIR="$OUT/tap"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
mkdir -p "$TAP_DIR/Casks"
sed -e "s/{{VERSION}}/$VERSION/" -e "s/{{SHA256}}/$SHA256/" \
  packaging/homebrew/tg-granola-autorecord.rb.template > "$TAP_DIR/Casks/tg-granola-autorecord.rb"
git -C "$TAP_DIR" add Casks/tg-granola-autorecord.rb
git -C "$TAP_DIR" commit --quiet -m "tg-granola-autorecord $VERSION"
git -C "$TAP_DIR" push --quiet origin HEAD

step "Done: https://github.com/leplik/tg-granola-autorecord/releases/tag/$TAG"
