// Preferences for future recordings and tools for managing saved nights.
import SwiftUI
import UserNotifications

struct SleepSchedule: DynamicProperty {
    @AppStorage("bedtimeGoalEnabled") var enabled = false
    @AppStorage("bedtimeGoalMinutes") var bedtimeMinutes = 23 * 60
    @AppStorage("customWakeGoalMinutes") private var customWakeGoalMinutes = -1

    private var suggestedWakeMinutes: Int { (bedtimeMinutes + 8 * 60) % 1440 }
    var wakeMinutes: Int { customWakeGoalMinutes < 0 ? suggestedWakeMinutes : customWakeGoalMinutes }

    func setBedtime(minutes: Int) {
        if minutes != bedtimeMinutes {
            bedtimeMinutes = minutes
            customWakeGoalMinutes = -1
        }
    }

    func setWakeTime(minutes: Int) { customWakeGoalMinutes = minutes }
}

extension Calendar {
    func clockTime(minutes: Int) -> Date? {
        // A fixed winter date keeps clock labels independent of today's DST transition.
        guard let reference = self.date(from: DateComponents(year: 2026, month: 1, day: 15)) else { return nil }
        return self.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: reference)
    }
}

private struct ReminderSchedule: Equatable {
    let enabled: Bool
    let minutes: Int
    let days: Int

    @MainActor
    func apply() async throws {
        let center = UNUserNotificationCenter.current()
        let identifiers = (1...7).map { "bedtime.\($0)" }
        try Task.checkCancellation()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard enabled else { return }
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw ReminderError.denied
        }
        let content = UNMutableNotificationContent()
        content.title = "Bedtime reminder"
        content.body = "Ready for bed? Open Sleep tracker to start listening."
        content.sound = .default
        for day in 1...7 where days & (1 << (day - 1)) != 0 {
            try Task.checkCancellation()
            let date = DateComponents(hour: minutes / 60, minute: minutes % 60, weekday: day)
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            try await center.add(.init(identifier: identifiers[day - 1], content: content, trigger: trigger))
        }
    }

    enum ReminderError: LocalizedError {
        case denied
        var errorDescription: String? { "Allow notifications for Sleep tracker in iPhone Settings to receive reminders." }
    }
}

private struct SoundPreference: View {
    let sound: NightSound
    @AppStorage private var enabled: Bool

    init(_ sound: NightSound) {
        self.sound = sound
        _enabled = AppStorage(wrappedValue: true, "detect." + sound.rawValue)
    }

    var body: some View { Toggle(sound.title, isOn: $enabled) }
}

struct SettingsView: View {
    private var sleepSchedule = SleepSchedule()
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @EnvironmentObject private var model: SessionModel
    @AppStorage("bedtimeReminder") private var reminder = false
    @AppStorage("reminderMinutes") private var minutes = 22 * 60 + 30
    @AppStorage("reminderDays") private var days = 127
    @AppStorage("autoResume") private var resume = true
    @AppStorage("keepFullAudio") private var full = false
    @AppStorage("recordingQuality") private var quality = RecordingQuality.preferred()
    @AppStorage("retentionDays") private var retention = 0
    @State private var reminderTask: Task<Void, Never>?
    @State private var clearDays = 7
    @State private var confirmClear = false
    @State private var exportID: UUID?
    @State private var includeAudio = false
    @State private var shared: ExportFile?

    private var schedule: ReminderSchedule { .init(enabled: reminder, minutes: minutes, days: days) }
    private var filesBusy: Bool { model.startedAt != nil || model.isBusy || model.analyzingID != nil || model.managingAudio }

