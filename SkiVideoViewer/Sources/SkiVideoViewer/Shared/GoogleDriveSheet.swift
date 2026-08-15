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

    /// Where a club-supplied OAuth client id is read and written. A struct over
    /// `UserDefaults`, so holding one costs nothing and it needs no `@StateObject`;
    /// `savedClientID` below is what actually drives redraws.
    private let store = ClubOAuthClientStore()

    /// Mirrors the store so edits redraw the sheet — SwiftUI cannot observe
    /// `UserDefaults` through a plain struct. Seeded from the store at init so
    /// a club that set this up on a previous launch sees its id, not a blank
    /// field that looks like the setup was lost.
    @State private var savedClientID: String?
    @State private var clientIDField = ""
    @State private var clientIDError: String?
    @State private var isShowingClubSetup: Bool

    init(model: ViewerModel, isPresented: Binding<Bool>, cache: ClipCache) {
        self.model = model
        self._isPresented = isPresented
        self.cache = cache
        let store = ClubOAuthClientStore()
        self._savedClientID = State(initialValue: store.clientID)
        // Expanded only when there is no usable client at all — on a Mac with
        // no client-secrets file and no club id, this section is the only way
        // forward, and a coach should not have to find a disclosure triangle to
        // discover that.
        self._isShowingClubSetup = State(initialValue: GoogleDriveSheet.makeProvider() == nil)
    }

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

            Divider()
            clubClientSection
        }
    }

    /// Lets a club that is not the one this app was written for use its own
    /// Google OAuth client — the app's consent screen has an Internal audience,
    /// so no outside account can sign in with the built-in client at all. See
    /// `ClubOAuthClientStore` for why that is the design and not a workaround.
    ///
    /// Collapsed by default, and below the button: the overwhelmingly common
    /// case is a coach who should press "Sign in with Google" and nothing else.
    /// It starts expanded only when there is no client configured at all, which
    /// on a Mac without a client-secrets file is the one situation where this
    /// section is the only way forward.
    private var clubClientSection: some View {
        DisclosureGroup(isExpanded: $isShowingClubSetup) {
            VStack(alignment: .leading, spacing: 10) {
                if let savedClientID {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Using your club's client")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use built-in") {
                            store.clear()
                            self.savedClientID = nil
                            clientIDField = ""
                            clientIDError = nil
                        }
                        .font(.caption)
                    }
                    Text(savedClientID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Client ID", text: $clientIDField, prompt: Text("…apps.googleusercontent.com"))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                if let clientIDError {
                    Text(clientIDError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Save") { saveClubClientID() }
                        .disabled(clientIDField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // The values a club cannot guess. Everything else is in the
                // linked walkthrough, so this stays short enough to read
                // standing up at a race.
                //
                // Deliberately no markdown: SwiftUI parses it only in string
                // *literals*, and these were once written as `+`-concatenated
                // expressions, which put "type **iOS**" on screen with the
                // asterisks showing. Structure carries the emphasis instead —
                // and the bundle id gets its own line so it can be selected
                // and copied, which is what someone mid-setup actually wants.
                VStack(alignment: .leading, spacing: 4) {
                    Text("In Google Cloud Console, create an OAuth client of type iOS with this bundle ID:")
                    Text(ClubOAuthClientStore.redirectScheme)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Set its consent screen to audience Internal, with the scope drive.readonly. "
                         + "Full walkthrough: docs/google-oauth-club-setup.md")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            Text("Use your club's own Google account")
                .font(.callout)
        }
    }

    private func saveClubClientID() {
        do {
            savedClientID = try store.save(clientIDField)
            clientIDField = ""
            clientIDError = nil
            // Any failure from the built-in client is about a client that is no
            // longer in use, so leaving it on screen would send a club that just
            // fixed its setup back to debugging the wrong thing.
            model.clearSignInError()
        } catch {
            clientIDError = error.localizedDescription
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
    /// A club-supplied client wins over the built-in one on both platforms —
    /// see `ClubOAuthClientStore`. It is always an iOS-type client with no
    /// secret, redirecting through the one scheme every club registers against,
    /// because Google blocks loopback for iOS clients and asking each club for a
    /// second Desktop client just to keep the Mac's listener would double the
    /// setup.
    private static func configuration() -> GoogleOAuthConfiguration? {
        ClubOAuthClientStore().configuration(fallingBackTo: builtInConfiguration())
    }

    private static func builtInConfiguration() -> GoogleOAuthConfiguration? {
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
