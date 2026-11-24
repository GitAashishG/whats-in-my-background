import SwiftUI

// Command Line Tools installations do not include Xcode's State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct Dashboard: View {
    @ObservedObject var model: DeskModel
    @ViewState private var expandedLabel: String?
    @ViewState private var sheet: DeskSheet?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSImage(named: "CurtainFox") ?? NSApp.applicationIconImage)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 54, height: 54).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ON THIS MAC").eyebrow().foregroundStyle(DeskInk.jade)
                    Text("Background jobs")
                        .font(.system(size: 38, weight: .medium, design: .serif))
                        .tracking(-1.4)
                }
                Spacer(minLength: 0)
                Button {
                    model.errorMessage = nil
                    sheet = .add
                    model.loadCandidates()
                } label: {
                    Label("Add jobs", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(DeskInk.button)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("addJobs")
                .disabled(model.busy)
            }
            .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 22)

            if let message = model.errorMessage, sheet == nil {
                ErrorStrip(message: message) { model.errorMessage = nil }
            }
            if model.jobs.isEmpty {
                if model.busy {
                    ProgressView("Reading jobs…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyMessage(title: "Your watchlist is empty", detail: "Add a LaunchAgent you wrote or installed to see when it runs.")
                }
            } else {
                HStack {
                    Text("WATCHLIST").eyebrow()
                    Spacer()
                    Text("STATUS / SCHEDULE").eyebrow().padding(.trailing, 25)
                }
                .foregroundStyle(DeskInk.muted)
                .padding(.bottom, 9).padding(.horizontal, 30)
                rule.padding(.horizontal, 30)
                jobList
            }
            footer
        }
        .background(DeskInk.paper)
        .tint(DeskInk.jade)
        .onReceive(model.$jobs) { jobs in
            if let expandedLabel, !jobs.contains(where: { $0.label == expandedLabel }) { self.expandedLabel = nil }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .add: AddJobsSheet(model: model)
            case let .confirm(change, label): ConfirmJobSheet(model: model, change: change, target: label)
            }
        }
    }

    private var jobList: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.jobs) { job in
                        VStack(spacing: 0) {
                            JobRow(job: job, expanded: expandedLabel == job.label) {
                                expandedLabel = expandedLabel == job.label ? nil : job.label
                            }
                            if expandedLabel == job.label { details(for: job) }
                            rule
                        }
                        .id(job.label)
                    }
                }
                .padding(.horizontal, 30)
            }
            .onChange(of: expandedLabel) { _, label in
                if let label { reader.scrollTo(label, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        let running = model.jobs.lazy.filter { $0.state == .running }.count
        return VStack(spacing: 0) {
            rule
            HStack(spacing: 9) {
                Text("\(model.jobs.count) tracked").fontWeight(.medium)
                Text("·").accessibilityHidden(true)
                Text("\(running) running").foregroundStyle(running == 0 ? DeskInk.muted : DeskInk.jade)
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating jobs") }
                Button { model.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh jobs (⌘R)")
                .accessibilityIdentifier("refreshJobs")
                .disabled(model.busy)
            }
            .font(.callout.monospacedDigit()).foregroundStyle(DeskInk.muted)
            .padding(.horizontal, 30).padding(.vertical, 12)
            .background(DeskInk.band)
        }
    }

    private func details(for job: ManagedJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 13, verticalSpacing: 5) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Label").foregroundStyle(DeskInk.muted)
                    Text(job.label).font(.system(.callout, design: .monospaced)).accessibilityIdentifier("selectedJobLabel")
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Schedule").foregroundStyle(DeskInk.muted)
                    Text(job.schedule)
                }
                if let executable = job.executable {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Program").foregroundStyle(DeskInk.muted)
                        Text(executable).font(.system(.callout, design: .monospaced))
                    }
                }
                if let pid = job.pid, job.state == .running {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Process ID").foregroundStyle(DeskInk.muted)
                        Text(verbatim: String(pid)).monospacedDigit()
                    }
                }
            }
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            if let note = job.note {
                Label(note, systemImage: "exclamationmark.triangle").textSelection(.enabled)
            } else {
                Text(job.state.explanation).foregroundStyle(DeskInk.muted)
            }
            HStack(spacing: 8) {
                if job.note == nil {
                    switch job.state {
                    case .running, .idle:
                        Button("Stop until login…") { sheet = .confirm(.stop, job.label) }.accessibilityIdentifier("stopJob")
                    case .unloaded:
                        Button("Load now") { model.perform(.load, on: job) }.accessibilityIdentifier("loadJob")
                    case .archived:
                        Button("Restore startup…") { sheet = .confirm(.restore, job.label) }.accessibilityIdentifier("restoreJob")
                    case .unavailable: EmptyView()
                    }
                    if DeskChange.archive.permits(job) {
                        Button("Remove from startup…") { sheet = .confirm(.archive, job.label) }.accessibilityIdentifier("archiveJob")
                    }
                }
                Spacer(minLength: 8)
                Button("Stop tracking…") { sheet = .confirm(.untrack, job.label) }
                    .buttonStyle(.borderless)
                    .help(job.state == .archived ? "Restore startup before you stop tracking this job." : "Remove this job from your watchlist without changing how it runs.")
                    .accessibilityIdentifier("untrackJob").disabled(job.state == .archived)
            }
            .controlSize(.small).disabled(model.busy)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 13)
        .overlay(alignment: .leading) { Rectangle().fill(DeskInk.jade.opacity(0.4)).frame(width: 2) }
        .padding(.bottom, 17)
    }
}

