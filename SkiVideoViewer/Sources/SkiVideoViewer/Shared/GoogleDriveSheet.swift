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
            if let provider = GoogleDriveSheet.makeProvider() {
                Text("Sign in with the club's Google account to see the Shared Drives it can open.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Sign in with Google") {
                        Task { await model.signIn(with: provider) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(GoogleClientSecretsLoader.missingConfigurationMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
    /// "Two OAuth clients, two redirect strategies". The client's id and
    /// secret come from `GoogleClientSecretsLoader`, which reads them from a
    /// `client_secret_*.json` on disk rather than a literal in source — see
    /// that type for where it looks. Nil when it finds none, so
    /// `signInSection` can say so instead of offering a button that reaches
    /// Google only to be refused as a misconfigured client.
    private static func makeProvider() -> GoogleDriveProvider? {
        guard let configuration = GoogleClientSecretsLoader.load() else { return nil }
        return GoogleDriveProvider(configuration: configuration)
    }
}
