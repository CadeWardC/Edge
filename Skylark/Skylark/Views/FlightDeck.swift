import SwiftUI

/// Instruments and controls over the 3D view while flying.
struct FlightDeck: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var simulator: FlightSimulator
    @Binding var showHangar: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                instruments
                if simulator.telemetry.stalled {
                    Text("STALL · nose down, add power")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.red, in: Capsule())
                }
                if let note = simulator.note {
                    Text(note)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 14) {
                    ThrottleSlider(value: $model.throttle, name: simulator.throttleName)
                    RudderSlider { model.moveRudder($0) }
                    Spacer()
                    Joystick { model.moveStick($0) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .animation(.default, value: simulator.note)

            if let reason = simulator.crash {
                card(title: "Crashed", detail: reason) {
                    Button { model.again() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(BigButton(color: .orange))
                    Button { model.backToMenu() } label: { Label("Menu", systemImage: "house") }
                        .buttonStyle(BigButton(color: .gray))
                }
            } else if model.paused {
                card(title: "Paused", detail: nil) {
                    Button { model.paused = false } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(BigButton(color: .orange))
                    Button { model.again() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .buttonStyle(BigButton(color: .teal))
                    Button { model.backToMenu() } label: { Label("Menu", systemImage: "house") }
                        .buttonStyle(BigButton(color: .gray))
                }
            }
        }
    }

    private var instruments: some View {
        let t = simulator.telemetry
        return HStack(spacing: 10) {
            Gauge(name: "SPEED", value: "\(t.speed)", unit: "kt")
            Gauge(name: "ALTITUDE", value: "\(t.altitude)", unit: "ft")
            Gauge(name: "CLIMB", value: t.climb > 0 ? "+\(t.climb)" : "\(t.climb)", unit: "ft/min")
            Gauge(name: "HEADING", value: String(format: "%03d", t.heading), unit: Self.compassPoint(t.heading))
            if t.aboveGround < 1000 && !t.onGround {
                Gauge(name: "GROUND", value: "\(t.aboveGround)", unit: "ft below")
            }
            if t.ringsTotal > 0 {
                Gauge(name: "RINGS", value: "\(t.ringsDone)/\(t.ringsTotal)", unit: "")
            }
            Spacer()
            Button { model.view = model.view == .chase ? .cockpit : .chase } label: {
                Image(systemName: model.view == .chase ? "video.fill" : "eye.fill").roundButton()
            }
            .accessibilityLabel(model.view == .chase ? "Switch to cockpit view" : "Switch to outside view")
            Button { model.paused = true } label: {
                Image(systemName: "pause.fill").roundButton()
            }
            .accessibilityLabel("Pause")
        }
    }

    private static func compassPoint(_ degrees: Int) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((Double(degrees) / 45).rounded()) % 8]
    }

    private func card<Buttons: View>(title: String, detail: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                if let detail {
                    Text(detail)
                        .font(.system(.title3, design: .rounded))
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) { buttons() }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

private struct Gauge: View {
    let name: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .opacity(0.8)
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
            Text(unit.isEmpty ? " " : unit)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .frame(minWidth: 62)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value) \(unit)")
    }
}

private extension Image {
    func roundButton() -> some View {
        self.font(.title3)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
    }
}

// MARK: Controls

/// The stick. Drag anywhere in the circle; it springs back to the middle when let go.
struct Joystick: View {
    /// x is right, y is back (towards the pilot), each -1 to 1.
    let onMove: (CGPoint) -> Void
    @State private var knob = CGSize.zero
    private let size: CGFloat = 156
    private var reach: CGFloat { size / 2 - 26 }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.25))
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
            Path { path in
                path.move(to: CGPoint(x: size / 2, y: 14)); path.addLine(to: CGPoint(x: size / 2, y: size - 14))
                path.move(to: CGPoint(x: 14, y: size / 2)); path.addLine(to: CGPoint(x: size - 14, y: size / 2))
            }
            .stroke(.white.opacity(0.2), lineWidth: 1)
            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 52, height: 52)
                .offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    var offset = CGSize(width: drag.location.x - size / 2, height: drag.location.y - size / 2)
                    let length = hypot(offset.width, offset.height)
                    if length > reach {
                        offset.width *= reach / length
                        offset.height *= reach / length
                    }
                    knob = offset
                    onMove(CGPoint(x: offset.width / reach, y: offset.height / reach))
                }
                .onEnded { _ in
                    knob = .zero
                    onMove(.zero)
                }
        )
        .accessibilityLabel("Stick")
    }
}

/// Stays where it is put. Up is more.
struct ThrottleSlider: View {
    @Binding var value: Float
    let name: String
    private let size = CGSize(width: 58, height: 170)

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 14)
                    .fill(.orange.opacity(0.75))
                    .frame(height: max(CGFloat(value) * size.height, 6))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 2)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(.footnote, design: .rounded).weight(.heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = Float(min(max(1 - (drag.location.y - 10) / (size.height - 20), 0), 1))
                }
            )
            Text(name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }
}

/// Left and right rudder. Springs back to the middle.
struct RudderSlider: View {
    let onMove: (Float) -> Void
    @State private var position: CGFloat = 0
    private let size = CGSize(width: 170, height: 50)
    private var reach: CGFloat { size.width / 2 - 26 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.5), lineWidth: 2))
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.85))
                    .frame(width: 44, height: 36)
                    .offset(x: position * reach)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        position = min(max((drag.location.x - size.width / 2) / reach, -1), 1)
                        onMove(Float(position))
                    }
                    .onEnded { _ in
                        position = 0
                        onMove(0)
                    }
            )
            Text("RUDDER")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Rudder")
    }
}