private struct JobRow: View {
    let job: ManagedJob
    let expanded: Bool
    let toggle: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.name).font(.system(size: 16, weight: .semibold))
                    Text(job.label).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DeskInk.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: job.state.symbol).font(.system(size: 10, weight: .semibold))
                        Text(job.state.displayName).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(job.state == .running ? DeskInk.jade : Color.primary)
                    Text(job.schedule).font(.callout).foregroundStyle(DeskInk.muted)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                }
                .frame(width: 174, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(expanded || hovered ? DeskInk.jade : DeskInk.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 13)
            }
            .padding(.vertical, 13).frame(minHeight: 71)
            .background(hovered ? DeskInk.jade.opacity(0.055) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text("\(job.name), \(job.label)"))
        .accessibilityValue(Text("\(job.state.displayName), \(job.schedule), \(expanded ? "expanded" : "collapsed")"))
        .accessibilityHint(expanded ? "Hide job details" : "Show job details and actions")
        .accessibilityIdentifier("jobRow.\(job.label)")
    }
}

private extension JobState {
    var displayName: String { self == .idle ? "Waiting" : rawValue }

    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .idle: "clock"
        case .unloaded: "pause.circle"
        case .archived: "archivebox"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    var explanation: String {
        switch self {
        case .running: "This job is running in your login session."
        case .idle: "This job is loaded and waiting for its next trigger."
        case .unloaded: "This job is stopped. Its startup settings are still installed for your next login."
        case .archived: "The startup file is in the archive. Restore it to load this job again."
        case .unavailable: "Refresh to check whether this job is available again."
        }
    }
}

private enum DeskSheet: Identifiable {
    case add, confirm(DeskChange, String)
    var id: String {
        switch self {
        case .add: "add"
        case let .confirm(change, label): "\(change.rawValue):\(label)"
        }
    }
}

private enum DeskChange: String {
    case stop, archive, restore, untrack

    var button: String {
        switch self {
        case .stop: "Stop until login"
        case .archive: "Remove from startup"
        case .restore: "Restore startup"
        case .untrack: "Stop tracking"
        }
    }

    var detail: String {
        switch self {
        case .stop: "Unload this job now and pause its scheduled runs. Its startup file stays in place for your next login. Choose Load now to bring it back sooner."
        case .archive: "Unload this job and move its startup file to the archive. It won’t load at your next login. Your scripts stay in place, and you can restore startup here."
        case .restore: "Move the archived startup file back to your LaunchAgents folder and load the job. It may run immediately, depending on its schedule."
        case .untrack: "Remove this job from your watchlist. Its activity and startup settings won’t change."
        }
    }

    func permits(_ job: ManagedJob) -> Bool {
        switch self {
        case .stop: job.note == nil && (job.state == .running || job.state == .idle)
        case .archive: job.note == nil && (job.state == .running || job.state == .idle || job.state == .unloaded)
        case .restore: job.note == nil && job.state == .archived
        case .untrack: job.state != .archived
        }
    }
}

@MainActor
private struct ConfirmJobSheet: View {
    @ObservedObject var model: DeskModel
    let change: DeskChange
    let target: String
    @Environment(\.dismiss) private var dismiss

