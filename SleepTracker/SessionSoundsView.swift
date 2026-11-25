// Session-level measurements and the recordings behind each episode.
import SwiftUI

private extension NightSound {
    var color: Color {
        switch self { case .snoring: accent; case .speech: .mint; case .cough: .orange }
    }
}

private func db(_ value: Double) -> String { "\(Int(value.rounded())) dBFS" }

struct SessionSoundsView: View {
    let night: Night
    @EnvironmentObject private var model: SessionModel

    var body: some View {
        let episodes = night.episodes
        let levels = night.levels ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording levels").font(.headline)
            if levels.isEmpty {
                Text("Level measurements are unavailable for this session.").foregroundStyle(muted)
            } else {
                let sorted = levels.map(\.power).sorted()
                let peak = levels.map(\.peak).max() ?? 0
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        level("Quiet", RecordingLevel.percentile(sorted, 0.1))
                        level("Typical", RecordingLevel.percentile(sorted, 0.5))
                    }
                    GridRow {
                        level("Average", RecordingLevel.average(levels))
                        level("Peak", RecordingLevel.decibels(peak * peak))
                    }
                }
                Text("Levels are relative to your microphone. Distance and phone placement affect them.")
                    .font(.caption).foregroundStyle(muted)
            }
            if night.duration > 0 {
                timeline(episodes, levels: levels)
                if let clip = episodes.first?.clips.first, model.audioURL(for: clip, in: night) != nil {
                    Text("Tap a colored marker to hear its recording.").font(.caption).foregroundStyle(muted)
                }
            }
            Text("Sound episodes").font(.headline)
            if night.needsAnalysis {
                Text("Totals so far").font(.caption).foregroundStyle(muted)
            } else if night.options?.sounds.isEmpty == true {
                Text("Sound detection was off for this session.").foregroundStyle(muted)
            } else if episodes.isEmpty {
                Text("No nighttime sounds were flagged.").foregroundStyle(muted)
            }
            ForEach(NightSound.allCases, id: \.self) { sound in
                let group = episodes.filter { $0.sound == sound }
                if !group.isEmpty {
                    let seconds = group.reduce(0) { $0 + $1.detectedDuration }
                    let unit = sound == .cough ? "bout" : "episode"
                    HStack {
                        Circle().fill(sound.color).frame(width: 8, height: 8)
                        Text(sound.title)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(group.count) \(unit)\(group.count == 1 ? "" : "s") · ~\(durationText(seconds))")
                            if night.duration > 0 {
                                Text("\(seconds / night.duration, format: .percent.precision(.fractionLength(1))) of recording")
                                    .font(.caption).foregroundStyle(muted)
                            }
                        }
                    }.font(.subheadline)
                }
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode, night: night)
                }
            }
        }
    }

    private func level(_ title: String, _ value: Double) -> some View {
        LabeledContent(title, value: db(value)).font(.subheadline.monospacedDigit())
    }

    private func clipDistance(_ clip: SoundClip, from time: Date) -> Double {
        max(0, clip.startedAt.timeIntervalSince(time), time.timeIntervalSince(clip.startedAt) - clip.duration)
    }

    private func timeline(_ episodes: [SoundEpisode], levels: [RecordingLevel]) -> some View {
        let playingID = model.playingID
        return VStack {
            GeometryReader { proxy in
                Canvas { context, size in
                    let scale = size.width / night.elapsed
                    for level in levels {
                        let x = level.start.timeIntervalSince(night.startedAt) * scale
                        let height = min(1, max(0, 1 + RecordingLevel.decibels(level.power) / 90)) * 44
                        context.fill(Path(CGRect(x: x, y: 44 - height, width: max(1, level.duration * scale),
                                                 height: height)), with: .color(muted.opacity(0.7)))
                    }
                    for episode in episodes {
                        let x = episode.start.timeIntervalSince(night.startedAt) * scale
                        let lane = NightSound.allCases.firstIndex(of: episode.sound) ?? 0
                        let rect = CGRect(x: x, y: CGFloat(48 + lane * 8), width: max(3, episode.duration * scale), height: 6)
                        let playing = playingID.map { id in episode.clips.contains { $0.id == id } } ?? false
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(playing ? .white : episode.sound.color))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    let scale = proxy.size.width / night.elapsed
                    let lane = Int(floor((point.y - 48) / 8))
                    guard NightSound.allCases.indices.contains(lane), scale > 0 else { return }
                    let time = night.startedAt.addingTimeInterval(point.x / scale)
                    func distance(_ episode: SoundEpisode) -> Double {
                        max(0, episode.start.timeIntervalSince(time), time.timeIntervalSince(episode.end))
                    }
                    guard let episode = episodes.filter({ $0.sound == NightSound.allCases[lane] })
                        .min(by: { distance($0) < distance($1) }), distance(episode) * scale <= 8,
                          let clip = episode.clips.min(by: {
                              clipDistance($0, from: time) < clipDistance($1, from: time)
                          }) else { return }
                    model.play(clip, in: night, from: min(1, max(0, max(episode.start, time).timeIntervalSince(clip.startedAt) / clip.duration)))
                }
            }.frame(height: 73)
            HStack {
                Text(night.startedAt, style: .time)
                Spacer()
                Text(night.endedAt, style: .time)
            }.font(.caption).foregroundStyle(muted)
        }
    }
}

private struct EpisodeRow: View {
    let episode: SoundEpisode
    let night: Night
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let levels = night.levels {
                        let starts = Set(episode.clips.map(\.startedAt))
                        let source = levels.filter { starts.contains($0.start) }
                        if let peak = source.map(\.peak).max() {
                            let average = RecordingLevel.average(source)
                            Text("Source clips · \(db(average)) average · \(db(RecordingLevel.decibels(peak * peak))) peak")
                            let nearby = levels.filter {
                                ($0.start < episode.start && $0.start >= episode.start.addingTimeInterval(-60)
                                || $0.start >= episode.end && $0.start < episode.end.addingTimeInterval(60))
                                && !starts.contains($0.start)
                            }.map(\.power).sorted()
                            if !nearby.isEmpty {
                                let delta = Int((average - RecordingLevel.percentile(nearby, 0.1)).rounded())
                                Text("\(abs(delta)) dB \(delta >= 0 ? "above" : "below") nearby background")
                            }
                        }
                    }
                    ForEach(episode.clips) { ClipRow(clip: $0, night: night) }
                }.font(.footnote)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.sound == .cough ? "Coughing bout" : episode.sound.title).font(.headline)
                Text("\(episode.start.formatted(date: .omitted, time: .standard)) · ~\(durationText(episode.duration))")
                    .font(.caption).foregroundStyle(muted)
            }
        }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
