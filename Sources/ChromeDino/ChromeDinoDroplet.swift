//
//  ChromeDinoDroplet.swift
//  ChromeDino
//
//  The offline dino runner for Droppy's shelf.
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(ChromeDinoPrincipal)
public final class ChromeDinoPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { ChromeDinoDroplet() }
}

/// The dino runner. The droplet owns the simulation so the shelf widget and
/// the takeover show the same run; the views only draw it.
@MainActor
public final class ChromeDinoDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "chrome-dino"

    // MARK: Game state (drawn by every surface)

    @Published var score = 0
    @Published var highScore = 0
    @Published var isPlaying = false
    @Published var isGameOver = false
    @Published var dinoY: CGFloat = 0
    @Published var obstacles: [DinoObstacle] = []
    @Published var clouds: [DinoCloud] = []
    @Published var legFrame = 0

    // MARK: Settings (persisted)

    @Published var showClouds = true
    @Published var holdOpenWhilePlaying = true

    private var host: DropletHost?
    private var ticker: AnyCancellable?

    // Physics tuning for a ~400pt world at 60fps.
    private var velocity: CGFloat = 0
    private var speed: CGFloat = 300
    private var spawnIn: Double = 1.0
    private var legTimer: Double = 0
    private let jumpVelocity: CGFloat = 780
    private let gravity: CGFloat = 2450
    private let baseSpeed: CGFloat = 300
    private let maxSpeed: CGFloat = 620

    /// Travelled distance in points. Drives the ground ticks and the score.
    var distance: CGFloat { _distance }

    private var _distance: CGFloat = 0

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        highScore = host.preferences.value(forKey: "highScore", default: 0)
        showClouds = host.preferences.value(forKey: "showClouds", default: true)
        holdOpenWhilePlaying = host.preferences.value(forKey: "holdOpen", default: true)
        seedClouds()
        host.log.info("Chrome Dino activated, high score \(highScore)")

        // One timer for the whole droplet. It drives clouds at rest and the
        // run while playing. Torn down in deactivate.
        ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    public func deactivate() {
        ticker?.cancel()
        ticker = nil
        _ = host?.shelf.setHoldsOpen(false)
        host = nil
    }

    // MARK: Game control

    /// Tap, click or jump button: starts, jumps, or restarts.
    func pressJump() {
        if isGameOver {
            start()
        } else if !isPlaying {
            start()
        } else if dinoY <= 0.5 {
            velocity = jumpVelocity
        }
    }

    func start() {
        score = 0
        _distance = 0
        obstacles = []
        dinoY = 0
        velocity = 0
        speed = baseSpeed
        spawnIn = 0.9
        legTimer = 0
        legFrame = 0
        isGameOver = false
        isPlaying = true
        refreshHold()
        host?.log.info("Chrome Dino run started")
    }

    func stopToIdle() {
        isPlaying = false
        isGameOver = false
        refreshHold()
    }

    private func gameOver() {
        isPlaying = false
        isGameOver = true
        if score > highScore {
            highScore = score
            host?.preferences.setValue(highScore, forKey: "highScore")
        }
        refreshHold()
        host?.log.info("Chrome Dino game over at \(score), best \(highScore)")
    }

    func resetHighScore() {
        highScore = 0
        host?.preferences.setValue(0, forKey: "highScore")
    }

    private func refreshHold() {
        guard let host else { return }
        if isPlaying && holdOpenWhilePlaying {
            _ = host.shelf.setHoldsOpen(true)
        } else {
            _ = host.shelf.setHoldsOpen(false)
        }
    }

    // MARK: Simulation

    private func seedClouds() {
        clouds = (0..<4).map { i in
            DinoCloud(
                x: CGFloat(i) * 120 + CGFloat.random(in: 0...60),
                y: CGFloat.random(in: 10...44),
                scale: CGFloat.random(in: 0.8...1.2)
            )
        }
    }

    private func tick() {
        let dt: CGFloat = 1.0 / 60.0

        // Clouds always drift so the idle scene feels alive.
        for i in clouds.indices {
            clouds[i].x -= 16 * dt
            if clouds[i].x < -50 {
                clouds[i].x = DinoWorld.width + CGFloat.random(in: 0...80)
                clouds[i].y = CGFloat.random(in: 10...44)
            }
        }

        guard isPlaying else { return }

        // Speed ramps with distance.
        speed = min(baseSpeed + _distance * 0.012, maxSpeed)
        _distance += speed * dt
        score = Int(_distance / 10)

        // Dino physics.
        if dinoY > 0 || velocity != 0 {
            velocity -= gravity * dt
            dinoY += velocity * dt
            if dinoY <= 0 {
                dinoY = 0
                velocity = 0
            }
        }

        // Leg animation on the ground.
        if dinoY <= 0.5 {
            legTimer += Double(dt)
            if legTimer > 0.12 {
                legTimer = 0
                legFrame = legFrame == 0 ? 1 : 0
            }
        }

        // Spawn cacti.
        spawnIn -= Double(dt)
        if spawnIn <= 0 {
            spawnObstacle()
            let slowness = max(0.55, 340 / speed)
            spawnIn = Double.random(in: 0.75...1.5) * Double(slowness) + 0.25
        }

        // Move obstacles.
        for i in obstacles.indices {
            obstacles[i].x -= speed * dt
        }
        obstacles.removeAll { $0.x + $0.width < -30 }

        checkCollision()
    }

    private func spawnObstacle() {
        let roll = Int.random(in: 0...9)
        let preset: (CGFloat, CGFloat)
        switch roll {
        case 0...3:
            preset = (14, 28)
        case 4...6:
            preset = (18, 40)
        case 7...8:
            preset = (32, 26)
        default:
            preset = (18, 34)
        }
        obstacles.append(DinoObstacle(x: DinoWorld.width + 20, width: preset.0, height: preset.1))
    }

    private func checkCollision() {
        let dinoLeft = DinoWorld.dinoX + 3
        let dinoRight = DinoWorld.dinoX + 21
        let dinoBottom = dinoY
        let dinoTop = dinoY + 26
        for obstacle in obstacles {
            let left = obstacle.x + 3
            let right = obstacle.x + obstacle.width - 3
            let top = obstacle.height - 2
            if dinoRight > left && dinoLeft < right && dinoBottom < top && dinoTop > 2 {
                gameOver()
                return
            }
        }
    }

    // MARK: Expanded surface

    func openExpanded() {
        guard let host else { return }
        guard host.isGranted(.expandedSurface) else {
            host.log.error("Chrome Dino takeover needs the expanded-surface capability")
            return
        }
        let presentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: "dino-run", opensShelf: true)
        )
        if presentation == nil {
            host.log.error("Chrome Dino takeover was refused")
        }
    }

    func closeExpanded() {
        host?.notchSurface.dismissExpandedSurface("dino-run")
    }

    // MARK: Settings bindings

    var showCloudsBinding: Binding<Bool> {
        Binding(
            get: { self.showClouds },
            set: {
                self.showClouds = $0
                self.host?.preferences.setValue($0, forKey: "showClouds")
            }
        )
    }

    var holdOpenBinding: Binding<Bool> {
        Binding(
            get: { self.holdOpenWhilePlaying },
            set: {
                self.holdOpenWhilePlaying = $0
                self.host?.preferences.setValue($0, forKey: "holdOpen")
                self.refreshHold()
            }
        )
    }
}

