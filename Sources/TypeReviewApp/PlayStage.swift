import AppKit
import QuartzCore
import TypeReviewKit

/// Everything drawn on the playfield: a layer per falling item, and the
/// short-lived pieces a burst throws.
///
/// The effects take their colour from the caret, the one accent the practice
/// screen already has; nothing here adds a hue of its own. With Reduce Motion
/// on, a finished word fades where it stands instead of flying apart, and
/// nothing sprays.
@MainActor
final class PlayStage {
    private let world: CALayer
    var art: PlayArt {
        didSet { if art.signature != oldValue.signature { invalidate() } }
    }
    var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var itemLayers: [Int: CALayer] = [:]
    private var drawnAs: [Int: String] = [:]
    /// Each item as of the last sync, so a burst or a loss can still find where
    /// it was after the rules have let go of it.
    private var lastSeen: [Int: FallingItem] = [:]
    private var glyphs: [String: CGImage] = [:]

    private struct Piece {
        let layer: CALayer
        var x, y, vx, vy, spin, angle: CGFloat
        var life: Double
        let span: Double
        let gravity: CGFloat
    }
    private struct Spark {
        let layer: CALayer
        var x, y, vx, vy: CGFloat
        var life: Double
        let span: Double
        let gravity: CGFloat
    }
    private struct Ring {
        let layer: CAShapeLayer
        let x, y, from, to: CGFloat
        var life: Double
        let span: Double
    }
    private struct Pop {
        let layer: CATextLayer
        let x, y: CGFloat
        var life: Double
        let span: Double
    }
    private var pieces: [Piece] = []
    private var sparks: [Spark] = []
    private var rings: [Ring] = []
    private var pops: [Pop] = []

    init(world: CALayer, art: PlayArt) {
        self.world = world
        self.art = art
    }

    /// Pieces of bursts still in flight, for the self-test to see one happen.
    var effectsInFlight: Int { pieces.count + sparks.count + rings.count }

    /// The image a falling item's layer is showing, for the self-test to read.
    func image(forItem id: Int) -> CGImage? {
        guard let contents = itemLayers[id]?.contents else { return nil }
        // A layer's contents is `Any`; the stage only ever puts CGImages there.
        return (contents as! CGImage)
    }

    /// Forgets every image, so the next sync redraws them.
    func invalidate() {
        drawnAs.removeAll()
        glyphs.removeAll()
        for layer in itemLayers.values { layer.contentsScale = art.scale }
    }

    func clear() {
        for layer in itemLayers.values { layer.removeFromSuperlayer() }
        pieces.forEach { $0.layer.removeFromSuperlayer() }
        sparks.forEach { $0.layer.removeFromSuperlayer() }
        rings.forEach { $0.layer.removeFromSuperlayer() }
        pops.forEach { $0.layer.removeFromSuperlayer() }
        itemLayers = [:]
        drawnAs = [:]
        lastSeen = [:]
        pieces = []
        sparks = []
        rings = []
        pops = []
    }

    // MARK: - Items

    /// Puts every item's layer where the rules say it is. Positions are kept
    /// measured down from the top, as the rules keep them, and flipped only
    /// when handed to a layer.
    func sync(_ game: FallingGame, height: CGFloat) {
        let targetID = game.target?.id
        var alive = Set<Int>()
        for item in game.items {
            alive.insert(item.id)
            lastSeen[item.id] = item
            let layer = itemLayers[item.id] ?? addItemLayer(item.id)
            let isTarget = item.id == targetID
            // The key just missed shows red for a moment, where practice would
            // leave the wrong letter red in the passage.
            let wrong = isTarget && game.clock - item.wrongAt < 0.3
            let key = "\(item.typed) \(item.gone.count) \(isTarget) \(wrong) \(art.signature)"
            if drawnAs[item.id] != key {
                layer.contents = art.image(of: item, mode: game.mode, target: isTarget, wrong: wrong)
                drawnAs[item.id] = key
            }
            let box = art.box(for: item)
            layer.frame = CGRect(
                x: CGFloat(item.x) - PlayArt.padX, y: height - CGFloat(item.y) - box.height,
                width: box.width, height: box.height)
        }
        for (id, layer) in itemLayers where !alive.contains(id) {
            layer.removeFromSuperlayer()
            itemLayers[id] = nil
            drawnAs[id] = nil
            lastSeen[id] = nil
        }
    }

