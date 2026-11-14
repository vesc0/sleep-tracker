// Summarizes saved sessions by night and displays duration and sound trends.

import Charts
import SwiftUI

struct TrendNight: Identifiable {
    let date: Date
    let sessions: [Night]

    var id: Date { date }
    var duration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }

    func soundRate(for sound: NightSound?) -> Double? {
        let analyzed = sessions.filter { !$0.needsAnalysis }
        let hours = analyzed.reduce(0) { $0 + $1.duration } / 3_600
        guard hours > 0 else { return nil }

        let count = analyzed.flatMap(\.clips).count { clip in
            sound.map { (clip.sounds ?? [.snoring]).contains($0) } ?? true
        }
        return Double(count) / hours
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
    @State private var selectedDay: Int?

    private var localCalendar: Calendar {
        var local = calendar
        local.timeZone = timeZone
        return local
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let nights = TrendNight.recent(sessions, days: days, now: context.date, calendar: localCalendar)
            let tracked = nights.filter { !$0.sessions.isEmpty }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Trends").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
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
                        if let selectedDay, nights.indices.contains(selectedDay) {
                            sessionLinks(for: nights[selectedDay])
                        }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: nights.first?.date) { _, _ in selectedDay = nil }
        }
        .onChange(of: days) { _, _ in selectedDay = nil }
        .background(nightBackground.ignoresSafeArea())
        .toolbarBackground(nightBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private func durationCard(_ nights: [TrendNight], tracked: [TrendNight]) -> some View {
        let average = tracked.reduce(0) { $0 + $1.duration } / Double(tracked.count)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Sleep duration").font(.headline).accessibilityAddTraits(.isHeader)
            Text(durationText(average)).font(.title.bold().monospacedDigit())
            Text("Average from recorded sessions · \(tracked.count) of \(days) nights")
                .font(.subheadline).foregroundStyle(muted)

            Chart {
                ForEach(nights.indices, id: \.self) { index in
                    if nights[index].duration > 0 {
                        nightBar(at: index, value: nights[index].duration / 3_600, axis: "Sleep duration in hours")
                            .foregroundStyle(selectedDay == index ? Color.white : accent)
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
            .chartYAxisLabel("Hours")
            .modifier(NightChartAxis(nights: nights))
            .chartXSelection(value: daySelection)
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func soundsCard(_ nights: [TrendNight]) -> some View {
        let rates = nights.map { $0.soundRate(for: sound) }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Nighttime sounds").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Sound type", selection: $sound) {
                Text("All sounds").tag(nil as NightSound?)
                ForEach(NightSound.allCases, id: \.self) { sound in
                    Text(sound.title).tag(Optional(sound))
                }
            }
            .pickerStyle(.menu)
            .tint(accent)

            if rates.allSatisfy({ $0 == nil }) {
                Text("Analyze a session to see sound trends.")
                    .font(.subheadline).foregroundStyle(muted)
            } else {
                Text("Flagged clips per session hour")
                    .font(.subheadline).foregroundStyle(muted)
                Chart {
                    ForEach(nights.indices, id: \.self) { index in
                        if let rate = rates[index] {
                            if rate > 0 {
                                nightBar(at: index, value: rate, axis: "Clips per hour")
                                    .foregroundStyle(selectedDay == index ? Color.white : accent)
                                    .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue(rate.formatted(.number.precision(.fractionLength(0...1))))
                            } else {
                                PointMark(x: .value("Night", Double(index)), y: .value("Clips per hour", 0.0))
                                    .foregroundStyle(selectedDay == index ? Color.white : accent)
                                    .accessibilityLabel(nights[index].date.formatted(date: .abbreviated, time: .omitted))
                                    .accessibilityValue("0 clips per hour")
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...max(1, (rates.compactMap { $0 }.max() ?? 0) * 1.1))
                .modifier(NightChartAxis(nights: nights))
                .chartXSelection(value: daySelection)
            }
        }
        .padding(16)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
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

    private var daySelection: Binding<Double?> {
        Binding(
            get: { selectedDay.map { Double($0) } },
            set: { selectedDay = $0.map { Int($0.rounded()) } }
        )
    }

    private func sessionLinks(for night: TrendNight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(night.date.formatted(date: .complete, time: .omitted)).font(.headline)
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

private struct NightChartAxis: ViewModifier {
    let nights: [TrendNight]

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: -0.5...(Double(nights.count) - 0.5))
            .chartXAxis {
                AxisMarks(values: stride(from: 0, to: nights.count, by: nights.count > 7 ? 7 : 2).map { Double($0) }) { value in
                    if let index = value.as(Double.self).map(Int.init), nights.indices.contains(index) {
                        AxisValueLabel {
                            Text(nights[index].date, format: .dateTime.month(.abbreviated).day())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 155)
    }
}
