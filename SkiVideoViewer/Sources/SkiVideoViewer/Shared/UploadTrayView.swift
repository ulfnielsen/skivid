import SkiVideoCore
import SwiftUI

/// The sorted clips waiting to go to the club's Drive, and the one button that
/// sends them.
///
/// Read standing in a lift queue, on a phone: one column, the file name on its
/// own line with athlete, event and size under it, and the state at the end of
/// the row in a word, not a colour alone. A failure keeps its reason under the
/// clip it belongs to, with a Retry beside it, so a dropped signal costs one
/// tap and no re-tagging. The batch's controls ride in a bar at the bottom,
/// where a thumb is.
///
/// What it lists, and what is done, come from `UploadBatchModel` — from disk
/// and from Drive, never from memory — so this view refreshes on appearing and
/// holds no state of its own.
struct UploadTrayView: View {
    @ObservedObject var model: UploadBatchModel

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            notices
            if model.entries.isEmpty {
                // Silent when the folder could not be read: the notice above
                // says why, and "nothing sorted" would contradict it.
                Text(model.readProblem != nil ? ""
                     : model.isCheckingDrive ? "Looking for sorted clips…" : "No sorted clips on this device yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    row(entry)
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actions
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .onAppear { model.refresh() }
        // A container, so this identifier names the tray without replacing
        // the identifiers of the controls inside it — on a plain stack it is
        // handed down to every child, and `upload.start` became unfindable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upload.tray")
    }

    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stopReason = model.stopReason {
                Label(stopReason, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("upload.stopReason")
            }
            if let readProblem = model.readProblem {
                Label(readProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let checkProblem = model.checkProblem {
                Label(checkProblem, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if model.isCheckingDrive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(model.libraryName) for clips already there…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, hasNotices ? 8 : 0)
    }

    private var hasNotices: Bool {
        model.stopReason != nil || model.readProblem != nil || model.checkProblem != nil
            || model.isCheckingDrive
    }

    private func row(_ entry: UploadBatchModel.Entry) -> some View {
        let name = entry.clip.file.lastPathComponent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                stateLabel(entry.state)
                    .accessibilityIdentifier("upload.state.\(name)")
            }
            Text("\(entry.clip.athlete) · \(entry.clip.event) · "
                 + Self.sizeFormatter.string(fromByteCount: entry.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // A different clip had this name in Drive, so this one went up —
            // or was found from an earlier run — under a numbered name. Said
            // so, or a coach looking for IMG_0413 in Drive finds someone
            // else's clip there. See `UploadBatchModel.placement(of:in:)`.
            if let driveName = entry.driveName {
                Text(entry.state == .uploaded ? "Uploaded as \(driveName)" : "In Drive as \(driveName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("upload.driveName.\(name)")
            }
            if case let .failed(reason) = entry.state {
                HStack(alignment: .firstTextBaseline) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { model.retry(entry.id) }
                        .buttonStyle(.bordered)
                        .disabled(model.isUploading)
                        .accessibilityIdentifier("upload.retry.\(name)")
                }
            }
        }
        .padding(.vertical, 2)
        // A container for the same reason as the tray's: the row keeps its
        // own identifier and `upload.state.<name>` survives inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upload.row.\(name)")
    }

    @ViewBuilder
    private func stateLabel(_ state: UploadBatchModel.ClipState) -> some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .uploading:
            // Indeterminate: the resumable upload reports no byte progress,
            // and a bar that sat at zero would read as stuck.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Uploading")
            }
        case .uploaded:
            Label("Uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .alreadyInDrive:
            Label("In Drive", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.isUploading {
            VStack(spacing: 8) {
                ProgressView(value: Double(model.runDone), total: Double(max(model.runTotal, 1)))
                HStack {
                    Text("Uploading \(min(model.runDone + 1, model.runTotal)) of \(model.runTotal) to \(model.libraryName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("upload.cancel")
                }
            }
        } else {
            VStack(spacing: 8) {
                Button {
                    model.uploadWaiting()
                } label: {
                    Text(uploadTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.waitingCount == 0)
                .accessibilityIdentifier("upload.start")
                if model.failedCount > 0 {
                    Button("Retry \(model.failedCount) failed") { model.retryFailed() }
                        .accessibilityIdentifier("upload.retryFailed")
                }
            }
        }
    }

    private var uploadTitle: String {
        let count = model.waitingCount
        if count == 0 { return "Nothing waiting to upload" }
        return "Upload \(count) clip\(count == 1 ? "" : "s") to \(model.libraryName)"
    }
}