    private var permittedJob: ManagedJob? {
        model.jobs.first { $0.label == target && change.permits($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("\(change.button)?").sheetTitle()
            Text(target).font(.system(.body, design: .monospaced)).foregroundStyle(DeskInk.jade)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("confirmationTarget")
            Text(permittedJob == nil ? "This job has changed. Cancel and check its current status before trying again." : change.detail)
                .fixedSize(horizontal: false, vertical: true)
            rule.padding(.top, 5)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(change.button) {
                    guard !model.busy, let job = permittedJob else { return }
                    dismiss()
                    switch change {
                    case .stop: model.perform(.stop, on: job)
                    case .archive: model.perform(.archive, on: job)
                    case .restore: model.perform(.restore, on: job)
                    case .untrack: model.untrack(job.label)
                    }
                }
                .accessibilityIdentifier("confirmAction").disabled(model.busy || permittedJob == nil)
            }
        }
        .padding(24).frame(width: 440, alignment: .leading).background(DeskInk.paper)
    }
}

@MainActor
private struct AddJobsSheet: View {
    @ObservedObject var model: DeskModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: Set<String> = []
    @ViewState private var filter = ""

    private var filtered: [String] {
        filter.isEmpty ? model.candidates : model.candidates.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add jobs").sheetTitle()
                Text("Choose LaunchAgents you wrote or installed. Adding them to your watchlist won’t start or stop them.")
                    .foregroundStyle(DeskInk.muted).fixedSize(horizontal: false, vertical: true)
                TextField("Filter by label", text: $filter)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Filter by label").padding(.top, 5)
            }
            .padding(.horizontal, 24).padding(.vertical, 19)
            rule
            if let message = model.errorMessage {
                ErrorStrip(message: message) { model.errorMessage = nil }
            }
            if model.busy {
                ProgressView("Reading LaunchAgents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.candidates.isEmpty {
                if model.errorMessage != nil {
                    EmptyMessage(title: "Couldn’t read available jobs", detail: "Choose Reload to try again.")
                } else {
                    EmptyMessage(title: "No jobs to add", detail: "Your LaunchAgents folder has no other eligible jobs.")
                }
            } else if filtered.isEmpty {
                EmptyMessage(title: "No matching labels", detail: "Try a shorter name or clear the filter.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { label in
                            Toggle(isOn: Binding(get: { selection.contains(label) }, set: { on in
                                if on { selection.insert(label) } else { selection.remove(label) }
                            })) {
                                Text(label).font(.system(.callout, design: .monospaced))
                            }
                            .toggleStyle(.checkbox).padding(.vertical, 10)
                            .accessibilityLabel(Text(label)).accessibilityIdentifier("candidate.\(label)")
                            rule
                        }
                    }.padding(.horizontal, 24)
                }
            }
            rule
            HStack {
                Button("Reload") {
                    model.errorMessage = nil
                    model.loadCandidates()
                }.disabled(model.busy)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selection.isEmpty ? "Add to list" : "Add to list (\(selection.count))") {
                    let labels = model.candidates.filter { selection.contains($0) }
                    guard !model.busy, !labels.isEmpty else { return }
                    model.track(labels)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("trackSelected")
                .disabled(selection.isEmpty || model.candidates.isEmpty || model.busy)
            }
            .padding(.horizontal, 24).padding(.vertical, 14).background(DeskInk.band)
        }
        .frame(width: 470, height: 390).background(DeskInk.paper).tint(DeskInk.jade)
        .onChange(of: model.busy) { _, busy in
            if !busy && model.errorMessage == nil { selection.formIntersection(model.candidates) }
        }
    }
}

private struct EmptyMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(DeskInk.muted)
        }
        .multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(message).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Label("Dismiss error", systemImage: "xmark").labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help("Dismiss error")
        }
        .font(.callout).padding(.horizontal, 24).padding(.vertical, 9)
        .background(Color.orange.opacity(0.09))
    }
}

private extension Text {
    func eyebrow() -> some View { font(.system(size: 10, weight: .semibold)).tracking(1.35) }
    func sheetTitle() -> some View { font(.system(size: 27, weight: .medium, design: .serif)).tracking(-0.7) }
}

@MainActor private var rule: some View { Divider().overlay(DeskInk.rule) }

private enum DeskInk {
    static let paper = adaptive(0xFAF9F5, 0x1B1E1D)
    static let band = adaptive(0xF2F1EB, 0x181B1A)
    static let rule = adaptive(0xD7D9D1, 0x3B403C)
    static let muted = adaptive(0x606862, 0xAEB8B1)
    static let jade = adaptive(0x236952, 0x91D9BC)
    static let button = adaptive(0x285E4D, 0x306551)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}
