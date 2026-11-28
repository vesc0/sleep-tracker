import AlarmKit
import SwiftUI

struct TrackView: View {
    @EnvironmentObject private var model: SessionModel
    @State private var confirmEnd = false
    @State private var alarm: Date?
    @State private var draft: Date?
    @State private var savingAlarm = false
    private var schedule = SleepSchedule()
    let finished: (Night) -> Void

    private var listening: Bool { model.startedAt != nil && model.pausedReason == nil }
    private var busy: Bool { model.isBusy || model.managingAudio || model.analyzingID != nil }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let diameter = width.isFinite ? min(max(0, width - 40), 344) : 0
            ScrollView {
                VStack(spacing: 28) {
                    ZStack {
                        ClockFace(listening: listening, alarmMinutes: (draft ?? alarm).map(clockMinutes),
                                  goalMinutes: schedule.enabled ? schedule.wakeMinutes : nil)

                        if let draft {
                            VStack(spacing: 6) {
                                Text(draft.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: diameter * 0.13, weight: .medium))
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.65)
                                Text("Wake-up alarm").font(.subheadline).foregroundStyle(muted)
                            }
                            .lineLimit(1)
                            .frame(width: diameter * 0.55)
                        } else {
                            recordingButton(diameter: diameter)
                        }

                        if #available(iOS 26, *),
                           let handleTime = draft ?? alarm ?? (schedule.enabled ? defaultAlarmTime : nil) {
                            AlarmHandle(time: handleTime, diameter: diameter) { draft = $0 }
                                .allowsHitTesting(!savingAlarm)
                        }
                    }
                    .frame(width: diameter, height: diameter)
                    .coordinateSpace(name: "alarmDial")

                    if let reason = model.pausedReason {
                        VStack {
                            Text(reason).font(.footnote).foregroundStyle(muted)
                            Button("Resume listening") { model.resumeRecording() }
                                .disabled(busy)
                        }
                        .multilineTextAlignment(.center)
                    }

                    if #available(iOS 26, *) {
                        WakeAlarmControl(alarm: $alarm, draft: $draft, saving: $savingAlarm, defaultTime: defaultAlarmTime)
                    }
                }
                .padding(.top, max(24, (geometry.size.height - diameter - 120) / 2))
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(nightBackground.ignoresSafeArea())
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var defaultAlarmTime: Date {
        Calendar.current.clockTime(minutes: schedule.wakeMinutes) ?? .now
    }

    private func recordingButton(diameter: CGFloat) -> some View {
        Button {
            if model.startedAt != nil {
                confirmEnd = true
            } else {
                Task { await model.start() }
            }
        } label: {
            VStack(spacing: 8) {
                MoonLogo()
                    .fill(accent)
                    .frame(width: diameter * (listening ? 0.19 : 0.24),
                           height: diameter * (listening ? 0.19 : 0.24))
                if model.isBusy {
                    ProgressView()
                } else if let start = model.startedAt {
                    Text(listening ? "Listening" : "Paused")
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(accent)
                    if listening {
                        Text("Tap to stop").font(.footnote).foregroundStyle(muted)
                    }
                } else {
                    Text(model.analyzingID != nil ? "Analyzing…" : "Tap to start")
                        .foregroundStyle(muted)
                }
            }
            .frame(width: diameter * 0.57, height: diameter * 0.57)
            .multilineTextAlignment(.center)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(model.startedAt == nil ? "Start listening" : "End session")
        .accessibilityValue(model.startedAt == nil ? "" : (listening ? "Listening" : "Recording paused"))
        .confirmationDialog("End this sleep session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) {
                Task { if let night = await model.finish() { finished(night) } }
            }
            Button("Keep session", role: .cancel) {}
        }
    }
}

