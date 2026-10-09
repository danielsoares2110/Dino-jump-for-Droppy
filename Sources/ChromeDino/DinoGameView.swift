//
//  DinoGameView.swift
//  ChromeDino
//
//  The runner rendering shared by the shelf widget and the expanded surface.
//  Passive views: the droplet owns the simulation, these draw it.
//

import DroppyKit
import SwiftUI

/// One cactus. `x` is the world position in points, moving left.
struct DinoObstacle: Identifiable, Equatable {
    let id = UUID()
    var x: CGFloat
    var width: CGFloat
    var height: CGFloat
}

/// One background cloud.
struct DinoCloud: Identifiable, Equatable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
}

/// Fixed world width the simulation spawns in. Views narrower than this
/// simply see obstacles later; the dino at x=48 is visible everywhere.
enum DinoWorld {
    static let width: CGFloat = 440
    static let dinoX: CGFloat = 48
}

/// Pixel-style runner canvas. No background, no card: content straight on
/// the shelf, the way every Droppy widget draws.
struct DinoGameCanvas: View {
    @ObservedObject var droplet: ChromeDinoDroplet
    /// Drawing height in points.
    var height: CGFloat = 92
    /// Shape scale for the takeover.
    var scale: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            let primary = AdaptiveColors.notchSurfacePrimaryText
            let secondary = AdaptiveColors.notchSurfaceSecondaryText
            let tertiary = AdaptiveColors.notchSurfaceTertiaryText
            let groundY = size.height - 10 * scale

            drawGround(context: &context, size: size, groundY: groundY, secondary: secondary, tertiary: tertiary)
            if droplet.showClouds {
                drawClouds(context: &context, size: size, color: tertiary)
            }
            drawObstacles(context: &context, groundY: groundY, color: primary)
            drawDino(context: &context, groundY: groundY, primary: primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityLabel("Dino runner, score \(droplet.score)")
    }

    // MARK: Ground

    private func drawGround(
        context: inout GraphicsContext,
        size: CGSize,
        groundY: CGFloat,
        secondary: Color,
        tertiary: Color
    ) {
        var groundPath = Path()
        groundPath.move(to: CGPoint(x: 0, y: groundY))
        groundPath.addLine(to: CGPoint(x: size.width, y: groundY))
        context.stroke(groundPath, with: .color(secondary), lineWidth: 2 * scale)

        // Moving ticks sell the speed. They wrap across the visible width.
        let spacing: CGFloat = 47
        let offset = droplet.distance.truncatingRemainder(dividingBy: spacing)
        var i: CGFloat = -1
        while i * spacing < size.width + spacing {
            let x = i * spacing - offset + spacing
            if x >= -10 && x <= size.width + 10 {
                let tick = Path(CGRect(x: x, y: groundY + 5 * scale, width: 8 * scale, height: 2 * scale))
                context.fill(tick, with: .color(tertiary.opacity(0.7)))
            }
            i += 1
        }
    }

    // MARK: Clouds

    private func drawClouds(context: inout GraphicsContext, size: CGSize, color: Color) {
        for cloud in droplet.clouds {
            guard cloud.x > -50 && cloud.x < size.width + 50 else { continue }
            let s = cloud.scale * scale
            let y = cloud.y * (size.height / 92)
            let puffs: [CGRect] = [
                CGRect(x: cloud.x, y: y, width: 26 * s, height: 9 * s),
                CGRect(x: cloud.x + 6 * s, y: y - 5 * s, width: 15 * s, height: 8 * s),
            ]
            for rect in puffs {
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
            }
        }
    }

    // MARK: Cacti

    private func drawObstacles(context: inout GraphicsContext, groundY: CGFloat, color: Color) {
        for obstacle in droplet.obstacles {
            drawCactus(
                context: &context,
                x: obstacle.x,
                groundY: groundY,
                width: obstacle.width * scale,
                height: obstacle.height * scale,
                color: color
            )
        }
    }

    private func drawCactus(
        context: inout GraphicsContext,
        x: CGFloat,
        groundY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        color: Color
    ) {
        // One column, or two side by side when wide (a cluster).
        if width > 24 {
            let half = (width - 6) / 2
            drawSingleCactus(context: &context, x: x, groundY: groundY, width: half, height: height * 0.85, color: color)
            drawSingleCactus(context: &context, x: x + half + 6, groundY: groundY, width: half, height: height, color: color)
        } else {
            drawSingleCactus(context: &context, x: x, groundY: groundY, width: width, height: height, color: color)
        }
    }