    var body: some View {
        NavigationStack {
            Form {
                sleepScheduleSection
                reminderSection
                Section("Sounds to detect") {
                    ForEach(NightSound.allCases, id: \.self) { SoundPreference($0) }
                }.listRowBackground(surface)
                Section {
                    Toggle("Resume after interruptions", isOn: $resume)
                    Picker("Audio quality", selection: $quality) {
                        ForEach(RecordingQuality.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Keep full recording", isOn: $full)
                } header: { Text("Recording") } footer: {
                    Text(full ? "New sessions keep the full recording and detected clips. Full audio uses about \(quality.megabytesPerHour) MB per recorded hour, plus clip storage." : "New sessions keep only detected clips after analysis.")
                }.listRowBackground(surface)
                storageSection
                exportSection
                Section {
                    NavigationLink("How Sleep tracker works") {
                        List {
                            explanation("Sleep duration", "Duration estimates sleep from recorded time. Paused time is excluded. The microphone cannot tell exactly when you fell asleep.")
                            explanation("Sound episodes", "The app checks short recordings for snoring, speech, and coughing. Nearby detections of the same sound form one episode. You can correct labels in History.")
                            explanation("Recording levels", "dBFS measures the microphone signal. Values closer to zero are louder. Quiet and typical describe the quieter and middle levels of the night. Average uses signal power, and peak is the loudest sample. Phone placement affects every reading.")
                        }.navigationTitle("How it works").scrollContentBackground(.hidden).background(nightBackground)
                    }
                    NavigationLink("About") {
                        List {
                            LabeledContent("Version", value: bundleValue("CFBundleShortVersionString"))
                            LabeledContent("Build", value: bundleValue("CFBundleVersion"))
                            explanation("Release notes", "Added bedtime reminders, recording preferences, interruption recovery, audio retention, and session exports.")
                            Link("Send feedback on GitHub", destination: URL(string: "https://github.com/vesc0/sleep-tracker/issues")!)
                        }.listRowBackground(surface).navigationTitle("About").scrollContentBackground(.hidden).background(nightBackground)
                    }
                }.listRowBackground(surface)
            }
            .scrollContentBackground(.hidden)
            .background(nightBackground)
            .navigationTitle("Settings")
            .tint(accent)
            .task { await model.maintainAudio() }
            .onChange(of: retention) { _, _ in Task { await model.maintainAudio() } }
            .onChange(of: schedule) { _, next in
                let previous = reminderTask
                previous?.cancel()
                reminderTask = Task {
                    // Serialize edits so a slow notification request can't restore an old schedule.
                    await previous?.value
                    do { try await next.apply() }
                    catch where !Task.isCancelled {
                        reminder = false
                        model.problem = error.localizedDescription
                    } catch {}
                }
            }
            .sheet(item: $shared) { file in
                ExportPicker(file: file)
            }
        }
    }

    private var localCalendar: Calendar {
        var local = calendar
        local.timeZone = timeZone
        return local
    }

    private var sleepScheduleSection: some View {
        Section("Sleep Schedule") {
            Toggle("Bedtime goal", isOn: sleepSchedule.$enabled)
            if sleepSchedule.enabled {
                HStack(spacing: 6) {
                    goalPicker("Bedtime", selection: bedtimeGoal)
                    Spacer(minLength: 0)
                    goalPicker("Wake up", selection: wakeGoal)
                }
            }
        }.listRowBackground(surface)
    }

    private func goalPicker(_ title: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(muted).lineLimit(1)
            DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
        }
    }

    private var bedtimeGoal: Binding<Date> {
        Binding(
            get: { localCalendar.clockTime(minutes: sleepSchedule.bedtimeMinutes) ?? .now },
            set: {
                let parts = localCalendar.dateComponents([.hour, .minute], from: $0)
                let minutes = (parts.hour ?? 23) * 60 + (parts.minute ?? 0)
                sleepSchedule.setBedtime(minutes: minutes)
            }
        )
    }

    private var wakeGoal: Binding<Date> {
        Binding(
            get: { localCalendar.clockTime(minutes: sleepSchedule.wakeMinutes) ?? .now },
            set: {
                let parts = localCalendar.dateComponents([.hour, .minute], from: $0)
                sleepSchedule.setWakeTime(minutes: (parts.hour ?? 7) * 60 + (parts.minute ?? 0))
            }
        )
    }

    private var reminderSection: some View {
        Section("Bedtime reminder") {
            Toggle("Remind me", isOn: $reminder)
            if reminder {
                DatePicker("Time", selection: Binding(get: {
                    Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
                }, set: {
                    minutes = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0)
                }), displayedComponents: .hourAndMinute)
                HStack(spacing: 0) {
                    ForEach(0..<7) { index in
                        let day = (Calendar.current.firstWeekday - 1 + index) % 7
                        let bit = 1 << day
                        let selected = days & bit != 0
                        Button {
                            if days != bit { days ^= bit }
                        } label: {
                            Text(Calendar.current.veryShortStandaloneWeekdaySymbols[day])
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .foregroundStyle(selected ? nightBackground : muted)
                                .background(selected ? accent : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }.listRowBackground(surface)
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Recording storage", value: ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))
            Picker("Keep audio", selection: $retention) {
                Text("Until deleted").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            Picker("Clear recordings", selection: $clearDays) {
                Text("Older than 7 days").tag(7)
                Text("Older than 30 days").tag(30)
                Text("All ages").tag(0)
            }
            Button("Clear audio…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Clear \(clearDays == 0 ? "all analyzed audio" : "audio older than \(clearDays) days")?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear audio", role: .destructive) { Task { await model.maintainAudio(clearOlderThan: clearDays) } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("This permanently removes audio files. Session details and Trends stay available.") }
        } header: { Text("Storage") } footer: {
            Text("Retention applies to existing recordings when the app is open. Audio awaiting analysis is kept until analysis finishes.")
        }.listRowBackground(surface).disabled(filesBusy)
    }

    private var exportSection: some View {
        Section("Export data") {
            Picker("Sessions", selection: $exportID) {
                Text("All sessions").tag(nil as UUID?)
                ForEach(model.nights) { night in
                    Text(night.startedAt.formatted(date: .abbreviated, time: .standard)).tag(Optional(night.id))
                }
            }
            Toggle("Include available audio", isOn: $includeAudio)
            Button("Export to Files…", systemImage: "square.and.arrow.up") {
                Task {
                    do { shared = ExportFile(url: try await model.export(id: exportID, audio: includeAudio)) }
                    catch { model.problem = error.localizedDescription }
                }
            }
        }.listRowBackground(surface).disabled(filesBusy || model.nights.isEmpty)
    }

    private func explanation(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(muted)
        }.listRowBackground(surface)
    }

    private func bundleValue(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—" }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ExportPicker: UIViewControllerRepresentable {
    let file: ExportFile
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> URL { file.url.deletingLastPathComponent() }
    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: URL) {
        try? FileManager.default.removeItem(at: coordinator)
    }
}
