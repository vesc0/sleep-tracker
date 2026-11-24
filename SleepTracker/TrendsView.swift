// Summarizes saved sessions by night and displays duration and sound trends.

import Charts
import SwiftUI

struct TrendNight: Identifiable {
    let date: Date
    let sessions: [Night]

    var id: Date { date }
    var duration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }

    private var analyzedSessions: [Night] { sessions.filter { !$0.needsAnalysis } }

    func episodeCount(for sound: NightSound?) -> Int? {
        let analyzed = analyzedSessions
        guard !analyzed.isEmpty else { return nil }
        return analyzed.flatMap(\.episodes).count { sound == nil || $0.sound == sound }
    }

    var soundRate: Double? {
        let hours = analyzedSessions.reduce(0) { $0 + $1.duration } / 3_600
        guard hours > 0, let count = episodeCount(for: nil) else { return nil }
        return Double(count) / hours
    }

    var restedRating: Double? {
        let ratings = sessions.compactMap { $0.checkIn?.restedRating }
        guard !ratings.isEmpty else { return nil }
        return Double(ratings.reduce(0, +)) / Double(ratings.count)
    }

    var tags: Set<NightTag> {
        Set(sessions.flatMap { $0.checkIn?.tags ?? [] })
    }

    static func recent(
        _ sessions: [Night], days: Int, now: Date, calendar: Calendar
    ) -> [TrendNight] {
        // Group sessions before noon with the previous evening.
        func nightDate(for date: Date) -> Date {
            let day = calendar.startOfDay(for: date)
            guard calendar.component(.hour, from: date) < 12 else { return day }
            return calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }

        let latest = nightDate(for: now)
        let grouped = Dictionary(grouping: sessions.filter { $0.duration > 0 }) {
            nightDate(for: $0.startedAt)
        }
        return ((1 - days)...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: latest).map { date in
                TrendNight(date: date, sessions: grouped[date] ?? [])
            }
        }
    }
}

struct TrendsView: View {
    let sessions: [Night]
    let openSession: (Night) -> Void

    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var days = 7
    @State private var sound: NightSound?
    private enum SelectedChart { case duration, sounds }
    @State private var selection: (chart: SelectedChart, day: Int)?
    @State private var comparisonTag = NightTag.lateCaffeine
    @AppStorage("bedtimeGoalEnabled") private var bedtimeGoalEnabled = false
    @AppStorage("bedtimeGoalMinutes") private var bedtimeGoalMinutes = 23 * 60
    @AppStorage("customWakeGoalMinutes") private var customWakeGoalMinutes = -1

    private var suggestedWakeMinutes: Int { (bedtimeGoalMinutes + 8 * 60) % 1440 }
    private var wakeGoalMinutes: Int { customWakeGoalMinutes < 0 ? suggestedWakeMinutes : customWakeGoalMinutes }

    private var localCalendar: Calendar {
        var local = calendar
        local.timeZone = timeZone
        return local
    }

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                let nights = TrendNight.recent(sessions, days: days, now: context.date, calendar: localCalendar)
                let tracked = nights.filter { !$0.sessions.isEmpty }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("Date range", selection: $days) {
                            Text("7 Days").tag(7)
                            Text("30 Days").tag(30)
                        }
                        .pickerStyle(.segmented)

