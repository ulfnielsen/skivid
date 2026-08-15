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
    /// Which of the two folders nearest a clip is the athlete and which is
    /// the event, for whichever drive is chosen next. `.eventThenAthlete`
    /// matches the local convention, so it stays the default until a coach
    /// says otherwise — this sheet is the one place that convention is
    /// "settable when a remote library is opened," per the design.
    @State private var folderConvention: FolderConvention = .eventThenAthlete

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
        VStack(alignment: .leading, spacing: 12) {
            // This club's Shared Drive nests `<athlete>/<event>/clip.mp4` —
            // the reverse of the local convention — and a wrong pick here is
            // what used to show athlete names as section headers, reversed
            // clip captions, and reversed ordering throughout the sidebar.
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder layout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Folder layout", selection: $folderConvention) {
                    Text("Event, then athlete").tag(FolderConvention.eventThenAthlete)
                    Text("Athlete, then event").tag(FolderConvention.athleteThenEvent)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            List(model.availableRoots, id: \.id) { root in
                Button(root.name) {
                    Task {
                        if await model.chooseRoot(root, cache: cache, convention: folderConvention) {
                            isPresented = false
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
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
        guard let configuration = configuration() else { return nil }
        return GoogleDriveProvider(configuration: configuration)
    }

    /// Where each platform's OAuth client comes from — and they genuinely
    /// differ, rather than one being a fallback for the other.
    ///
    /// macOS reads a Desktop client from a `client_secret_*.json` beside the
    /// repo, which keeps a credential out of git and lets the file be swapped
    /// without a rebuild. iPadOS cannot: it has no home directory to search,
    /// and no such file exists on a device. Its client is compiled in.
    ///
    /// They are also different *clients*, not the same one reached two ways.
    /// Google issues an iOS client no secret and refuses it a loopback
    /// redirect — blocked since October 2022 — so the iPad redirects through
    /// the reverse-DNS scheme in `IOSOAuthPresenter.callbackScheme` while the
    /// Mac keeps its loopback listener.
    private static func configuration() -> GoogleOAuthConfiguration? {
        #if os(macOS)
        return GoogleClientSecretsLoader.load()
        #else
        return GoogleOAuthConfiguration(
            clientID: "1075094033080-autj2djudlifsgtr0rd51910531ig1qt.apps.googleusercontent.com",
            // Google issues none for an iOS client, and sending an empty one
            // is rejected — which is why the field is optional at all.
            clientSecret: nil,
            redirectKind: .customScheme(IOSOAuthPresenter.callbackScheme)
        )
        #endif
    }
}