    private func drawSingleCactus(
        context: inout GraphicsContext,
        x: CGFloat,
        groundY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        color: Color
    ) {
        let stemW = max(4 * scale, width * 0.34)
        let stemX = x + (width - stemW) / 2
        let top = groundY - height
        context.fill(Path(roundedRect: CGRect(x: stemX, y: top, width: stemW, height: height), cornerRadius: 2 * scale), with: .color(color))

        // Arms, only on cacti tall enough to read them.
        if height > 24 * scale {
            let armW = 3 * scale
            let armH = 9 * scale
            // Left arm.
            context.fill(Path(roundedRect: CGRect(x: stemX - armW - 1 * scale, y: top + 9 * scale, width: armW, height: armH), cornerRadius: 1.5 * scale), with: .color(color))
            context.fill(Path(roundedRect: CGRect(x: stemX - armW - 1 * scale, y: top + 7 * scale, width: armW + 3 * scale, height: 3 * scale), cornerRadius: 1.5 * scale), with: .color(color))
            // Right arm.
            context.fill(Path(roundedRect: CGRect(x: stemX + stemW + 1 * scale, y: top + 13 * scale, width: armW, height: armH), cornerRadius: 1.5 * scale), with: .color(color))
            context.fill(Path(roundedRect: CGRect(x: stemX + stemW - 1 * scale, y: top + 11 * scale, width: armW + 3 * scale, height: 3 * scale), cornerRadius: 1.5 * scale), with: .color(color))
        }
    }

    // MARK: Dino

    private func drawDino(context: inout GraphicsContext, groundY: CGFloat, primary: Color) {
        let s = scale
        let feetY = groundY - droplet.dinoY * s
        let x = DinoWorld.dinoX
        let running = droplet.isPlaying && droplet.dinoY <= 0.5
        let legLift: CGFloat = running ? (droplet.legFrame == 0 ? 4 * s : 0) : 0
        let legLift2: CGFloat = running ? (droplet.legFrame == 0 ? 0 : 4 * s) : 0

        // Tail.
        var tail = Path()
        tail.move(to: CGPoint(x: x + 2 * s, y: feetY - 18 * s))
        tail.addLine(to: CGPoint(x: x - 7 * s, y: feetY - 13 * s))
        tail.addLine(to: CGPoint(x: x + 2 * s, y: feetY - 11 * s))
        tail.closeSubpath()
        context.fill(tail, with: .color(primary))

        // Body.
        context.fill(Path(roundedRect: CGRect(x: x, y: feetY - 22 * s, width: 18 * s, height: 12 * s), cornerRadius: 2 * s), with: .color(primary))
        // Head.
        context.fill(Path(roundedRect: CGRect(x: x + 12 * s, y: feetY - 28 * s, width: 10 * s, height: 9 * s), cornerRadius: 2 * s), with: .color(primary))
        // Snout.
        context.fill(Path(roundedRect: CGRect(x: x + 20 * s, y: feetY - 25 * s, width: 4 * s, height: 4 * s), cornerRadius: 1 * s), with: .color(primary))
        // Tiny arm.
        context.fill(Path(CGRect(x: x + 16 * s, y: feetY - 14 * s, width: 3 * s, height: 2 * s)), with: .color(primary))

        // Legs: standing, running alternate, tucked when airborne.
        if droplet.dinoY > 0.5 {
            context.fill(Path(CGRect(x: x + 3 * s, y: feetY - 8 * s, width: 5 * s, height: 8 * s)), with: .color(primary))
            context.fill(Path(CGRect(x: x + 10 * s, y: feetY - 6 * s, width: 5 * s, height: 6 * s)), with: .color(primary))
        } else {
            context.fill(Path(CGRect(x: x + 3 * s, y: feetY - 8 * s - legLift, width: 5 * s, height: 8 * s)), with: .color(primary))
            context.fill(Path(CGRect(x: x + 10 * s, y: feetY - 8 * s - legLift2, width: 5 * s, height: 8 * s)), with: .color(primary))
        }

        // Eye: dark cutout on the light head.
        if droplet.isGameOver {
            // X eye on game over.
            var eye = Path()
            let ex = x + 18 * s
            let ey = feetY - 26 * s
            eye.move(to: CGPoint(x: ex, y: ey))
            eye.addLine(to: CGPoint(x: ex + 3 * s, y: ey + 3 * s))
            eye.move(to: CGPoint(x: ex + 3 * s, y: ey))
            eye.addLine(to: CGPoint(x: ex, y: ey + 3 * s))
            context.stroke(eye, with: .color(.black), lineWidth: 1.2 * s)
        } else {
            context.fill(Path(CGRect(x: x + 18 * s, y: feetY - 26 * s, width: 2 * s, height: 2 * s)), with: .color(.black))
        }
    }
}

private extension Path {
    init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        self = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
    }

    init(ellipseIn rect: CGRect) {
        self = Ellipse().path(in: rect)
    }
}