    private func addItemLayer(_ id: Int) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = art.scale
        layer.contentsGravity = .resize
        world.addSublayer(layer)
        itemLayers[id] = layer
        return layer
    }

    private func glyph(_ character: String, mode: PlayMode, role: PlayArt.GlyphRole) -> CGImage? {
        let key = "\(character) \(mode.rawValue) \(role)"
        if let cached = glyphs[key] { return cached }
        let image = art.glyph(character, mode: mode, role: role)
        glyphs[key] = image
        return image
    }

    // MARK: - Effects

    /// A finished word flies apart: its own letters, sparks in the caret's
    /// colour, and a ring.
    func burst(_ id: Int, indices: [Int], mode: PlayMode) {
        guard let item = lastSeen[id], let first = indices.first, let last = indices.last else { return }
        let big: CGFloat = mode == .letters ? 1.6 : 1
        let cell = art.cell(mode)
        let size = CGSize(width: cell.width, height: cell.height)
        let accent = art.resolve(Theme.caret)
        let middle = CGFloat(first + last) / 2
        let y = CGFloat(item.y + item.size.height / 2)
        var xs: [CGFloat] = []
        for index in indices where item.chars[index] != " " {
            let x = CGFloat(item.x + cell.width * (Double(index) + 0.5))
            xs.append(x)
            guard let image = glyph(item.chars[index], mode: mode, role: .typed) else { continue }
            if reducesMotion {
                addPiece(image, size: size, x: x, y: y, vx: 0, vy: 0, spin: 0, span: 0.3, gravity: 0)
                continue
            }
            addPiece(
                image, size: size, x: x, y: y,
                vx: .random(in: -190...190) + (CGFloat(index) - middle) * 55,
                vy: -.random(in: 260...520) * big, spin: .random(in: -9...9),
                span: .random(in: 0.9...1.25), gravity: 1100)
            for _ in 0..<(mode == .sentences ? 8 : 12) {
                let angle = CGFloat.random(in: 0..<(2 * .pi))
                let speed = CGFloat.random(in: 140...460) * big
                addSpark(
                    x: x, y: y, vx: cos(angle) * speed, vy: sin(angle) * speed - 60,
                    size: .random(in: 3...5.5) * big, colour: accent,
                    span: .random(in: 0.45...0.9), gravity: 380)
            }
        }
        guard !xs.isEmpty, !reducesMotion else { return }
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.strokeColor = accent
        ring.zPosition = 1
        world.addSublayer(ring)
        rings.append(
            Ring(
                layer: ring, x: xs.reduce(0, +) / CGFloat(xs.count), y: y,
                from: CGFloat(cell.width) * 0.8,
                to: CGFloat(cell.width) * (2.2 + 0.5 * CGFloat(xs.count)), life: 0, span: 0.5))
    }

    /// An item that reached the floor under arcade rules: its letters drop
    /// away in the untyped colour. No red, and nothing louder than that.
    func crumble(_ id: Int, mode: PlayMode) {
        guard let item = lastSeen[id] else { return }
        let cell = art.cell(mode)
        for (index, character) in item.chars.enumerated()
        where character != " " && !item.gone.contains(index) {
            guard let image = glyph(character, mode: mode, role: .pending) else { continue }
            addPiece(
                image, size: CGSize(width: cell.width, height: cell.height),
                x: CGFloat(item.x + cell.width * (Double(index) + 0.5)),
                y: CGFloat(item.y + item.size.height / 2),
                vx: reducesMotion ? 0 : .random(in: -60...60),
                vy: reducesMotion ? 0 : -.random(in: 40...120),
                spin: reducesMotion ? 0 : .random(in: -2...2), span: reducesMotion ? 0.3 : 0.8,
                gravity: reducesMotion ? 0 : 900)
        }
    }

    /// The points a cleared item earned, rising from where it was, in the
    /// status bar's face and colour.
    func pop(_ id: Int, points: Int) {
        guard let item = lastSeen[id] else { return }
        let layer = CATextLayer()
        layer.string = "+\(points)"
        layer.font = art.popFont
        layer.fontSize = art.popFont.pointSize
        layer.foregroundColor = art.resolve(Theme.secondaryText)
        layer.alignmentMode = .center
        layer.contentsScale = art.scale
        layer.bounds = CGRect(x: 0, y: 0, width: 120, height: ceil(art.popFont.pointSize * 1.4))
        layer.zPosition = 3
        world.addSublayer(layer)
        pops.append(
            Pop(
                layer: layer, x: CGFloat(item.x + item.size.width / 2), y: max(CGFloat(item.y), 30),
                life: 0, span: 1.1))
    }

    /// A whole sentence done: sparks rise from the floor across the field.
    func shower(width: CGFloat, height: CGFloat) {
        guard !reducesMotion else { return }
        let accent = art.resolve(Theme.caret)
        for _ in 0..<70 {
            addSpark(
                x: .random(in: width * 0.1...width * 0.9), y: height,
                vx: .random(in: -80...80), vy: -.random(in: 380...720),
                size: .random(in: 3...6), colour: accent, span: .random(in: 1.0...1.6), gravity: 520)
        }
    }

    private func addPiece(
        _ image: CGImage, size: CGSize, x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat,
        spin: CGFloat, span: Double, gravity: CGFloat
    ) {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = art.scale
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.zPosition = 1
        world.addSublayer(layer)
        pieces.append(
            Piece(
                layer: layer, x: x, y: y, vx: vx, vy: vy, spin: spin, angle: 0, life: 0,
                span: span, gravity: gravity))
    }

    private func addSpark(
        x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, size: CGFloat, colour: CGColor,
        span: Double, gravity: CGFloat
    ) {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.backgroundColor = colour
        layer.zPosition = 2
        world.addSublayer(layer)
        sparks.append(
            Spark(layer: layer, x: x, y: y, vx: vx, vy: vy, life: 0, span: span, gravity: gravity))
    }

    /// Moves every effect one frame on.
    func step(_ dt: Double, height: CGFloat) {
        let t = CGFloat(dt)
        for index in pieces.indices {
            pieces[index].life += dt
            pieces[index].vy += pieces[index].gravity * t
            pieces[index].x += pieces[index].vx * t
            pieces[index].y += pieces[index].vy * t
            pieces[index].angle += pieces[index].spin * t
            let piece = pieces[index]
            let k = min(1, piece.life / piece.span)
            let shrink = reducesMotion ? 1 : 1 - 0.35 * CGFloat(k)
            piece.layer.position = CGPoint(x: piece.x, y: height - piece.y)
            piece.layer.setAffineTransform(
                CGAffineTransform(rotationAngle: piece.angle).scaledBy(x: shrink, y: shrink))
            let fadeFrom = reducesMotion ? 0 : 0.6
            piece.layer.opacity = Float(k > fadeFrom ? 1 - (k - fadeFrom) / (1 - fadeFrom) : 1)
        }
        pieces.removeAll { piece in
            let done = piece.life >= piece.span
            if done { piece.layer.removeFromSuperlayer() }
            return done
        }

        let drag = CGFloat(pow(0.06, dt))
        for index in sparks.indices {
            sparks[index].life += dt
            sparks[index].vx *= drag
            sparks[index].vy = sparks[index].vy * drag + sparks[index].gravity * t
            sparks[index].x += sparks[index].vx * t
            sparks[index].y += sparks[index].vy * t
            let spark = sparks[index]
            spark.layer.position = CGPoint(x: spark.x, y: height - spark.y)
            spark.layer.opacity = Float(1 - min(1, spark.life / spark.span))
        }
        sparks.removeAll { spark in
            let done = spark.life >= spark.span
            if done { spark.layer.removeFromSuperlayer() }
            return done
        }

        for index in rings.indices {
            rings[index].life += dt
            let ring = rings[index]
            let k = CGFloat(min(1, ring.life / ring.span))
            let radius = ring.from + (ring.to - ring.from) * (1 - pow(1 - k, 3))
            ring.layer.path = CGPath(
                ellipseIn: CGRect(
                    x: ring.x - radius, y: height - ring.y - radius, width: radius * 2,
                    height: radius * 2), transform: nil)
            ring.layer.lineWidth = 3 * (1 - k) + 0.5
            ring.layer.opacity = Float(0.8 * (1 - k))
        }
        rings.removeAll { ring in
            let done = ring.life >= ring.span
            if done { ring.layer.removeFromSuperlayer() }
            return done
        }

        for index in pops.indices {
            pops[index].life += dt
            let pop = pops[index]
            let k = CGFloat(min(1, pop.life / pop.span))
            let rise = reducesMotion ? 0 : 50 * (1 - pow(1 - k, 3))
            pop.layer.position = CGPoint(x: pop.x, y: height - (pop.y - rise))
            pop.layer.opacity = Float(k > 0.6 ? 1 - (k - 0.6) / 0.4 : 1)
        }
        pops.removeAll { pop in
            let done = pop.life >= pop.span
            if done { pop.layer.removeFromSuperlayer() }
            return done
        }
    }
}
