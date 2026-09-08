#!/bin/bash
#
# Cut a signed, notarised release and publish it everywhere.
#
#   scripts/release.sh 1.0.0
#   scripts/release.sh 1.0.0 notes.md        # release notes, instead of generated ones
#
# In order: preflight · swift test · version bump · build · Developer ID sign · notarise ·
# staple · Gatekeeper verdict · tag · GitHub release · verify the *published* bytes · Homebrew
# cask. Stops at the first failure.
#
# RUN THIS ON THE RELEASE MACHINE — the Developer ID private key is not on the dev Mac, and
# preflight refuses to start without it rather than letting you find out after the build.
#
# One-time setup, both of which only Lee can do (they involve Apple credentials):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. xcrun notarytool store-credentials PWE_NOTARY --team-id 2SQV3H5MH9 \
#        --apple-id <apple-id> --password <app-specific-password>
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES_FILE="${2:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-PWE_NOTARY}"
REPO="${REPO:-kenshinice-ai/pwe-ai-bar}"
TAP_REPO="${TAP_REPO:-kenshinice-ai/homebrew-tap}"
CASK="Casks/pwe-ai-bar.rb"

[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <version> [notes.md]"; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ version must look like 1.0.0"; exit 1; }

MOUNT=""
BUMPED=""
TAGGED=""
SCRATCH=()
cleanup() {
  local rc=$?
  # `[[ … ]] && cmd` here is a trap for the trap: the last command of an AND-list is not exempt
  # from `set -e`, so a detach that fails — a volume Spotlight is still indexing is enough —
  # aborted the handler before the restore below and rewrote the exit code to 1. That fired
  # precisely when `spctl` had just rejected the app, which is the failure worth reporting.
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
  for dir in ${SCRATCH[@]+"${SCRATCH[@]}"}; do rm -rf "$dir"; done
  if [[ $rc -ne 0 ]]; then
    # Only while the bump is still uncommitted. It used to stay set past `git commit`, so a
    # failure at `gh release create` printed "tree left clean" over a `git checkout` that did
    # nothing — while the tag was already pushed and the next run refused to start because of it.
    if [[ -n "$BUMPED" ]]; then
      git checkout -- VERSION "$CASK" 2>/dev/null \
        && echo "! failed before publishing — VERSION and cask restored, tree left clean"
    fi
    if [[ -n "$TAGGED" ]]; then
      echo
      echo "! $TAGGED is already committed and pushed. Nothing above can undo that for you."
      echo "  To retry this version, remove it first:"
      echo "      git push --delete origin $TAGGED && git tag -d $TAGGED"
      echo "      git reset --hard HEAD~1 && git push --force-with-lease origin main"
      echo "  Or bump to the next patch version instead, which is usually the safer move."
    fi
  fi
  exit $rc
}
trap cleanup EXIT

echo "── preflight ─────────────────────────────────────────────"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || {
  echo "✗ No \"Developer ID Application\" certificate in this keychain."
  echo "  This is the development machine, not the release machine. A build signed here is"
  echo "  ad-hoc and Gatekeeper rejects it on every other Mac."
  exit 1; }
echo "✓ signing identity: $IDENTITY"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  cat <<MISSING
✗ No stored notarisation credentials under the profile "$NOTARY_PROFILE".

  Create an app-specific password at https://appleid.apple.com ▸ Sign-In and Security, then
  run this yourself — nothing and nobody else needs to see that password:

    xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --team-id 2SQV3H5MH9 --apple-id <your-apple-id>
MISSING
  exit 1; }
echo "✓ notarisation credentials: profile \"$NOTARY_PROFILE\""

[[ -z "$(git status --porcelain)" ]] || {
  echo "✗ working tree is dirty — commit or stash first:"; git status --short; exit 1; }
echo "✓ working tree clean"

# This repository lives in iCloud Drive, whose file provider resolves a two-machine conflict
# by writing "Forecast 2.swift" beside "Forecast.swift". SwiftPM does not compile them, so the
# build stays correct and nothing warns — they are invisible until something stages broadly.
# The v1.0.0 commit carried fourteen of them, 3,444 lines, into the published tag.
# Matched by shape *and* by having a sibling: iCloud writes "Forecast 2.swift" beside
# "Forecast.swift", so the sibling is what separates a conflict copy from a file that is simply
# called "Chapter 3.md". The old pattern required one digit and exactly one extension, which
# missed "VERSION 2" — and VERSION is the one file both machines are guaranteed to write —
# along with "Forecast 10.swift" and "archive 2.tar.gz", while flagging "Chapter 3.md".
CONFLICTS=$(git ls-files | while IFS= read -r f; do
  base="${f%% [0-9]}"; base="${base%% [0-9][0-9]}"
  if [[ "$base" != "$f" && -e "$base" ]]; then echo "$f"; continue; fi
  name="${f##*/}"; dir="${f%/*}"; [[ "$dir" == "$f" ]] && dir="."
  stem="${name%%.*}"; ext="${name#"$stem"}"
  trimmed="${stem%% [0-9]}"; trimmed="${trimmed%% [0-9][0-9]}"
  if [[ "$trimmed" != "$stem" && -e "$dir/$trimmed$ext" ]]; then echo "$f"; fi
done)
[[ -z "$CONFLICTS" ]] || {
  echo "✗ iCloud conflict copies are tracked in this repository:"
  sed 's/^/    /' <<<"$CONFLICTS"
  echo "  Delete them (git rm) before releasing — .gitignore keeps new ones out."
  exit 1; }
echo "✓ no iCloud conflict copies tracked"

