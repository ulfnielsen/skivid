# Connecting your club's Google Drive

This app can open training videos straight from a Google Shared Drive. To do
that, your club registers its own Google sign-in credential — about ten
minutes, once, by someone with admin access to your Google Workspace.

## Why your club needs its own

Google requires an app that signs in accounts from *outside* its own
organisation to pass a verification review and a paid annual security
assessment. Rather than put every club behind that, this app lets each club
register its own credential inside its own Google Workspace, where Google
exempts it from review.

The practical consequences are good ones: your club's video traffic stays
inside your own Google project, your data is never visible to anyone else
using this app, and you can revoke access yourself at any time without asking
us.

You will need someone who can sign in at
[console.cloud.google.com](https://console.cloud.google.com) with an account in
your club's Workspace.

## 1. Create a project

In the Google Cloud Console, create a project — call it something like
`Ski Video Viewer`. If your club already has one, you can reuse it.

## 2. Turn on the Drive API

Under **APIs & Services → Library**, search for **Google Drive API** and
enable it. Without this, sign-in succeeds and then every video listing comes
back empty.

## 3. Configure the consent screen

Under **APIs & Services → OAuth consent screen**:

- **User type: Internal.** This is the important one. Internal means only
  accounts in your own Workspace can sign in, and it is what exempts you from
  Google's verification review. If Google will not let you pick Internal, your
  account is not part of a Workspace organisation — see *Troubleshooting*.
- App name: anything your coaches will recognise. They see it on the consent
  screen.
- Add the scope `https://www.googleapis.com/auth/drive.readonly`.

Read-only is deliberate. The app never writes to, moves, or deletes anything
in your Drive.

## 4. Create the credential

Under **APIs & Services → Credentials → Create Credentials → OAuth client ID**:

- **Application type: iOS.** Choose iOS even if your coaches only use Macs.
  The app uses this client type on both, because Google no longer allows the
  Mac-style sign-in method for new configurations.
- **Bundle ID:** `dk.dyregod.video-viewer`

  Type it exactly. This is what tells Google it is safe to hand the sign-in
  result back to this app, and sign-in fails with `redirect_uri_mismatch` if
  it differs by even one character.

Google then shows you a **Client ID** ending in
`.apps.googleusercontent.com`. Copy it. There is no client secret for this
type, and you do not need one.

## 5. Enter it in the app

Open **Open Club Library**, expand **Use your club's own Google account**,
paste the Client ID, and press **Save**. Then press **Sign in with Google**.

The Client ID is not a secret — it identifies the app, it does not grant
access to anything — so it is fine to send it to your coaches in a normal
message. What grants access is each coach signing in with their own Google
account.

## Troubleshooting

**"Internal" is greyed out on the consent screen.** The account you are using
is a personal Google account, not part of a Workspace organisation. Only a
Workspace can have Internal apps. Use an account on your club's domain.

**`redirect_uri_mismatch` when signing in.** The Bundle ID in step 4 does not
match. It must be exactly `dk.dyregod.video-viewer` — no `.ipad`, no club name
appended, no trailing space.

**"This app is blocked" or an unverified-app warning.** The consent screen is
set to External rather than Internal. Change it to Internal in step 3.

**Sign-in works, but no drives appear.** Either the Drive API is not enabled
(step 2), or the account that signed in is not a member of any Shared Drive.
Shared Drive membership is separate from ordinary file sharing — check under
the Shared Drive's own **Manage members**.

**A coach outside your Workspace cannot sign in.** That is Internal working as
intended. Guest coaches need an account on your club's domain, or membership
in the Workspace.

## Going back to the built-in credential

Press **Use built-in** in the same section. That only affects this device, and
does not change anything in your Google project.