// Crescent and four-point star from the app icon, scaled to the dial.
private struct MoonLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.33, y: 0.07))
        path.addQuadCurve(to: CGPoint(x: 0.95, y: 0.79), control: CGPoint(x: 0.06, y: 0.92))
        path.addCurve(to: CGPoint(x: 0.33, y: 0.07), control1: CGPoint(x: 0.45, y: 1.39), control2: CGPoint(x: -0.44, y: 0.58))
        path.move(to: CGPoint(x: 0.85, y: 0))
        path.addQuadCurve(to: CGPoint(x: 1, y: 0.15), control: CGPoint(x: 0.86, y: 0.14))
        path.addQuadCurve(to: CGPoint(x: 0.85, y: 0.30), control: CGPoint(x: 0.86, y: 0.16))
        path.addQuadCurve(to: CGPoint(x: 0.70, y: 0.15), control: CGPoint(x: 0.84, y: 0.16))
        path.addQuadCurve(to: CGPoint(x: 0.85, y: 0), control: CGPoint(x: 0.84, y: 0.14))
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
    }
}

private func clockMinutes(_ date: Date) -> Int {
    let calendar = Calendar.current
    return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
}

private func bandInset(_ diameter: CGFloat) -> CGFloat { diameter * 0.103 }

private struct ClockFace: View {
    var listening: Bool
    var alarmMinutes: Int?
    var goalMinutes: Int?

