// App entry point and SwiftUI screens for recording and reviewing sessions.
// The app shares one SessionModel across the Track, History, and Trends tabs.

import AVFoundation
import SwiftUI

@main
struct SleepTrackerApp: App {
    @StateObject private var model = SessionModel()

    var body: some Scene {
        WindowGroup {
            SleepTrackerView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

let nightBackground = Color(red: 0.05, green: 0.06, blue: 0.10)
let surface = Color(red: 0.09, green: 0.11, blue: 0.17)
let accent = Color(red: 0.77, green: 0.80, blue: 1.0)
let muted = Color(red: 0.66, green: 0.70, blue: 0.80)

struct SleepTrackerView: View {
    @EnvironmentObject private var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var tab = 0
    @State private var selectedNight: Night?

    var body: some View {
        TabView(selection: $tab) {
            track
                .tabItem { Label("Track", systemImage: "moon.stars") }
                .tag(0)
            history
                .tabItem { Label("History", systemImage: "clock") }
                .tag(1)
            TrendsView(sessions: model.historyNights) { selectedNight = $0 }
                .tabItem { Label("Trends", systemImage: "chart.bar") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(accent)
        .sheet(item: $selectedNight, onDismiss: model.stopPlayback) { night in
            NightDetail(originalNight: night)
        }
        .alert("Microphone access", isPresented: $model.showMicrophoneSettings) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to detect nighttime sounds.")
        }
        .alert("Sleep tracker", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Recording can continue while locked. Analysis needs the app open.
            if phase != .active { model.pauseAnalysis() }
            else { Task { await model.becameActive() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            Task { await model.handleInterruption(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { note in
            Task { await model.handleEngineChange(note) }
        }
    }

    private var track: some View {
        NavigationStack {
            TrackView { night in
                tab = 1
                selectedNight = night
                if scenePhase == .active { model.analyze(night.id) }
            }
            .navigationTitle("Track")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var history: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    #if DEBUG
                    if model.sampleNights.isEmpty {
                        Button("Add 60 Days of Sample Data", systemImage: "plus.circle") {
                            model.addSampleData()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Clear Sample Data", systemImage: "trash") {
                            model.clearSampleData()
                        }
                        .buttonStyle(.bordered)
                    }
                    #endif
                    if model.historyNights.isEmpty {
                        ContentUnavailableView(
                            "No sessions yet", systemImage: "moon.zzz",
                            description: Text("Your sessions and saved clips will appear here.")
                        )
                        .padding(.vertical, 64)
                    } else {
                        ForEach(model.historyNights) { night in
                            Button { selectedNight = night } label: {
                                NightRow(night: night, title: night.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(nightBackground.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
        }
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

struct NightRow: View {
    @EnvironmentObject private var model: SessionModel
    let night: Night
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: night.wasInterrupted ? "exclamationmark.circle" : "moon")
                .foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if model.isSampleNight(night.id) {
                    Text("Sample session").font(.caption).foregroundStyle(muted)
                }
                HStack(spacing: 4) {
                    SleepDurationValue(seconds: night.duration)
                    Text("·").foregroundStyle(muted)
                    SoundCountValue(night: night, showUnit: true)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(muted)
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 19))
        .contentShape(Rectangle())
    }
}

struct SoundCountValue: View {
    let night: Night
    var showUnit = false

    var body: some View {
        let count = night.episodes.count
        let unit = count == 1 ? "episode" : "episodes"
        Text(showUnit ? "\(count) \(unit)" : String(count))
            .bold()
            .monospacedDigit()
            .foregroundStyle(night.needsAnalysis ? muted : Self.color(for: count))
            .accessibilityLabel(night.needsAnalysis ? "\(count) \(unit) so far, analysis pending" : "\(count) \(unit)")
    }

    static func color(for count: Int) -> Color {
        switch count {
        case 0: .green
        case 1...5: .yellow
        default: .red
        }
    }
}

private struct NightDetail: View {
    let originalNight: Night
    @EnvironmentObject private var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var editingCheckIn = false
    @State private var showDismissed = false

    private var night: Night {
        model.historyNights.first(where: { $0.id == originalNight.id }) ?? originalNight
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(night.startedAt.formatted(date: .complete, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(muted)

                    if model.isSampleNight(night.id) {
                        Label("Sample session · Audio unavailable", systemImage: "waveform.slash")
                            .font(.subheadline)
                            .foregroundStyle(muted)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        metric(label: "Sleep duration") {
                            SleepDurationValue(seconds: night.duration)
                        }
                        metric(label: "Sound episodes") {
                            SoundCountValue(night: night)
                        }
                    }
                    Text("Estimated from recorded time")
                        .font(.footnote).foregroundStyle(muted)
                    if let full = night.fullRecording, model.audioURL(for: full, in: night) != nil {
                        Button(model.playingID == full.id ? "Stop full recording" : "Play full recording",
                               systemImage: model.playingID == full.id ? "stop.circle" : "play.circle") {
                            model.play(full, in: night)
                        }.disabled(model.startedAt != nil || model.isBusy || model.managingAudio)
                    }
                    ForEach(night.gaps ?? [], id: \.start) { gap in
                        Text("\(gap.reason) · \(gap.start.formatted(date: .omitted, time: .standard)) – \((gap.end ?? night.endedAt).formatted(date: .omitted, time: .standard))")
                            .font(.footnote).foregroundStyle(muted)
                    }
                    checkInCard
                    if night.wasInterrupted {
                        Label("Listening ended early. This session may be incomplete.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(muted)
                            .font(.subheadline)
                    }

                    if model.analyzingID == night.id {
                        ProgressView(value: model.analysisProgress) {
                            Text("Analyzing recording… Keep Sleep tracker open.")
                        } currentValueLabel: {
                            Text(model.analysisProgress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                        .tint(accent)
                    } else if night.needsAnalysis {
                        Text("\(night.analysisProgress, format: .percent.precision(.fractionLength(0))) analyzed")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(muted)
                        Button("Analyze remaining audio") { model.analyze(night.id) }
                            .buttonStyle(.bordered)
                            .disabled(model.startedAt != nil || model.isBusy || model.managingAudio || model.analyzingID != nil)
                    }

                    if let problem = model.analysisProblems[night.id] {
                        Text(problem).font(.footnote).foregroundStyle(muted)
                    }

                    SessionSoundsView(night: night)
                    if night.activeClips.count < night.clips.count {
                        DisclosureGroup("Dismissed clips (\(night.clips.count - night.activeClips.count))", isExpanded: $showDismissed) {
                            ForEach(night.clips.filter { $0.isDismissed == true }) { clip in
                                HStack {
                                    Text(clip.soundTitle)
                                    Text(clip.startedAt, style: .time).foregroundStyle(muted)
                                    Spacer()
                                    Button("Restore") {
                                        model.editClip(clip.id, in: night.id) { $0.isDismissed = nil }
                                    }
                                    .disabled(model.analyzingID == night.id)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    if !model.isSampleNight(night.id), model.startedAt != nil, !night.activeClips.isEmpty {
                        Text("Clips are available to play after the current session ends.")
                            .font(.footnote)
                            .foregroundStyle(muted)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(nightBackground.ignoresSafeArea())
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete session", systemImage: "trash")
                    }
                    .disabled(model.analyzingID == night.id)
                    .tint(accent)
                }
            }
            .sheet(isPresented: $editingCheckIn) {
                NightCheckInEditor(initial: night.checkIn ?? NightCheckIn()) { checkIn in
                    model.editNight(night.id) { $0.checkIn = checkIn }
                }
            }
            .confirmationDialog("Delete this session and its clips?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete session", role: .destructive) {
                    model.delete(night)
                    if !model.historyNights.contains(where: { $0.id == night.id }) { dismiss() }
                }
            }
        }
    }

    private var checkInCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sleep rating").font(.headline)
                Spacer()
                Button(night.checkIn == nil ? "Add" : "Edit") { editingCheckIn = true }
                    .disabled(model.analyzingID == night.id)
            }
            if let checkIn = night.checkIn {
                if let rating = checkIn.restedRating {
                    HStack(spacing: 4) {
                        Text("Rested")
                        RestedScore(value: Double(rating))
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
                if !checkIn.tags.isEmpty {
                    Text(NightTag.allCases.filter { checkIn.tags.contains($0) }.map(\.rawValue).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(muted)
                }
                if !checkIn.notes.isEmpty {
                    Text(checkIn.notes).font(.subheadline)
                }
            }
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric<Value: View>(label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            value().font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.subheadline).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct NightCheckInEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NightCheckIn
    let save: (NightCheckIn?) -> Bool

    init(initial: NightCheckIn, save: @escaping (NightCheckIn?) -> Bool) {
        _draft = State(initialValue: initial)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("How rested do you feel?") {
                    Picker("Rested rating", selection: $draft.restedRating) {
                        Text("Skip").tag(nil as Int?)
                        ForEach(1...5, id: \.self) { rating in
                            Text(String(rating)).tag(Optional(rating))
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("1 · Not rested     5 · Very rested").font(.footnote)
                }
                .listRowBackground(surface)
                Section("Notes") {
                    TextField("Add a note", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                .listRowBackground(surface)
                Section("Tags") {
                    ForEach(NightTag.allCases) { tag in
                        Toggle(tag.rawValue, isOn: Binding(
                            get: { draft.tags.contains(tag) },
                            set: { selected in
                                if selected { draft.tags.insert(tag) }
                                else { draft.tags.remove(tag) }
                            }
                        ))
                        .tint(accent)
                    }
                }
                .listRowBackground(surface)
            }
            .scrollContentBackground(.hidden)
            .background(nightBackground)
            .navigationTitle("Sleep rating")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        let empty = draft.restedRating == nil && draft.notes.isEmpty && draft.tags.isEmpty
                        if save(empty ? nil : draft) { dismiss() }
                    }
                }
            }
        }
    }
}

private let playbackColor = Color(red: 0.37, green: 0.89, blue: 0.80)

struct ClipRow: View {
    let clip: SoundClip
    let night: Night
    @EnvironmentObject private var model: SessionModel
    @State private var expanded = false
    @State private var editingLabels = false
    @State private var startFraction = 0.0
    @State private var peaks: [Float]?
    @State private var waveformFailed = false

    private var isPlaying: Bool { model.playingID == clip.id }
    private var audioAvailable: Bool { model.audioURL(for: clip, in: night) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if !audioAvailable {
                    Image(systemName: "waveform.slash").font(.title2).foregroundStyle(muted)
                        .accessibilityLabel("Audio unavailable")
                } else {
                    Button {
                        model.play(clip, in: night, from: startFraction)
                    } label: {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(isPlaying ? playbackColor : accent)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(isPlaying ? "Stop clip" : "Play \(clip.soundTitle)")
                    .disabled(model.startedAt != nil || model.isBusy || model.managingAudio)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.soundTitle).font(.headline)
                    Text("\(clip.startedAt.formatted(date: .omitted, time: .shortened)) · \(durationText(clip.duration))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(muted)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Edit labels", systemImage: "tag") {
                        editingLabels = true
                    }
                    Button("Dismiss detection", systemImage: "eye.slash") {
                        model.editClip(clip.id, in: night.id) { $0.isDismissed = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Clip options")
                .disabled(model.analyzingID == night.id)

                if audioAvailable {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(expanded ? "Hide waveform" : "Show waveform")
                }
            }

            if expanded, let url = model.audioURL(for: clip, in: night) {
                waveformPanel
                    .task(id: url) {
                        guard peaks == nil else { return }
                        let loaded = await Task.detached(priority: .utility) {
                            try? ClipWaveform.read(from: url)
                        }.value
                        guard !Task.isCancelled else { return }
                        peaks = loaded
                        waveformFailed = loaded == nil
                    }
            }
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 14))
        .buttonStyle(.plain)
        .sheet(isPresented: $editingLabels) {
            ClipLabelEditor(labels: clip.labels) { labels in
                model.editClip(clip.id, in: night.id) { $0.sounds = labels }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: isPlaying) { wasPlaying, playing in
            if wasPlaying && !playing { startFraction = 0 }
        }
    }

    private var waveformPanel: some View {
        Group {
            if let peaks {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { _ in
                    let progress = model.playbackFraction(for: clip.id) ?? startFraction
                    VStack(spacing: 6) {
                        GeometryReader { geometry in
                            Canvas { context, size in
                                let step = size.width / CGFloat(peaks.count)
                                for (index, peak) in peaks.enumerated() {
                                    let x = (CGFloat(index) + 0.5) * step
                                    let height = max(2, CGFloat(peak) * (size.height - 4))
                                    let bar = CGRect(x: x - step * 0.3, y: (size.height - height) / 2,
                                                     width: step * 0.6, height: height)
                                    let color = x <= progress * size.width ? playbackColor : accent.opacity(0.45)
                                    context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(color))
                                }
                                let x = progress * size.width
                                let playhead = CGRect(x: min(x, max(0, size.width - 2)), y: 0,
                                                      width: 2, height: size.height)
                                context.fill(Path(playhead), with: .color(playbackColor))
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                if geometry.size.width > 0 {
                                    seek(to: value.location.x / geometry.size.width)
                                }
                            })
                        }
                        .frame(height: 44)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(durationText(progress * clip.duration)) of \(durationText(clip.duration))")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: seek(to: progress + 0.1)
                            case .decrement: seek(to: progress - 0.1)
                            @unknown default: break
                            }
                        }

                        HStack {
                            Text(durationText(progress * clip.duration))
                            Spacer()
                            Text(durationText(clip.duration))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(muted)
                        .accessibilityHidden(true)
                    }
                }
            } else if waveformFailed {
                Text("Waveform unavailable").font(.footnote).foregroundStyle(muted)
            } else {
                ProgressView("Loading waveform").font(.footnote)
            }
        }
    }

    private func seek(to fraction: Double) {
        let position = min(1, max(0, fraction))
        if isPlaying {
            model.seekPlayback(clip.id, to: position)
        } else {
            startFraction = position
        }
    }
}

private struct ClipLabelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<NightSound>
    let save: ([NightSound]) -> Bool

    init(labels: [NightSound], save: @escaping ([NightSound]) -> Bool) {
        _selected = State(initialValue: Set(labels))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(NightSound.allCases, id: \.self) { sound in
                        Toggle(sound.title, isOn: Binding(
                            get: { selected.contains(sound) },
                            set: { enabled in
                                if enabled { selected.insert(sound) }
                                else { selected.remove(sound) }
                            }
                        ))
                        .tint(accent)
                    }
                } footer: {
                    if selected.isEmpty {
                        Text("Select at least one label.")
                    }
                }
            }
            .navigationTitle("Edit labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if save(NightSound.allCases.filter { selected.contains($0) }) { dismiss() }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

private enum ClipWaveform {
    nonisolated static func read(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = file.length
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Keep the peak amplitude for each slice of the clip, across all channels.
        let count = Int(min(72, frameCount))
        var peaks = Array(repeating: Float.zero, count: count)
        var offset: AVAudioFramePosition = 0
        while offset < frameCount {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let index = min(count - 1, Int((offset + AVAudioFramePosition(frame)) * Int64(count) / frameCount))
                for channel in 0..<Int(buffer.format.channelCount) {
                    peaks[index] = max(peaks[index], abs(channels[channel][frame]))
                }
            }
            offset += AVAudioFramePosition(buffer.frameLength)
        }
        guard offset > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let maximum = max(0.001, peaks.max() ?? 0)
        return peaks.map { $0 / maximum }
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
    if total >= 60 { return "\(total / 60)m \(total % 60)s" }
    return "\(total)s"
}
