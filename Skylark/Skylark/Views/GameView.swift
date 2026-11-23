import SpriteKit
import SwiftUI

struct GameView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHangar = false

    var body: some View {
        ZStack {
            SpriteView(scene: model.scene, isPaused: model.paused)
                .ignoresSafeArea()
            switch model.phase {
            case .menu: menu
            case .playing: hud
            case .crashed: results
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $showHangar) { HangarView() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, model.phase == .playing { model.paused = true }
        }
    }

    private var menu: some View {
        VStack(spacing: 14) {
            Text("Skylark")
                .font(.system(size: 54, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
            if let aircraft = model.selected {
                Text(aircraft.name)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            HStack(spacing: 14) {
                Button { model.play() } label: { Label("Fly", systemImage: "play.fill").frame(minWidth: 110) }
                    .buttonStyle(BigButton(color: .orange))
                Button { showHangar = true } label: { Label("Hangar", systemImage: "airplane").frame(minWidth: 110) }
                    .buttonStyle(BigButton(color: .blue))
            }
            HStack(spacing: 18) {
                Label("\(model.totalStars)", systemImage: "star.fill")
                if model.best > 0 { Label("Best \(model.best) m", systemImage: "trophy.fill") }
            }
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
    }

    private var hud: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    Text("\(model.metres) m")
                        .font(.system(.title, design: .rounded).weight(.heavy).monospacedDigit())
                    Spacer()
                    Label("\(model.runStars)", systemImage: "star.fill")
                        .font(.system(.title2, design: .rounded).weight(.heavy).monospacedDigit())
                    Button { model.paused = true } label: {
                        Image(systemName: "pause.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.25), in: Circle())
                    }
                    .accessibilityLabel("Pause")
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                Spacer()
                if model.metres < 45 {
                    Text(model.selected?.type == "helicopter" ? "Hold to lift · let go to sink" : "Hold to climb · let go to dive")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.3), in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .padding()
            if model.paused {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("Paused")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 14) {
                        Button { model.paused = false } label: { Label("Resume", systemImage: "play.fill").frame(minWidth: 110) }
                            .buttonStyle(BigButton(color: .orange))
                        Button { model.backToMenu() } label: { Label("Quit", systemImage: "xmark").frame(minWidth: 110) }
                            .buttonStyle(BigButton(color: .gray))
                    }
                }
            }
        }
    }

    private var results: some View {
        VStack(spacing: 12) {
            Text(model.isNewBest ? "New best!" : "Crashed!")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
            HStack(spacing: 22) {
                Label("\(model.metres) m", systemImage: "ruler.fill")
                Label("+\(model.runStars)", systemImage: "star.fill")
            }
            .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Best \(model.best) m · \(model.totalStars) stars to spend")
                .font(.system(.subheadline, design: .rounded))
                .opacity(0.85)
            HStack(spacing: 14) {
                Button { model.play() } label: { Label("Fly again", systemImage: "arrow.clockwise").frame(minWidth: 110) }
                    .buttonStyle(BigButton(color: .orange))
                Button { model.backToMenu(); showHangar = true } label: { Label("Hangar", systemImage: "airplane").frame(minWidth: 110) }
                    .buttonStyle(BigButton(color: .blue))
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct BigButton: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(color, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}
