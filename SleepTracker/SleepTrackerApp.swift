// App entry point and SwiftUI screens for recording and reviewing sessions.
// The app shares one SessionModel across the Tonight and History tabs.

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

private let nightBackground = Color(red: 0.05, green: 0.06, blue: 0.10)
private let surface = Color(red: 0.09, green: 0.11, blue: 0.17)
private let accent = Color(red: 0.77, green: 0.80, blue: 1.0)
private let muted = Color(red: 0.66, green: 0.70, blue: 0.80)

struct SleepTrackerView: View {
    @EnvironmentObject private var model: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var tab = 0
    @State private var selectedNight: Night?

    var body: some View {
        TabView(selection: $tab) {
            tonight
                .tabItem { Label("Tonight", systemImage: "moon.stars") }
                .tag(0)
            history
                .tabItem { Label("History", systemImage: "clock") }
                .tag(1)
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
        .onChange(of: scenePhase) { _, phase in
            // Recording can continue while locked. Analysis needs the app open.
            if phase != .active { model.pauseAnalysis() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            Task { await model.handleInterruption(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { note in
            Task { await model.handleEngineChange(note) }
        }
    }

    private var tonight: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform").foregroundStyle(accent)
                    Text("Sleep tracker").font(.headline.weight(.semibold))
                }

                VStack(spacing: 16) {
                    MoonDial(listening: model.startedAt != nil)
                        .frame(height: 230)
                        .accessibilityHidden(true)

                    if let startedAt = model.startedAt {
                        Text("Listening").font(.largeTitle.weight(.semibold))
                        Text(startedAt, style: .timer)
                            .font(.title2.monospacedDigit())
                            .foregroundStyle(accent)
                            .accessibilityLabel("Elapsed recording time")
                        Text("You can lock your iPhone while listening.")
                            .foregroundStyle(muted)
                    } else {
                        Text("Ready for bed?")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        Text("Set your iPhone on your bedside table. Sleep tracker checks for nighttime sounds when you end the session.")
                            .foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task {
                            if model.startedAt != nil {
                                if let night = await model.finish() {
                                    tab = 1
                                    selectedNight = night
                                    if scenePhase == .active { model.analyze(night.id) }
                                }
                            } else {
                                await model.start()
                            }
                        }
                    } label: {
                        Label(model.startedAt == nil ? "Start listening" : "End session",
                              systemImage: model.startedAt == nil ? "mic" : "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(accent, in: RoundedRectangle(cornerRadius: 19))
                            .foregroundStyle(nightBackground)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy || model.analyzingID != nil)
                    .opacity(model.isBusy || model.analyzingID != nil ? 0.55 : 1)
                    .padding(.top, 10)

                    if model.isBusy {
                        ProgressView().tint(accent)
                    } else if model.startedAt == nil {
                        Label("Audio stays on this iPhone", systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(muted)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                if let latest = model.nights.first, model.startedAt == nil {
                    Button { selectedNight = latest } label: {
                        NightRow(night: latest, title: "Last session")
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(nightBackground.ignoresSafeArea())
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("History").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if model.nights.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet", systemImage: "moon.zzz",
                        description: Text("Your sessions and saved clips will appear here.")
                    )
                    .padding(.vertical, 64)
                } else {
                    ForEach(model.nights) { night in
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
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct MoonDial: View {
    let listening: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.22), nightBackground.opacity(0)],
                                     center: .center, startRadius: 12, endRadius: 130))
                .frame(width: 260, height: 260)
            ForEach([112.0, 150, 188, 226], id: \.self) { diameter in
                Circle()
                    .strokeBorder(accent.opacity(diameter == 112 ? 0.38 : 0.16), lineWidth: 1)
                    .frame(width: diameter, height: diameter)
            }
            Circle()
                .fill(surface)
                .frame(width: 88, height: 88)
            Image(systemName: listening ? "waveform" : "moon.stars.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(accent)
            Circle().fill(accent).frame(width: 5, height: 5).offset(x: 78, y: -52)
            Circle().fill(accent.opacity(0.65)).frame(width: 4, height: 4).offset(x: -97, y: 57)
        }
    }
}

private struct NightRow: View {
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
                Text("\(durationText(night.duration)) · \(night.clips.count) \(night.clips.count == 1 ? "clip" : "clips")")
                    .font(.subheadline)
                    .foregroundStyle(muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(muted)
        }
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 19))
        .contentShape(Rectangle())
    }
}

private struct NightDetail: View {
    let originalNight: Night
    @EnvironmentObject private var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var night: Night {
        model.nights.first(where: { $0.id == originalNight.id }) ?? originalNight
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(night.startedAt.formatted(date: .complete, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(muted)

                    HStack(alignment: .top, spacing: 10) {
                        metric(durationText(night.duration), label: "Time monitored")
                        metric(String(night.clips.count), label: "Saved clips")
                    }
                    if night.wasInterrupted {
                        Label("Listening ended early. This session may be incomplete.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(muted)
                            .font(.subheadline)
                    }

                    if model.analyzingID == night.id {
                        ProgressView("Analyzing recording… Keep Sleep tracker open.")
                            .tint(accent)
                    } else if night.needsAnalysis {
                        Button("Analyze remaining audio") { model.analyze(night.id) }
                            .buttonStyle(.bordered)
                            .disabled(model.startedAt != nil || model.isBusy || model.analyzingID != nil)
                    }

                    if let problem = model.analysisProblems[night.id] {
                        Text(problem).font(.footnote).foregroundStyle(muted)
                    }

                    if night.duration > 0 {
                        timeline
                    }

                    Text("Detected sounds").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    if night.clips.isEmpty, !night.needsAnalysis {
                        Text("No nighttime sounds were flagged.")
                            .foregroundStyle(muted)
                    }
                    ForEach(night.clips) { clip in
                        Button {
                            model.play(clip, in: night)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: model.playingID == clip.id ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(clip.soundTitle).font(.headline)
                                    Text(clip.startedAt, style: .time)
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(muted)
                                }
                                Spacer()
                                Text(durationText(clip.duration))
                                    .font(.subheadline)
                                    .foregroundStyle(muted)
                            }
                            .padding(12)
                            .background(surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.playingID == clip.id ? "Stop clip" : "Play \(clip.soundTitle) at \(clip.startedAt.formatted(date: .omitted, time: .shortened))")
                        .disabled(model.startedAt != nil || model.isBusy)
                    }
                    if model.startedAt != nil, !night.clips.isEmpty {
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
            .confirmationDialog("Delete this session and its clips?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete session", role: .destructive) {
                    model.delete(night)
                    if !model.nights.contains(where: { $0.id == night.id }) { dismiss() }
                }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                let track = CGRect(x: 0, y: size.height / 2 - 2, width: size.width, height: 4)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(accent.opacity(0.20)))
                for clip in night.clips {
                    let position = clip.startedAt.timeIntervalSince(night.startedAt) / night.duration
                    // Keep short clips visible on a full-night timeline.
                    let width = max(2, clip.duration / night.duration * size.width)
                    let mark = CGRect(x: min(size.width - width, position * size.width),
                                      y: 0, width: width, height: size.height)
                    context.fill(Path(roundedRect: mark, cornerRadius: 1), with: .color(accent))
                }
            }
            .frame(height: 17)
            HStack {
                Text(night.startedAt, style: .time)
                Spacer()
                Text(night.endedAt, style: .time)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(muted)
        }
        .accessibilityHidden(true)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.subheadline).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private func durationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
    if total >= 60 { return "\(total / 60)m \(total % 60)s" }
    return "\(total)s"
}
