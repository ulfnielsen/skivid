import SwiftUI

struct GoogleDriveSheet: View {
    @ObservedObject var model: ViewerModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Shared Drive")
                .font(.title2.bold())
            Text("Sign in with a Google desktop OAuth client, then browse video files under a Shared Drive folder. The client secret stays in its selected location; the refresh token is stored in your macOS Keychain.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("OAuth client-secret JSON")
                    .font(.headline)
                HStack {
                    TextField("Choose client-secret JSON…", text: $model.clientSecretsPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        model.chooseClientSecretsFile()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shared Drive folder ID")
                    .font(.headline)
                TextField("Paste Shared Drive folder ID", text: $model.driveFolderID)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button(model.isConnectingToDrive ? "Connecting…" : "Connect & Open") {
                    model.connectGoogleDrive()
                    isPresented = false
                }
                .disabled(
                    model.isConnectingToDrive
                        || model.clientSecretsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.driveFolderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
