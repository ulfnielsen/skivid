import SkiVideoCore
import SwiftUI

/// What a coach lands on: the libraries they already have.
///
/// This replaces an empty pane and two toolbar actions — "Open Club Library…"
/// and "Open Folder…" — which asked the same questions on every launch, sign-in
/// and drive listing and folder layout included. Connecting is still all of
/// that; it just happens once, from here, and everything after is a row.
///
/// Sized for the window it actually lands in. The first build of this screen
/// used an inset `List` with caption-sized subtitles, which on a full-screen
/// Mac window read as a rounding error in the middle of an acre of white. A
/// coach opening a laptop at the side of a hill should see the club's library
/// from arm's length, so the rows are cards with real hit targets and the
/// actions sit under them rather than pinned to the bottom of the pane.
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
    @State private var hovering: UUID?

    var body: some View {
        VStack(spacing: 32) {
            if model.libraries.isEmpty {
                empty
            } else {
                list
            }
            actions
        }
        .padding(40)
        // Wide enough for a long club name and a state sentence on one line,
        // narrow enough that the eye does not have to travel the whole of a
        // 27-inch display to get from the icon to the row it belongs to.
        .frame(maxWidth: 720)
        // Centred in whatever is left, rather than stretched into it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshLibraries() }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No libraries yet")
                .font(.largeTitle.weight(.semibold))
            Text("Connect the club's Google Drive, or add a folder of clips from this Mac. "
                 + "Whatever you connect stays here, so this is the last time you have to find it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Libraries")
                .font(.largeTitle.weight(.semibold))

            // A plain stack rather than a `List`: this is a short set of large
            // targets, not a data table, and `List` spent the space on chrome
            // and small type. It scrolls once there are more than a screenful.
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.libraries) { library in
                        row(library)
                    }
                }
            }
            .frame(maxHeight: 460)
        }
    }

    private func row(_ library: Library) -> some View {
        let failed = failures[library.id] != nil
        return Button {
            open(library)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: icon(for: library))
                    .font(.system(size: 30))
                    .foregroundStyle(failed ? Color.orange : Color.accentColor)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(library.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    // The row's state rather than its description: a coach
                    // scanning this list wants to know whether a library is
                    // ready, not what kind it is.
                    Text(subtitle(for: library))
                        .font(.body)
                        .foregroundStyle(failed ? Color.orange : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if opening == library.id {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(hovering == library.id ? 0.09 : 0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? library.id : (hovering == library.id ? nil : hovering) }
        .contextMenu {
            Button("Open") { open(library) }
            Divider()
            // Worded as forgetting rather than deleting, because that is what
            // it does: the clips already downloaded stay, and reconnecting
            // finds them.
            Button("Forget \(library.name)", role: .destructive) {
                model.libraryStore.remove(library.id)
                failures[library.id] = nil
                model.refreshLibraries()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            // The picker the app already has. What is new is on the other side
            // of it: `chooseDirectory` writes the folder down now, so this
            // button and the menu item both leave a row behind.
            Button("Add Folder…") {
                Task { await model.chooseDirectory() }
            }
            Button("Connect Google Drive…", action: onConnectDrive)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .font(.title3)
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
