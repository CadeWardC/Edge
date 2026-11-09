import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SwitchbackWidgets: WidgetBundle {
    var body: some Widget {
        HikeLiveActivity()
    }
}

private let green = Color(red: 0.13, green: 0.62, blue: 0.30)

struct HikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HikeAttributes.self) { context in
            LockScreenHike(context: context)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Distance").font(.caption2).foregroundStyle(.secondary)
                        Text(HikeFormat.distance(s.distance, imperial: s.imperial)).font(.title3.bold().monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Time").font(.caption2).foregroundStyle(.secondary)
                        TimeText(state: s).font(.title3.bold().monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label("↑ " + HikeFormat.elevation(s.gain, imperial: s.imperial), systemImage: "mountain.2.fill")
                        Spacer()
                        if s.offTrail {
                            Label("Off trail", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        } else if let r = s.remaining {
                            Label(HikeFormat.distance(r, imperial: s.imperial) + " to go", systemImage: "flag.checkered")
                        }
                    }
                    .font(.caption.bold())
                }
            } compactLeading: {
                Image(systemName: s.offTrail ? "exclamationmark.triangle.fill" : "figure.hiking")
                    .foregroundStyle(s.offTrail ? .red : green)
            } compactTrailing: {
                Text(HikeFormat.distance(s.remaining ?? s.distance, imperial: s.imperial))
                    .font(.caption.bold().monospacedDigit())
            } minimal: {
                Image(systemName: "figure.hiking").foregroundStyle(green)
            }
        }
    }
}

private struct TimeText: View {
    let state: HikeAttributes.ContentState

    var body: some View {
        if let paused = state.pausedElapsed {
            Text(HikeFormat.clock(paused))
        } else {
            Text(state.timerStart, style: .timer)
        }
    }
}

private struct LockScreenHike: View {
    let context: ActivityViewContext<HikeAttributes>

    var body: some View {
        let s = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "figure.hiking").foregroundStyle(green)
                Text(context.attributes.trailName ?? "Hike").font(.headline).lineLimit(1)
                Spacer()
                if s.pausedElapsed != nil {
                    Text("Paused").font(.caption.bold()).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .top) {
                stat("Time") { TimeText(state: s) }
                stat("Distance") { Text(HikeFormat.distance(s.distance, imperial: s.imperial)) }
                stat("Climb") { Text(HikeFormat.elevation(s.gain, imperial: s.imperial)) }
                if let r = s.remaining {
                    stat("To go") { Text(HikeFormat.distance(r, imperial: s.imperial)) }
                }
            }
            if s.offTrail {
                Label("You're off the trail", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func stat<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.7))
            value().font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
