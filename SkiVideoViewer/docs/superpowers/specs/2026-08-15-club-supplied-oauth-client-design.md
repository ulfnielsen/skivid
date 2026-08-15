# Club-supplied OAuth client — design

**Goal:** a ski club that is not rg-albis.ch can open its own Google Drive
library in this app, without the app being verified by Google.

## Why this exists

The app works today because its OAuth consent screen has an **Internal**
audience, which Google exempts from verification. Internal means *the owning
Workspace only* — an account at another club cannot sign in at all, no matter
what the app does.

Opening it up would mean an **External** audience, and `drive.readonly` is a
Google **restricted** scope. External plus a restricted scope means a
verification review, an annual CASA security assessment, and — until it
passes — a 100-user cap behind an "unverified app" warning screen.

So the app does not ask Google for permission to serve every club. Each club
registers its own OAuth client, in its own Google Cloud project, with its own
Internal audience, and enters the client id here. No review, no annual fee,
no user cap, and each club's Drive traffic stays inside its own project —
which is also an easier conversation with another club's committee than
"trust our app."

The cost is a one-time setup by someone with Workspace admin access. This
design's job is to make that setup as small as it can be: **one client, one
field, no secret.**

## What was measured, and what it rules out

Probed against the live authorization endpoint on 2026-08-15, reading the
`Location` header of `https://accounts.google.com/o/oauth2/v2/auth`. Note
that all of these return **HTTP 302** — the status code does not discriminate
and a probe reading only the code concludes everything is accepted. The
redirect *target* is the answer.

| Client type | Redirect tried | Result |
| --- | --- | --- |
| iOS | `com.googleusercontent.apps.<id>:/oauth2redirect` | accepted |
| iOS | `<registered-bundle-id>:/oauth2redirect` | **accepted** |
| iOS | `ch.ski.bogus.nonsense:/oauth2redirect` | `redirect_uri_mismatch` |
| iOS | `http://127.0.0.1:51234` | `invalid_request` — *"The loopback flow has been blocked in order to keep users secure."* |
| iOS | `http://localhost:51234` | same block |

Two consequences, and they are the whole design:

**An iOS client accepts a bundle-ID redirect.** This is what makes the
feature buildable at all. A custom URL scheme must be registered in
`Info.plist` at build time, so a club pasting its own client id at runtime
could never register `com.googleusercontent.apps.<their-id>`. Because Google
honours the registered bundle ID instead, every club registers its client
against **one fixed string** and the app ships a single unchanging scheme.

**An iOS client cannot use loopback.** So the Mac cannot reuse its existing
loopback listener with a club-supplied iOS client. The alternative — asking
each club to create a *second*, Desktop-type client with a secret, just for
the Mac — doubles the setup and adds a secret field. Rejected.

## The shape

**One iOS-type client serves both platforms.** Club-supplied credentials
always redirect through a custom scheme, on macOS as well as iPadOS.
`ASWebAuthenticationSession` exists on both, so this removes a platform
difference rather than adding one.

**The redirect scheme is `ch.ski.video-viewer`** — the shipped Mac app's
bundle identifier, and the string a club is told to enter as the Bundle ID
when creating its client. Both apps register it.

The built-in client keeps its existing `ch.ski.video-viewer.ipad` scheme,
because that is what it was registered with and re-registering it would
break the home club's sign-in. Both schemes therefore appear in the iPad's
`Info.plist`; which one is used follows from which configuration is active,
and is not itself configurable.

**Storage: `UserDefaults`.** An OAuth client id is not a secret — every iOS
app shipping Google Sign-In has one in plain text inside its bundle, and
Google documents this as expected. Security here comes from the
redirect-URI restriction plus PKCE. Putting it in the Keychain would imply a
confidentiality it does not have, and the Keychain is already the token
store; mixing a public identifier into it blurs that line.

**No configuration means the built-in client.** rg-albis.ch keeps working
with nothing entered, and a club that has entered its own can clear it and
fall back.

**A client id and a token have different lifetimes**, and only the id is
configuration: a token expires or is revoked as a matter of course, while a
club's client id is set once and kept. The app has no sign-out today, so
there is nothing to enforce this against yet and no test asserts it — noted
here because whoever adds sign-out will have to clear the token *without*
clearing the id, or every token expiry will look like a fresh setup.

## Where it lives

In `GoogleDriveSheet`, as a disclosure below the sign-in button, not in a
separate settings window. Two reasons: iPadOS has no preferences window, so
a settings-window design would need a second implementation there anyway;
and the sheet is already the one place that answers "how do I connect to
Drive?" A club setting this up is by definition looking at that sheet,
having found it cannot sign in.

The disclosure is collapsed by default. The overwhelmingly common case is a
coach who should press the button and nothing else.

## Validation

A client id is checked for the `.apps.googleusercontent.com` suffix before
it is stored, and the field reports the mismatch inline. This catches the
predictable paste error — the *client secret*, or a project number — at the
moment it happens rather than as a `redirect_uri_mismatch` three screens
later, which reads as an app bug and is unactionable for the person who
caused it.

Nothing else is validated locally. Whether the id exists, whether its
audience is Internal, and whether the signing-in account is inside that
Workspace are all Google's answers to give, and guessing at them here would
mean maintaining a second, worse copy of Google's rules.

## Setup instructions

The sheet shows the two values a club cannot guess — the Bundle ID string to
enter, and the scope the client needs — and links to
`docs/google-oauth-club-setup.md` for the full walkthrough. The in-app text
stays short enough to read standing up at a race.

## Testing

- A club-supplied id, once saved, is what the next sign-in uses.
- With nothing saved, the built-in client is used. Pin both directions —
  a fallback that never falls back and a fallback that always falls back
  both pass a one-directional test.
- Clearing restores the built-in.
- A saved id survives relaunch.
- Rejected input is not stored, and the previous value survives the attempt.
- The redirect scheme for a club-supplied id is `ch.ski.video-viewer`, and
  it is registered in both apps' `Info.plist` — a scheme the app does not
  register is a redirect that never comes back.

  **Parse the plists; do not search them as text.** The text version was
  written first and could not fail: the Mac bundle's `CFBundleIdentifier` is
  *also* `ch.ski.video-viewer`, so `contains(...)` stayed true after the URL
  scheme was deleted outright. Caught only by deliberately breaking it. The
  assertion has to reach into `CFBundleURLTypes` specifically.

Every one of these was confirmed to fail against a deliberately broken
implementation before being trusted — the five breaks were: `configuration`
ignoring a stored id, `configuration` never falling back, `save` writing
before validating, and each app in turn dropping the scheme.

## Not in scope

Other providers. Dropbox and OneDrive reach production through a form
review rather than a paid annual audit, so a provider added later should
ship one app key and show no configuration at all. Whether credentials are
club-supplied is a property of the provider, not of this screen — but
generalising on one example would be guessing at the second. Revisit when
Dropbox is actually built.
