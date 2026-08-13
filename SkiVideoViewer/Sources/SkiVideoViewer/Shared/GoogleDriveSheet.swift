import SkiVideoCore
import SwiftUI

/// Signs the coach in with the club's Google account, then lists the Shared
/// Drives that account can see.
///
/// No text field of any kind. The sheet used to ask for a client-secret file
/// path and a pasted folder id — which meant only the person who had both
/// could ever connect a Mac to the library. `model.availableRoots` decides
/// which half of the sheet shows: a single button before sign-in, a list of
/// drives after. Choosing a drive fetches nothing by itself — `chooseRoot`
/// only lists the drive's files; a clip's bytes arrive when it is selected.
struct GoogleDriveSheet: View {
    @ObservedObject var model: ViewerModel
    @Binding var isPresented: Bool
    let cache: ClipCache

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Club Library")
                .font(.title2.bold())

            if let signInError = model.signInError {
                Text(signInError)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.availableRoots.isEmpty {
                signInSection
            } else {
                driveList
            }

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with the club's Google account to see the Shared Drives it can open.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Sign in with Google") {
                    Task { await model.signIn(with: GoogleDriveSheet.makeProvider()) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var driveList: some View {
        List(model.availableRoots, id: \.id) { root in
            Button(root.name) {
                Task {
                    await model.chooseRoot(root, cache: cache)
                    isPresented = false
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 260)
    }

    /// A Desktop OAuth client, using the loopback redirect
    /// `AppKitOAuthPresenter` already implements — see the design spec's
    /// "Two OAuth clients, two redirect strategies".
    ///
    /// The id and secret below are placeholders. This app has no registered
    /// Google Cloud client yet: the plan's "Setup this plan needs from a
    /// human" step asks for a Desktop client in a project owned by the
    /// club's Workspace organisation, and sign-in cannot succeed until that
    /// client's real id and secret replace these. Until then, tapping
    /// "Sign in with Google" reaches Google and is refused as a
    /// misconfigured client — a config gap, not a code path this task can
    /// exercise or fix.
    private static func makeProvider() -> GoogleDriveProvider {
        GoogleDriveProvider(configuration: GoogleOAuthConfiguration(
            clientID: "REPLACE-WITH-MACOS-CLIENT-ID.apps.googleusercontent.com",
            clientSecret: "REPLACE-WITH-MACOS-CLIENT-SECRET",
            redirectKind: .loopback
        ))
    }
}