gh auth status >/dev/null 2>&1 || { echo "✗ gh is not authenticated (run: gh auth login)"; exit 1; }
echo "✓ gh authenticated"

git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && {
  echo "✗ tag v$VERSION already exists"; exit 1; }
echo "✓ v$VERSION is unused"

echo
echo "── tests ─────────────────────────────────────────────────"
# Never a release off an unproven tree. The forecast engine and the credential rotation both
# have regression tests that fail if their invariants are broken; that is the whole point.
# `tail -3` here used to show only the swift-testing summary — "0 tests in 0 suites" — while
# the line that says 116 XCTest cases passed scrolled off. The gate was right and the report
# was misleading, which is its own kind of wrong.
# `grep` returning 1 on a run with no matching line would abort a *passing* build under
# pipefail, so the test result is taken from swift itself and grep only shapes the report.
set +o pipefail
TEST_OUT="$(swift test 2>&1)"; TEST_RC=$?
set -o pipefail
grep -E "Executed [0-9]+ tests|error:" <<<"$TEST_OUT" | tail -3
[[ $TEST_RC -eq 0 ]] || { echo "✗ tests failed"; exit 1; }

echo
echo "── version $VERSION ──────────────────────────────────────"
echo "$VERSION" > VERSION
BUMPED=1
echo "✓ VERSION → $VERSION  (Info.plist is generated from it by build-app.sh)"

echo
echo "── build, sign, notarise ─────────────────────────────────"
NOTARY_PROFILE="$NOTARY_PROFILE" ./scripts/package.sh --notarize

DMG="dist/PWE-AI-Bar-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "✗ $DMG was not produced"; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SHA  $(basename "$DMG")" > dist/SHA256SUMS.txt

echo
echo "── Gatekeeper verdict ────────────────────────────────────"
# The real test is not "did notarytool accept it" but what a stranger's Mac decides when the
# download is opened. Anything other than "Notarized Developer ID" stops the release here.
VERDICT=$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)
echo "$VERDICT"
grep -q "source=Notarized Developer ID" <<<"$VERDICT" || {
  echo "✗ the disk image is not recognised as notarised — stopping before publishing it"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null && echo "✓ ticket stapled to the disk image"

MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
spctl -a -vv "$MOUNT/PWE AI Bar.app"
xcrun stapler validate "$MOUNT/PWE AI Bar.app" >/dev/null && echo "✓ ticket stapled to the app"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo
echo "── publish ───────────────────────────────────────────────"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
# Exactly the two files this script is allowed to change. `git add -A` here is what swept the
# iCloud conflict copies into v1.0.0: a release commit must contain the version bump and the
# cask and nothing else, so that `git show` on a tag is readable a year later.
git add VERSION "$CASK"
git commit -q -m "Release $VERSION"
BUMPED=""            # committed: there is no longer a working-tree change to restore
git tag -a "v$VERSION" -m "PWE AI Bar $VERSION"
git push -q origin HEAD
git push -q origin "v$VERSION"
TAGGED="v$VERSION"   # past here a failure needs a human, and cleanup says exactly what to run
echo "✓ tagged v$VERSION and pushed"

if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
  gh release create "v$VERSION" "$DMG" dist/SHA256SUMS.txt \
    --repo "$REPO" --title "PWE AI Bar $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "v$VERSION" "$DMG" dist/SHA256SUMS.txt \
    --repo "$REPO" --title "PWE AI Bar $VERSION" --generate-notes
fi
echo "✓ release published"

echo
echo "── what is actually being served ─────────────────────────"
# The local .dmg being notarised proves nothing about the bytes on the release page. A CI run
# once overwrote a notarised disk image 53 seconds after the local release and spctl on the
# published file read "no usable signature" — so download it back and judge that copy.
BACK=$(mktemp -d); SCRATCH+=("$BACK")
gh release download "v$VERSION" --repo "$REPO" -p '*.dmg' -D "$BACK" >/dev/null
PUB_SHA=$(shasum -a 256 "$BACK"/*.dmg | cut -d' ' -f1)
[[ "$PUB_SHA" == "$SHA" ]] || {
  echo "✗ the published .dmg hashes $PUB_SHA, not $SHA — something replaced it"; exit 1; }
echo "✓ published checksum matches: $SHA"
spctl -a -t open --context context:primary-signature -vv "$BACK"/*.dmg 2>&1 | sed 's/^/  /'
spctl -a -t open --context context:primary-signature "$BACK"/*.dmg 2>/dev/null \
  || { echo "✗ the published copy does not pass Gatekeeper"; exit 1; }
rm -rf "$BACK"

echo
echo "── Homebrew tap ──────────────────────────────────────────"
TAP_DIR=$(mktemp -d); SCRATCH+=("$TAP_DIR")
git clone -q "https://github.com/$TAP_REPO.git" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
cp "$CASK" "$TAP_DIR/Casks/pwe-ai-bar.rb"
# Strip this repo's setup notes from the published cask. Deleting only the comment lines left
# the blank line that followed them, which `brew style` flags.
sed -i '' '1,/^cask /{/^cask /!d;}' "$TAP_DIR/Casks/pwe-ai-bar.rb"
git -C "$TAP_DIR" add -A
git -C "$TAP_DIR" commit -q -m "pwe-ai-bar $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "$TAP_DIR"
echo "✓ cask updated in $TAP_REPO"

echo
echo "Done. https://github.com/$REPO/releases/tag/v$VERSION"
echo "  brew install --cask kenshinice-ai/tap/pwe-ai-bar"
echo
echo "Not done by this script — the site is a separate repo:"
echo "  cd '../PWE Loan Bar' && ./site/deploy.sh"
