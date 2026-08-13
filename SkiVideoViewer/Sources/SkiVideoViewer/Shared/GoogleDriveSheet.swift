import SkiVideoCore
import SwiftUI

/// A placeholder. `RemoteLibraryProvider`, `RemoteLibraryIndex` and
/// `ClipCache` can already open a cloud library end to end — see
/// `ViewerModel.openRemoteLibrary` — but nothing in this app target can
/// obtain the credentials `GoogleDriveProvider` needs to do it: sign-in is a
/// later plan's job (`ASWebAuthenticationSession`, the loopback/custom-scheme
/// split, the Shared Drive picker). Until then a cloud library is opened
/// programmatically, by a caller that already has a token, not from this
/// sheet.
struct GoogleDriveSheet: View {
    @ObservedObject var model: ViewerModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Shared Drive")
                .font(.title2.bold())
            Text("Google sign-in is not wired up yet. A cloud library can only be opened programmatically for now — there is no button here that will connect one.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
