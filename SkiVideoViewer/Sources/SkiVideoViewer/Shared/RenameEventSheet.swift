import SkiVideoCore
import SwiftUI

/// A sidebar event name, made `Identifiable` for `.sheet(item:)`.
struct IdentifiedName: Identifiable { let id: String }

/// Rename one event across every athlete. The date and title are edited
/// apart and joined by `SortingLibrary.eventFolder`, so a renamed event is
/// spelled exactly as a freshly sorted one.
///
/// Two views, not one: `EventRenameModel` publishes its progress, and a
/// model held in `@State` is not observed — the progress bar and the Rename
/// button's state would never update. The outer view asks `ViewerModel` for
/// the rename (or why there is none); `RenameEventForm` observes it.
///
/// `viewerModel` is a plain `let`, not observed: the sheet only calls it, and
/// observing would re-render the form on every tick of the playback clock.
struct RenameEventSheet: View {
    let viewerModel: ViewerModel
    let eventName: String
    @Environment(\.dismiss) private var dismiss

    @State private var rename: EventRenameModel?
    @State private var refusal: String?

    var body: some View {
        Group {
            if let rename {
                RenameEventForm(viewerModel: viewerModel, rename: rename, eventName: eventName)
            } else {
                NavigationStack {
                    Form {
                        if let refusal { Text(refusal).foregroundStyle(.red) }
                    }
                    .navigationTitle("Rename Event")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 300)
        #endif
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard rename == nil, refusal == nil else { return }
        do { rename = try viewerModel.eventRenameTarget(for: eventName) }
        catch { refusal = error.localizedDescription }
    }
}

/// What the "Merge?" dialog says, counted when it is asked.
private struct MergeQuestion {
    let name: String
    let from: EventClipCount
    let into: EventClipCount
}

private struct RenameEventForm: View {
    let viewerModel: ViewerModel
    @ObservedObject var rename: EventRenameModel
    let eventName: String
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var title: String
    /// True from Rename (or Merge) until the library has been re-read.
    /// `rename.isRunning` alone leaves gaps — the `targetExists` read before
    /// the run and the reload after it — in which a second press would start
    /// a second run.
    @State private var isBusy = false
    @State private var mergeQuestion: MergeQuestion?
    /// The name the event now has, once a run has finished.
    @State private var finishedName: String?
    /// A failure outside the run itself: reading whether the target exists,
    /// or re-reading the library afterwards.
    @State private var problem: String?

    init(viewerModel: ViewerModel, rename: EventRenameModel, eventName: String) {
        self.viewerModel = viewerModel
        self.rename = rename
        self.eventName = eventName
        let parts = SortingLibrary.eventFolderParts(eventName)
        _date = State(initialValue: parts.date ?? Date())
        _title = State(initialValue: parts.title)
    }

    private var newName: String? { try? SortingLibrary.eventFolder(date: date, title: title) }
    private var isFinished: Bool { finishedName != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .accessibilityIdentifier("rename.date")
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("rename.title")
                    if let newName { LabeledContent("New name", value: newName) }
                }
                .disabled(isBusy || isFinished)
                if rename.isRunning {
                    ProgressView(value: Double(rename.done), total: Double(max(rename.total, 1))) {
                        Text("Renaming \(rename.done) of \(rename.total)…")
                    }
                }
                if let stop = rename.stopReason {
                    Text(stop).foregroundStyle(.red).accessibilityIdentifier("rename.stopReason")
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                if let finishedName, rename.stopReason == nil {
                    Text(summary(finishedName)).accessibilityIdentifier("rename.summary")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Rename Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? "Done" : "Cancel") { dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !isFinished {
                        Button("Rename") { Task { await submit() } }
                            .disabled(newName == nil || newName == eventName || isBusy)
                            .accessibilityIdentifier("rename.submit")
                    }
                }
            }
            .confirmationDialog(
                mergeQuestion.map { "\u{201C}\($0.name)\u{201D} already exists" } ?? "",
                isPresented: Binding(get: { mergeQuestion != nil }, set: { if !$0 { mergeQuestion = nil } }),
                titleVisibility: .visible,
                presenting: mergeQuestion
            ) { question in
                Button("Merge") { Task { await merge(into: question.name) } }
                    .accessibilityIdentifier("rename.merge")
                Button("Choose Another Name") { mergeQuestion = nil }
                    .accessibilityIdentifier("rename.otherName")
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { question in
                Text("It has \(Self.count(question.into.clips, "clip")) for "
                     + "\(Self.count(question.into.athletes, "athlete")). Merge \u{201C}\(eventName)\u{201D} "
                     + "(\(Self.count(question.from.clips, "clip")), \(Self.count(question.from.athletes, "athlete"))) "
                     + "into it?")
            }
        }
        // A swipe down must not leave a rename running behind a closed sheet.
        .interactiveDismissDisabled(isBusy)
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func summary(_ name: String) -> String {
        guard !rename.leftInPlace.isEmpty else { return "Renamed to \(name)." }
        let names = rename.leftInPlace.compactMap(\.last).joined(separator: ", ")
        return "Done. \(rename.leftInPlace.count) file(s) stayed in \u{201C}\(eventName)\u{201D} because the same "
            + "name is already in the target: \(names)."
    }

    /// Rename: asks "Merge?" first when the name is taken; otherwise runs
    /// without permission to merge, so a target that appears in the meantime
    /// stops the run instead of being merged into unasked.
    private func submit() async {
        guard let name = newName, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do {
            if try await rename.targetExists(newName: name) {
                askMerge(name)
                return
            }
        } catch {
            problem = error.localizedDescription
            return
        }
        await run(name, allowMerge: false)
    }

    /// The only caller that may merge: the coach pressed Merge.
    private func merge(into name: String) async {
        guard !isBusy else { return }
        mergeQuestion = nil
        isBusy = true
        defer { isBusy = false }
        problem = nil
        await run(name, allowMerge: true)
    }

    private func run(_ name: String, allowMerge: Bool) async {
        let ok = await rename.run(newName: name, allowMerge: allowMerge)
        // Re-read either way: after a stop the sidebar must show honestly
        // which athletes are under which name. The rename is named so a
        // local clip that was open follows its folder to the new name.
        do {
            try await viewerModel.reloadOpenLibrary(renamedEvent: (from: eventName, to: name))
        } catch {
            problem = "The library could not be re-read: \(error.localizedDescription) Press Refresh to try again."
        }
        if ok {
            finishedName = name
            return
        }
        // The target can appear between the first check and the run — Drive's
        // consent sheet may sit in between for as long as the coach takes —
        // and then the run stops before moving anything. Ask again, counted
        // from the library just re-read. Detected by asking the folders, not
        // by matching the stop text. `done == 0` keeps a run that stopped
        // partway for its own reason showing that reason instead.
        if !allowMerge, rename.done == 0, (try? await rename.targetExists(newName: name)) == true {
            askMerge(name)
        }
    }

    private func askMerge(_ name: String) {
        mergeQuestion = MergeQuestion(name: name,
                                      from: viewerModel.eventClipCount(named: eventName),
                                      into: viewerModel.eventClipCount(named: name))
    }
}
