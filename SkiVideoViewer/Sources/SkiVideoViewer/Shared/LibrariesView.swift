import SkiVideoCore
import SwiftUI

/// What a coach lands on: the libraries they already have.
///
/// This replaces an empty pane and two toolbar actions — "Open Club Library…"
/// and "Open Folder…" — which asked the same questions on every launch, sign-in
/// and drive listing and folder layout included. Connecting is still all of
/// that; it just happens once, from here, and everything after is a row.
struct LibrariesView: View {

    @ObservedObject var model: ViewerModel
    let cache: ClipCache
    /// Building a provider is the app layer's job — a client secret on disk on
    /// the Mac, a compiled-in client on iPad — so opening a Drive library asks
    /// for one rather than reaching for it.
    let makeProvider: () -> (any RemoteLibraryProvider)?
    let onConnectDrive: () -> Void

    /// The last failure, against the row that produced it. Held here rather
    /// than in the model because it belongs to this screen: a library that
    /// could not open is still a library, and the sentence explaining why is
    /// worth exactly as long as the coach is looking at the list.
    @State private var failures: [UUID: String] = [:]
    @State private var opening: UUID?

    var body: some View {
        VStack(spacing: 16) {
            if model.libraries.isEmpty {
                empty
            } else {
                list
            }
            actions
        }
        .padding(24)
        .frame(maxWidth: 560)
        .onAppear { model.refreshLibraries() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No libraries yet")
                .font(.title3.weight(.semibold))
            Text("Connect the club's Google Drive, or add a folder of clips from this Mac. "
                 + "Whatever you connect stays here, so this is the last time you have to find it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Libraries")
                .font(.title3.weight(.semibold))

            List {
                ForEach(model.libraries) { library in
                    row(library)
                        .contentShape(Rectangle())
                        .onTapGesture { open(library) }
                        .contextMenu {
                            Button("Open") { open(library) }
                            Divider()
                            // Worded as forgetting rather than deleting,
                            // because that is what it does: the clips already
                            // downloaded stay, and reconnecting finds them.
                            Button("Forget \(library.name)", role: .destructive) {
                                model.libraryStore.remove(library.id)
                                failures[library.id] = nil
                                model.refreshLibraries()
                            }
                        }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160, maxHeight: 320)
        }
    }

    private func row(_ library: Library) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: library))
                .font(.title3)
                .foregroundStyle(failures[library.id] == nil ? .secondary : Color.orange)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                    .font(.body.weight(.medium))
                // One line, and it is the row's state rather than its
                // description: a coach scanning this list is looking for
                // whether a library is ready, not what kind it is.
                Text(subtitle(for: library))
                    .font(.caption)
                    .foregroundStyle(failures[library.id] == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if opening == library.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            // The picker the app already has. What is new is on the other side
            // of it: `chooseDirectory` writes the folder down now, so this
            // button and the menu item both leave a row behind.
            Button("Add Folder…") {
                Task { await model.chooseDirectory() }
            }
            Button("Connect Google Drive…", action: onConnectDrive)
                .buttonStyle(.borderedProminent)
        }
    }

    private func open(_ library: Library) {
        guard opening == nil else { return }
        opening = library.id
        failures[library.id] = nil
        Task {
            let failure = await model.open(library, cache: cache, provider: makeProvider())
            failures[library.id] = failure
            opening = nil
        }
    }

    private func icon(for library: Library) -> String {
        if failures[library.id] != nil { return "exclamationmark.triangle" }
        switch library.kind {
        case .drive:  return "externaldrive.connected.to.line.below"
        case .folder: return "folder"
        }
    }

    private func subtitle(for library: Library) -> String {
        if let failure = failures[library.id] { return failure }
        let kind: String
        switch library.kind {
        case .drive:  kind = "Google Drive"
        case .folder: kind = "This Mac"
        }
        guard let opened = library.lastOpened else { return kind }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(kind) · opened \(formatter.localizedString(for: opened, relativeTo: Date()))"
    }
}