                        if tracked.isEmpty {
                            ContentUnavailableView(
                                "No tracked nights", systemImage: "chart.bar",
                                description: Text("Record a session to see trends here.")
                            )
                        } else {
                            durationCard(nights, tracked: tracked)
                            soundsCard(nights)
                            restedCard(nights)
                        }
                        timingCard(nights)
                        if !tracked.isEmpty { comparisonCard(tracked) }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onChange(of: nights.first?.date) { _, _ in selection = nil }
            }
            .background(nightBackground.ignoresSafeArea())
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
        }
        .onChange(of: days) { _, _ in selection = nil }
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private func durationCard(_ nights: [TrendNight], tracked: [TrendNight]) -> some View {
        let average = tracked.reduce(0) { $0 + $1.duration } / Double(tracked.count)

        return trendCard("Sleep duration", help: "Duration uses the recorded session length. The dashed line shows the average across tracked nights. Under 6 hours is red, 6 to under 7 is yellow, and 7 or more is green.") {
            SleepDurationValue(seconds: average).font(.title)
            Text("Average from recorded sessions · \(tracked.count) of \(days) nights")
                .font(.subheadline).foregroundStyle(muted)

            Chart {
                ForEach(nights.indices, id: \.self) { index in
                    if nights[index].duration > 0 {
                        nightBar(at: index, value: nights[index].duration / 3_600, axis: "Sleep duration in hours")
                            .foregroundStyle(SleepDurationValue.color(for: nights[index].duration)
                                .opacity(selection?.chart != .duration || selection?.day == index ? 1 : 0.45))
                            .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue(durationText(nights[index].duration))
                    }
                }
                RuleMark(y: .value("Average hours", average / 3_600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(muted)
                    .accessibilityHidden(true)
            }
            .chartYScale(domain: 0...max(1, (tracked.map(\.duration).max() ?? 0) / 3_600 * 1.1))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let hours = value.as(Double.self) {
                        AxisValueLabel { Text("\(hours, format: .number)h") }
                    }
                }
            }
            .modifier(NightChartAxis(nights: nights) { selection = (.duration, $0) })
            if let selection, selection.chart == .duration, nights.indices.contains(selection.day) {
                sessionLinks(for: nights[selection.day])
            }
        }
    }

    private func soundsCard(_ nights: [TrendNight]) -> some View {
        let counts = nights.map { $0.episodeCount(for: sound) }
        let maximum = max(1, counts.compactMap { $0 }.max() ?? 0)

        return trendCard("Nighttime sounds", help: "Only analyzed sessions count. Dismissed clips are excluded. Each bar counts the detected episodes that night. Green means zero, yellow means one to five, and red means six or more.") {
            Picker("Sound type", selection: $sound) {
                Text("All sounds").tag(nil as NightSound?)
                ForEach(NightSound.allCases, id: \.self) { sound in
                    Text(sound.title).tag(Optional(sound))
                }
            }
            .pickerStyle(.menu)
            .tint(accent)

            if counts.allSatisfy({ $0 == nil }) {
                Text("Analyze a session to see sound trends.")
                    .font(.subheadline).foregroundStyle(muted)
            } else {
                Text("Detected episodes per night")
                    .font(.subheadline).foregroundStyle(muted)
                Chart {
                    ForEach(nights.indices, id: \.self) { index in
                        if let count = counts[index] {
                            let color = SoundCountValue.color(for: count)
                                .opacity(selection?.chart != .sounds || selection?.day == index ? 1 : 0.45)
                            if count > 0 {
                                nightBar(at: index, value: Double(count), axis: "Episodes")
                                    .foregroundStyle(color)
                                    .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue(String(count))
                            } else {
                                PointMark(x: .value("Night", Double(index)), y: .value("Episodes", 0.0))
                                    .foregroundStyle(color)
                                    .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue("0 episodes")
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...Double(maximum) * 1.1)
                .chartYAxis { AxisMarks(values: .stride(by: max(1, ceil(Double(maximum) / 4)))) }
                .modifier(NightChartAxis(nights: nights) { selection = (.sounds, $0) })
                if let selection, selection.chart == .sounds, nights.indices.contains(selection.day) {
                    sessionLinks(for: nights[selection.day])
                }
            }
        }
    }

    private func restedCard(_ nights: [TrendNight]) -> some View {
        let ratings = nights.compactMap(\.restedRating)
        return trendCard("Rested rating", help: "Ratings come from your session’s Sleep rating. Only rated nights count toward the average. Ratings of 1–2 are red, 3 is yellow, and 4–5 are green. Averages are rounded for color.") {
            if ratings.isEmpty {
                Text("Add a sleep rating to chart how rested you feel.")
                    .font(.subheadline).foregroundStyle(muted)
            } else {
                let average = ratings.reduce(0, +) / Double(ratings.count)
                HStack(spacing: 4) {
                    RestedScore(value: average, showDecimal: true)
                    Text("average · \(ratings.count) rated nights").foregroundStyle(muted)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                Chart {
                    ForEach(nights.indices, id: \.self) { index in
                        if let rating = nights[index].restedRating {
                            LineMark(x: .value("Night", Double(index)), y: .value("Rested rating", rating))
                                .foregroundStyle(accent.opacity(0.6))
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(nights.indices, id: \.self) { index in
                        if let rating = nights[index].restedRating {
                            PointMark(x: .value("Night", Double(index)), y: .value("Rested rating", rating))
                                .foregroundStyle(RestedScore.color(for: rating))
                                .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
                .chartYScale(domain: 0.5...5.5)
                .chartYAxis { AxisMarks(values: [1, 2, 3, 4, 5]) }
                .modifier(NightChartAxis(nights: nights))
            }
        }
    }

    private func timingCard(_ nights: [TrendNight]) -> some View {
        let sessions = nights.flatMap(\.sessions)
        let starts = sessions.map { timingHour($0.startedAt, relativeTo: $0.startedAt) }
        let ends = sessions.map { timingHour($0.endedAt, relativeTo: $0.startedAt) }
        let goal = Double(bedtimeGoalMinutes) / 60 + (bedtimeGoalMinutes < 12 * 60 ? 24 : 0)
        let wakeOffset = (wakeGoalMinutes - bedtimeGoalMinutes + 1440) % 1440
        let wakeGoalHour = goal + Double(wakeOffset == 0 ? 1440 : wakeOffset) / 60
        let bounds = starts + ends + (bedtimeGoalEnabled ? [goal, wakeGoalHour] : [])
        let lower = floor((bounds.min() ?? 20) / 2) * 2 - 0.5
        let upper = ceil((bounds.max() ?? 32) / 2) * 2 + 0.5

        return trendCard("Bedtime consistency", help: "Circles show when recording started and diamonds show when it ended. Dashed lines show your goals when enabled. Later times appear higher as the night progresses through midnight. Changing bedtime sets the wake-up goal to eight hours later.") {
            Toggle("Bedtime goal", isOn: $bedtimeGoalEnabled)
                .font(.subheadline)
            if bedtimeGoalEnabled {
                HStack(spacing: 6) {
                    goalPicker("Bedtime", selection: bedtimeGoal)
                    Spacer(minLength: 0)
                    goalPicker("Wake up", selection: wakeGoal)
                }
            }
            if sessions.isEmpty {
                Text("Record a session to see start and end times.")
                    .font(.subheadline).foregroundStyle(muted)
            } else {
                HStack {
                    Label("Session start", systemImage: "circle.fill").foregroundStyle(accent)
                    Label("Session end", systemImage: "diamond.fill").foregroundStyle(.mint)
                }
                .font(.caption)
                Chart {
                    ForEach(nights.indices, id: \.self) { index in
                        ForEach(nights[index].sessions) { session in
                            PointMark(x: .value("Night", Double(index)),
                                      y: .value("Session start", timingHour(session.startedAt, relativeTo: session.startedAt)))
                                .foregroundStyle(accent)
                                .accessibilityValue(session.startedAt.formatted(date: .omitted, time: .shortened))
                            PointMark(x: .value("Night", Double(index)),
                                      y: .value("Session end", timingHour(session.endedAt, relativeTo: session.startedAt)))
                                .symbol(.diamond)
                                .foregroundStyle(Color.mint)
                                .accessibilityValue(session.endedAt.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    if bedtimeGoalEnabled {
                        RuleMark(y: .value("Bedtime goal", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(accent.opacity(0.7))
                        RuleMark(y: .value("Wake-up goal", wakeGoalHour))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Color.mint.opacity(0.7))
                    }
                }
                .chartYScale(domain: lower...upper)
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        if let hour = value.as(Double.self), let time = clockTime(minutes: Int((hour * 60).rounded()) % 1440) {
                            AxisValueLabel { Text(time, format: .dateTime.hour().minute()) }
                        }
                    }
                }
                .modifier(NightChartAxis(nights: nights))
            }
        }
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
            get: { clockTime(minutes: bedtimeGoalMinutes) ?? .now },
            set: {
                let parts = localCalendar.dateComponents([.hour, .minute], from: $0)
                let minutes = (parts.hour ?? 23) * 60 + (parts.minute ?? 0)
                if minutes != bedtimeGoalMinutes {
                    bedtimeGoalMinutes = minutes
                    customWakeGoalMinutes = -1
                }
            }
        )
    }

    private var wakeGoal: Binding<Date> {
        Binding(
            get: { clockTime(minutes: wakeGoalMinutes) ?? .now },
            set: {
                let parts = localCalendar.dateComponents([.hour, .minute], from: $0)
                customWakeGoalMinutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func clockTime(minutes: Int) -> Date? {
        // A fixed winter date keeps clock labels independent of today's DST transition.
        guard let reference = localCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15)) else { return nil }
        return localCalendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: reference)
    }

    private func timingHour(_ time: Date, relativeTo start: Date) -> Double {
        let calendar = localCalendar
        let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                to: calendar.startOfDay(for: time)).day ?? 0
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let shift = calendar.component(.hour, from: start) < 12 ? 24 : 0
        return Double(dayOffset * 24 + shift + (parts.hour ?? 0)) + Double(parts.minute ?? 0) / 60
    }

    private func comparisonCard(_ nights: [TrendNight]) -> some View {
        let checkedIn = nights.filter { $0.sessions.contains { $0.checkIn != nil } }
        let tagged = checkedIn.filter { $0.tags.contains(comparisonTag) }
        let other = checkedIn.filter { !$0.tags.contains(comparisonTag) }

        return trendCard("Compare tags", help: "Includes nights with a rating, notes, or tags. Compare nights with and without the selected tag. Duration uses recorded sessions, rested averages use ratings you entered, and sound rates use analyzed sessions. Hourly rates are green at zero, yellow through 0.625, and red above that.") {
            Picker("Tag", selection: $comparisonTag) {
                ForEach(NightTag.allCases) { tag in Text(tag.rawValue).tag(tag) }
            }
            .pickerStyle(.menu)
            comparisonRow("With tag", nights: tagged)
            comparisonRow("Without tag", nights: other)
        }
    }

    private func comparisonRow(_ label: String, nights: [TrendNight]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) · \(nights.count) nights").font(.subheadline.weight(.semibold))
            if !nights.isEmpty {
                let average = nights.reduce(0) { $0 + $1.duration } / Double(nights.count)
                let ratings = nights.compactMap(\.restedRating)
                HStack(spacing: 4) {
                    SleepDurationValue(seconds: average)
                    Text("average duration").foregroundStyle(muted)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                let soundRates = nights.compactMap { $0.soundRate }
                if !soundRates.isEmpty {
                    let averageRate = soundRates.reduce(0, +) / Double(soundRates.count)
                    HStack(spacing: 4) {
                        Text(averageRate, format: .number.precision(.fractionLength(2)))
                            .bold()
                            .monospacedDigit()
                            .foregroundStyle(soundRateColor(averageRate))
                        Text("episodes/hr · \(soundRates.count) analyzed").foregroundStyle(muted)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
                if !ratings.isEmpty {
                    let rested = ratings.reduce(0, +) / Double(ratings.count)
                    HStack(spacing: 4) {
                        RestedScore(value: rested, showDecimal: true)
                        Text("rested · \(ratings.count) rated").foregroundStyle(muted)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func trendCard<Content: View>(
        _ title: String, help: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                TrendInfoButton(title: title, help: help)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func soundRateColor(_ rate: Double) -> Color {
        // Normalize the five-episode cutoff to an eight-hour session.
        switch rate {
        case 0: .green
        case ...0.625: .yellow
        default: .red
        }
    }

    private func nightBar(at index: Int, value: Double, axis: String) -> RectangleMark {
        // Set both edges in day units so gaps do not affect the width of a bar.
        let center = Double(index)
        return RectangleMark(
            xStart: .value("Night", center - 0.31),
            xEnd: .value("Night", center + 0.31),
            yStart: .value(axis, 0.0),
            yEnd: .value(axis, value)
        )
    }

    private func sessionLinks(for night: TrendNight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(night.date.formatted(date: .complete, time: .omitted)).font(.headline)
                Spacer()
                Button { selection = nil } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close selected night")
            }
            if night.sessions.isEmpty {
                Text("No sessions recorded").foregroundStyle(muted)
            }
            ForEach(night.sessions) { session in
                Button {
                    openSession(session)
                } label: {
                    NightRow(night: session, title: session.startedAt.formatted(date: .omitted, time: .shortened))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SleepDurationValue: View {
    let seconds: TimeInterval

    var body: some View {
        Text(durationText(seconds))
            .bold()
            .monospacedDigit()
            .foregroundStyle(Self.color(for: seconds))
    }

    static func color(for seconds: TimeInterval) -> Color {
        switch seconds / 3_600 {
        case ..<6: return .red
        case ..<7: return .yellow
        default: return .green
        }
    }
}

struct RestedScore: View {
    let value: Double
    var showDecimal = false

    var body: some View {
        let score = value.formatted(.number.precision(.fractionLength(showDecimal ? 1 : 0)))
        Text("\(score)/5")
            .bold()
            .monospacedDigit()
            .foregroundStyle(Self.color(for: value))
            .accessibilityLabel("\(score) out of 5")
    }

    static func color(for value: Double) -> Color {
        switch value.rounded() {
        case ...2: return .red
        case 3: return .yellow
        default: return .green
        }
    }
}

private struct TrendInfoButton: View {
    let title: String
    let help: String
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(muted)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .alert(title, isPresented: $showingHelp) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(help)
        }
    }
}

private struct NightChartAxis: ViewModifier {
    let nights: [TrendNight]

    var select: ((Int) -> Void)? = nil

    @ScaledMetric(relativeTo: .caption2) private var dateRowHeight: CGFloat = 20

    func body(content: Content) -> some View {
        let ticks = nights.indices.filter { nights.count <= 7 || $0.isMultiple(of: 6) || $0 == nights.count - 1 }
        content
            .chartXScale(domain: -0.5...(Double(nights.count) - 0.5))
            .chartXAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { area in
                    if let anchor = proxy.plotFrame {
                        let plot = area[anchor]
                        ForEach(ticks, id: \.self) { index in
                            if let x = proxy.position(forX: Double(index)) {
                                Text(nights[index].date, format: .dateTime.day())
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize()
                                    .position(x: plot.minX + x, y: plot.maxY + dateRowHeight / 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        if let select {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .frame(width: plot.width, height: plot.height)
                                .onTapGesture { tap in
                                    if let day: Double = proxy.value(atX: tap.x) {
                                        select(min(nights.count - 1, max(0, Int(day.rounded()))))
                                    }
                                }
                                .position(x: plot.midX, y: plot.midY)
                        }
                    }
                }
            }
            .padding(.bottom, dateRowHeight)
            .frame(height: 155)
        if let first = nights.first, let last = nights.last {
            Text("\(first.date, format: .dateTime.month(.abbreviated).day()) – \(last.date, format: .dateTime.month(.abbreviated).day())")
                .font(.caption).foregroundStyle(muted)
                .frame(maxWidth: .infinity)
        }
    }
}
