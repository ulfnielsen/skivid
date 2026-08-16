#!/bin/zsh
set -euo pipefail

# Builds the Mac app the way another Mac will accept it: Developer ID signature,
# hardened runtime, notarised by Apple, ticket stapled.
#
# `build_app.sh` stays the fast local path and keeps its ad-hoc signature —
# `run.sh` calls it on every iteration and neither wants nor can afford a
# notarisation round trip. The two produce the same bundle at the same path; the
# only difference is who will run it. Measured on 2026-08-16, an ad-hoc bundle:
#
#     Signature=adhoc, TeamIdentifier=not set
#     spctl -a -t exec  ->  rejected
#     stapler validate  ->  does not have a ticket stapled to it
#
# On the machine that built it that is invisible. Anywhere else Gatekeeper
# refuses it, and a *downloaded* copy carries the quarantine flag, which on
# current macOS means no right-click-Open escape — the operator has to go to
# System Settings > Privacy & Security and allow it by hand. For a tool a club
# is being asked to trust with its athletes' footage that is the wrong first
# impression, which is what this script exists to avoid.

script_dir=${0:A:h}
bundle_path="$script_dir/SkiVideoViewer.app"
dist_dir="$script_dir/dist"
zip_path="$dist_dir/SkiVideoViewer.zip"

# The team the Developer ID certificate belongs to. Read off the installed
# Apple Development certificate's OU on 2026-08-16 rather than typed from
# memory; override for a different account.
: ${TEAM_ID:=9LTFHV87LB}

# The keychain profile `xcrun notarytool store-credentials` wrote. Created once,
# by hand, because it needs an Apple ID and an app-specific password that must
# not live in a repo. See the failure message below for the exact command.
: ${NOTARY_PROFILE:=skivideoviewer}

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# --- Preflight -------------------------------------------------------------
#
# Both checks fail loudly and early on purpose. Signing with the wrong identity
# still produces a bundle, and notarising without credentials fails eleven
# minutes into a build; neither is a state worth discovering late.

identity=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" \
  | head -1 \
  | sed -E 's/.*"(.*)"/\1/') || true

if [[ -z "${identity:-}" ]]; then
  print -u2 "No Developer ID Application certificate found in the keychain."
  print -u2 ""
  print -u2 "An 'Apple Development' certificate is not enough — that one signs"
  print -u2 "builds for your own machines. Distribution outside the App Store"
  print -u2 "needs a Developer ID Application certificate:"
  print -u2 ""
  print -u2 "  Xcode > Settings > Accounts > (your account) > Manage Certificates"
  print -u2 "  > + > Developer ID Application"
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  print -u2 "No notarytool credentials stored under the profile '$NOTARY_PROFILE'."
  print -u2 ""
  print -u2 "Create it once — it needs an app-specific password from"
  print -u2 "appleid.apple.com, NOT your Apple ID password:"
  print -u2 ""
  print -u2 "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
  print -u2 "      --apple-id <your-apple-id> \\"
  print -u2 "      --team-id $TEAM_ID \\"
  print -u2 "      --password <app-specific-password>"
  exit 1
fi

# --- Build -----------------------------------------------------------------

print "Building…"
"$script_dir/build_app.sh" >/dev/null

# --- Sign ------------------------------------------------------------------
#
# `--options runtime` is the hardened runtime, which notarisation requires.
# `--timestamp` fetches a trusted timestamp so the signature keeps verifying
# after the certificate itself expires; without it the app stops opening the day
# the cert lapses, on machines that never updated.
#
# No entitlements file. The hardened runtime restricts JIT, unsigned executable
# memory and DYLD injection, and this app does none of those — it draws
# AVPlayer layers and talks HTTPS. Network access needs no entitlement outside
# the App Sandbox, and the app is deliberately unsandboxed (see the notes on
# Mac App Store distribution: sandboxing would need security-scoped bookmarks
# on macOS, which only the iOS side has today).

print "Signing as: $identity"
codesign --force --deep \
  --sign "$identity" \
  --options runtime \
  --timestamp \
  "$bundle_path"

codesign --verify --strict --verbose=2 "$bundle_path"

# --- Notarise --------------------------------------------------------------
#
# Apple notarises a zip, not a directory. `ditto -c -k --keepParent` is the
# archiver Apple documents for this; `zip` mangles symlinks and extended
# attributes inside a bundle.

print "Notarising…"
mkdir -p "$dist_dir"
rm -f "$zip_path"
ditto -c -k --keepParent "$bundle_path" "$zip_path"

xcrun notarytool submit "$zip_path" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# Staple the ticket to the *bundle*, then re-zip. A stapled ticket is what lets
# the app open on a machine that is offline or behind a firewall that blocks
# Apple's notarisation check; without it Gatekeeper has to phone home and fails
# closed when it cannot.
xcrun stapler staple "$bundle_path"

rm -f "$zip_path"
ditto -c -k --keepParent "$bundle_path" "$zip_path"

# --- Verify ----------------------------------------------------------------
#
# The three checks that were negative before this script existed. Run them here
# rather than trusting the steps above to have worked: `spctl` is the actual
# question a coach's Mac asks, and it is cheap to answer now instead of over a
# support call.

print ""
print "Verifying…"
spctl -a -vvv -t exec "$bundle_path"
xcrun stapler validate "$bundle_path"
codesign -dvv "$bundle_path" 2>&1 | grep -E "^Identifier|^Authority|^TeamIdentifier"

print ""
print "Ready to distribute:"
print "$zip_path"