    var body: some View {
        GeometryReader { geometry in
            let diameter = geometry.size.width
            ZStack {
                Circle().fill(RadialGradient(colors: [accent.opacity(0.12), nightBackground],
                                             center: .center, startRadius: 0, endRadius: diameter / 2))
                Circle().strokeBorder(accent.opacity(listening ? 0.9 : 0.38), lineWidth: 1.2)
                    .shadow(color: listening ? accent : .clear, radius: 5)
                ForEach([0.46, 0.61], id: \.self) { scale in
                    Circle().stroke(accent.opacity(0.10)).scaleEffect(scale)
                }
                ForEach(0..<60, id: \.self) { tick in
                    let major = tick.isMultiple(of: 5)
                    let length: CGFloat = major ? 7 : 4
                    Capsule().fill(accent.opacity(major ? 0.9 : 0.5))
                        .frame(width: major ? 1.5 : 1, height: length)
                        .offset(y: -diameter / 2 + 3 + length / 2)
                        .rotationEffect(.degrees(Double(tick) * 6))
                }
                ForEach([12, 3, 6, 9], id: \.self) { hour in
                    let angle = Double(hour) * .pi / 6
                    Text(String(hour)).font(.system(size: diameter * 0.055))
                        .offset(x: sin(angle) * diameter * 0.443, y: -cos(angle) * diameter * 0.443)
                }
                if let target = alarmMinutes ?? goalMinutes {
                    TimelineView(.everyMinute) { tick in
                        let start = clockMinutes(tick.date)
                        let remaining = (target - start + 1440) % 1440
                        let inset = bandInset(diameter)
                        let width = diameter * 0.038
                        ZStack {
                            Circle().inset(by: inset)
                                .stroke(accent.opacity(remaining >= 720 ? 0.55 : 0.17), lineWidth: width)
                            Circle().inset(by: inset)
                                .trim(from: 0, to: CGFloat(remaining % 720) / 720)
                                .stroke(accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                                .rotationEffect(.degrees(Double(start) / 2 - 90))
                            Capsule().fill(.white).frame(width: 2, height: width * 0.7)
                                .offset(y: -diameter / 2 + inset)
                                .rotationEffect(.degrees(Double(start) / 2))
                        }
                    }
                }
                if let goalMinutes {
                    Circle().fill(nightBackground)
                        .overlay(Circle().strokeBorder(Color.mint, lineWidth: 2))
                        .frame(width: 24, height: 24)
                        .offset(y: -diameter / 2 + bandInset(diameter))
                        .rotationEffect(.degrees(Double(goalMinutes) / 2))
                }
                if let alarmMinutes {
                    Circle().fill(accent).frame(width: 18, height: 18)
                        .offset(y: -diameter / 2 + bandInset(diameter))
                        .rotationEffect(.degrees(Double(alarmMinutes) / 2))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AlarmHandle: View {
    let time: Date
    let diameter: CGFloat
    let change: (Date) -> Void

    var body: some View {
        let angle = Double(clockMinutes(time)) * .pi / 360
        let radius = diameter / 2 - bandInset(diameter)
        Circle().fill(.clear)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("alarmDial"))
                .onChanged { moveHandle(to: $0.location, diameter: diameter) })
            .offset(x: radius * sin(angle), y: -radius * cos(angle))
            .accessibilityHidden(true)
    }

    private func moveHandle(to point: CGPoint, diameter: CGFloat) {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        guard hypot(dx, dy) > diameter / 4 else { return }
        let turns = atan2(dx, -dy) / (2 * .pi)
        let snapped = (Int((turns * 144).rounded()) * 5 + 720) % 720
        let current = clockMinutes(time)
        // Follow the shortest movement around the face, including across noon or midnight.
        let delta = (snapped - current % 720 + 1080) % 720 - 360
        if delta != 0, let time = Calendar.current.clockTime(minutes: (current + delta + 1440) % 1440) {
            change(time)
        }
    }
}

@available(iOS 26, *)
private struct WakeAlarmMetadata: AlarmMetadata {}

@available(iOS 26, *)
private struct WakeAlarmControl: View {
    private static let id = UUID(uuidString: "A52DA52E-F065-461F-B916-AE5782354FA7")!
    @Binding var alarm: Date?
    @Binding var draft: Date?
    @Binding var saving: Bool
    let defaultTime: Date
    @Environment(\.scenePhase) private var phase
    @State private var error: String?
    @State private var exactTime = false

    var body: some View {
        VStack(spacing: 12) {
            if let selection = Binding($draft) {
                Button("Set exact time") { exactTime = true }
                    .frame(minHeight: 44)
                    .sheet(isPresented: $exactTime) {
                        VStack {
                            DatePicker("Wake-up time", selection: selection, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                            Button("Done") { exactTime = false }.buttonStyle(.borderedProminent)
                        }
                        .presentationDetents([.height(325)])
                    }
                HStack(spacing: 12) {
                    Button("Cancel") { draft = nil }.buttonStyle(.bordered)
                    Button("Save") { apply(remove: false) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                if alarm != nil {
                    Button("Remove alarm", role: .destructive) { apply(remove: true) }
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
                if let error {
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                }
            } else {
                Button { draft = alarm ?? defaultTime } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm")
                        if let alarm {
                            Text("Alarm · \(alarm.formatted(date: .omitted, time: .shortened))")
                        } else {
                            Text("Set alarm")
                        }
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .disabled(saving)
        .onChange(of: draft) { _, _ in error = nil }
        .task(id: phase) {
            guard phase == .active else { return }
            let manager = AlarmManager.shared
            if let alarms = try? manager.alarms { update(alarms) }
            for await alarms in manager.alarmUpdates { update(alarms) }
        }
    }

    private func update(_ alarms: [Alarm]) {
        if case let .fixed(date) = alarms.first(where: { $0.id == Self.id })?.schedule {
            alarm = date
        } else {
            alarm = nil
        }
    }

    private func apply(remove: Bool) {
        guard !saving, let selectedTime = draft else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            let manager = AlarmManager.shared
            do {
                if remove {
                    try manager.cancel(id: Self.id)
                    alarm = nil
                } else {
                    guard try await manager.requestAuthorization() == .authorized else {
                        error = "Allow alarms for Sleep tracker in iPhone Settings to set a wake-up alarm."
                        return
                    }
                    var time = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
                    time.second = 0
                    guard let next = Calendar.current.nextDate(after: .now, matching: time, matchingPolicy: .nextTime) else {
                        error = "Choose another wake-up time."
                        return
                    }
                    let alert: AlarmPresentation.Alert
                    if #available(iOS 26.1, *) {
                        alert = .init(title: "Wake up")
                    } else {
                        alert = .init(title: "Wake up", stopButton: .init(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
                    }
                    let attributes = AlarmAttributes<WakeAlarmMetadata>(presentation: .init(alert: alert), tintColor: accent)
                    _ = try await manager.schedule(id: Self.id, configuration: .alarm(schedule: .fixed(next), attributes: attributes))
                    alarm = next
                }
                draft = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
