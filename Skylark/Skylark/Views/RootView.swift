import SceneKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var simulator: FlightSimulator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHangar = false

    var body: some View {
        ZStack {
            WorldView(simulator: simulator)
                .ignoresSafeArea()
            switch model.phase {
            case .menu: menu
            case .flying: FlightDeck(showHangar: $showHangar)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $showHangar) { HangarView() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, model.phase == .flying, simulator.crash == nil { model.paused = true }
        }
    }

    private var menu: some View {
        VStack(spacing: 12) {
            Text("Skylark")
                .font(.system(size: 50, weight: .heavy, design: .rounded))
            if let aircraft = model.selected {
                Text(aircraft.name)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            Picker("Airport", selection: $model.airport) {
                ForEach(Array(simulator.terrain.airports.enumerated()), id: \.offset) { index, airport in
                    Text(airport.name).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            HStack(spacing: 12) {
                Button { model.fly(inTheAir: false) } label: { Label("Take off", systemImage: "airplane.departure") }
                    .buttonStyle(BigButton(color: .orange))
                Button { model.fly(inTheAir: true) } label: { Label("Start in the air", systemImage: "cloud") }
                    .buttonStyle(BigButton(color: .teal))
                Button { showHangar = true } label: { Label("Hangar", systemImage: "airplane") }
                    .buttonStyle(BigButton(color: .blue))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        .padding(.bottom, 90)
    }
}

/// The 3D view. The simulator drives it.
struct WorldView: UIViewRepresentable {
    let simulator: FlightSimulator

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = simulator.scene
        view.pointOfView = simulator.cameraNode
        view.delegate = simulator
        view.isPlaying = true
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.backgroundColor = WorldBuilder.haze
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct BigButton: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(color, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}