// MARK: - Shelf widget

extension ChromeDinoDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "dino-run",
                title: "Chrome Dino",
                systemImage: "figure.run",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(172)
                ),
                searchKeywords: ["dino", "game", "runner", "jump"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(ChromeDinoWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The playable widget. Solo and paired are the same game at different
/// widths; the canvas adapts, so there is no width comparison here.
private struct ChromeDinoWidget: View {
    @ObservedObject var droplet: ChromeDinoDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "figure.run")
                    .font(.system(size: 12, weight: .medium))
                Text("Chrome Dino")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(droplet.score)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .accessibilityLabel("Score \(droplet.score)")
                Button {
                    droplet.openExpanded()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Open the bigger run")
                .accessibilityLabel("Open the bigger run")
                Button {
                    droplet.pressJump()
                } label: {
                    Image(systemName: droplet.isPlaying ? "arrow.up" : "play.fill")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help(droplet.isPlaying ? "Jump" : "Start")
                .accessibilityLabel(droplet.isPlaying ? "Jump" : "Start game")
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            ZStack(alignment: .topLeading) {
                DinoGameCanvas(droplet: droplet, height: context.isCompact ? 76 : 92)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        droplet.pressJump()
                    }

                if !droplet.isPlaying && !droplet.isGameOver {
                    Text("Tap to start")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                }

                if droplet.isGameOver {
                    VStack(spacing: 2) {
                        Text("Game over")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Text("Tap to run again")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                }
            }

            HStack {
                Text("Best \(droplet.highScore)")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .monospacedDigit()
                Spacer(minLength: DroppySpacing.md)
                Text("Tap to jump")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Expanded surface (bigger run)

extension ChromeDinoDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

extension ChromeDinoDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: "dino-run",
                title: "Chrome Dino",
                systemImage: "figure.run",
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        AnyView(
            DinoTakeoverView(droplet: self)
                .padding(DroppySpacing.xl)
        )
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        CGSize(width: proposal.standardSize.width, height: min(proposal.maximumSize.height, 320))
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        host?.log.debug("Chrome Dino takeover dismissed: \(reason)")
    }
}

private struct DinoTakeoverView: View {
    @ObservedObject var droplet: ChromeDinoDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "figure.run")
                    .font(.system(size: 12, weight: .medium))
                Text("Chrome Dino")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("Best \(droplet.highScore)")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .monospacedDigit()
                Text("\(droplet.score)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Button {
                    droplet.pressJump()
                } label: {
                    Image(systemName: droplet.isPlaying ? "arrow.up" : "play.fill")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help(droplet.isPlaying ? "Jump" : "Start")
                .accessibilityLabel(droplet.isPlaying ? "Jump" : "Start game")
                Button {
                    droplet.closeExpanded()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 24))
                .help("Back to the shelf")
                .accessibilityLabel("Back to the shelf")
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            ZStack {
                DinoGameCanvas(droplet: droplet, height: 220, scale: 1.4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        droplet.pressJump()
                    }

                if droplet.isGameOver {
                    VStack(spacing: DroppySpacing.xs) {
                        Text("Game over")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Text("Score \(droplet.score) · best \(droplet.highScore)")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .monospacedDigit()
                        Button("Run again") {
                            droplet.start()
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    .allowsHitTesting(true)
                } else if !droplet.isPlaying {
                    VStack(spacing: DroppySpacing.xs) {
                        Text("Ready to run")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        Button("Start") {
                            droplet.start()
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
            }

            Text("Tap the desert or press jump to hop the cacti.")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings pane

extension ChromeDinoDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(ChromeDinoSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Chrome Dino", keywords: ["dino", "game", "runner"]),
            SettingsSearchEntry(title: "Reset high score", keywords: ["best", "score", "reset"]),
        ]
    }
}

private struct ChromeDinoSettings: View {
    @ObservedObject var droplet: ChromeDinoDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletControlRow(title: "High score") {
                    DropletValuePill(text: "\(droplet.highScore)")
                }
                DropletControlRow(title: "Reset the best score") {
                    Button("Reset") {
                        droplet.resetHighScore()
                    }
                    .buttonStyle(.bordered)
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Game")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Show clouds",
                        subtitle: "Drifting clouds behind the run.",
                        isOn: droplet.showCloudsBinding
                    )
                    DropletToggleRow(
                        title: "Hold the shelf open",
                        subtitle: "Keeps the shelf up while a run is going.",
                        isOn: droplet.holdOpenBinding
                    )
                }
            }
        }
    }
}
