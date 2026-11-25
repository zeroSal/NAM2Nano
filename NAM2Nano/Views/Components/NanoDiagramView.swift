import SwiftUI

/// Schematic, animated vector drawing of the Nano Cortex used by steps 1-3.
/// Jack placement is illustrative (top-down view, rear panel on the top edge).
struct NanoDiagramView: View {

    enum CableState: Equatable { case idle, testing, ok, failed }

    enum Mode: Equatable {
        case usb(connected: Bool)
        case pairing(connected: Bool)
        case cabling(CableState)
    }

    let mode: Mode

    private enum Sym: Hashable { case laptop, hand, waves }

    // Design space
    private static let designSize = CGSize(width: 520, height: 300)
    private static let bodyRect = CGRect(x: 120, y: 112, width: 280, height: 160)
    private static let jacks: [(name: String, x: CGFloat)] = [
        ("USB-C", 145), ("INPUT 1", 195), ("OUT 1L", 245), ("OUT 2R", 290), ("CAPTURE IN", 345), ("HP", 385),
    ]
    private static let footswitches: [CGPoint] = [CGPoint(x: 205, y: 230), CGPoint(x: 315, y: 230)]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                var ctx = context
                let scale = min(size.width / Self.designSize.width, size.height / Self.designSize.height)
                ctx.translateBy(x: (size.width - Self.designSize.width * scale) / 2,
                                y: (size.height - Self.designSize.height * scale) / 2)
                ctx.scaleBy(x: scale, y: scale)
                draw(&ctx, t: t)
            } symbols: {
                Image(systemName: "laptopcomputer").font(.system(size: 64, weight: .light)).tag(Sym.laptop)
                Image(systemName: "hand.point.down.fill").font(.system(size: 22)).tag(Sym.hand)
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .semibold)).tag(Sym.waves)
            }
        }
        .aspectRatio(Self.designSize.width / Self.designSize.height, contentMode: .fit)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch mode {
        case .usb: return "Nano Cortex connected to the Mac over USB-C"
        case .pairing: return "Hold both footswitches for Bluetooth pairing"
        case .cabling: return "Jack cable from OUT 1L to CAPTURE IN"
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, t: Double) {
        drawUSBCable(&ctx, t: t)
        drawBody(&ctx, t: t)
        drawJacks(&ctx)
        drawFootswitches(&ctx, t: t)
        if case .cabling(let state) = mode { drawPatchCable(&ctx, state: state, t: t) }
    }

    private func drawBody(_ ctx: inout GraphicsContext, t: Double) {
        let b = Self.bodyRect
        let shape = Path(roundedRect: b, cornerRadius: 18, style: .continuous)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6))
            layer.fill(shape, with: .linearGradient(
                Gradient(colors: [Color(white: 0.30), Color(white: 0.16)]),
                startPoint: CGPoint(x: b.midX, y: b.minY), endPoint: CGPoint(x: b.midX, y: b.maxY)))
        }
        ctx.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: 1)

        ctx.draw(Text("NANO CORTEX").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundColor(.white.opacity(0.55)),
                 at: CGPoint(x: b.minX + 16, y: b.minY + 18), anchor: .leading)

        // Knobs
        for (i, x) in [175.0, 260.0, 345.0].enumerated() {
            let c = CGPoint(x: x, y: 165)
            let r: CGFloat = 15
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.45), Color(white: 0.2)]),
                                           startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
            let a = Angle.degrees(-130 + Double(i) * 55)
            var p = Path()
            p.move(to: c)
            let sn = CGFloat(sin(a.radians)), cs = CGFloat(cos(a.radians))
            p.addLine(to: CGPoint(x: c.x + sn * (r - 3), y: c.y - cs * (r - 3)))
            ctx.stroke(p, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Status LED
        let ledOn: Bool
        let ledColor: Color
        switch mode {
        case .usb(let connected): ledOn = connected || sin(t * 4) > 0; ledColor = connected ? .green : .orange
        case .pairing(let connected): ledOn = connected || sin(t * 8) > 0; ledColor = connected ? Brand.cyan : .blue
        case .cabling: ledOn = true; ledColor = .green
        }
        let led = CGRect(x: Self.bodyRect.maxX - 26, y: Self.bodyRect.minY + 13, width: 9, height: 9)
        if ledOn {
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 4))
                l.fill(Path(ellipseIn: led.insetBy(dx: -3, dy: -3)), with: .color(ledColor.opacity(0.8)))
            }
        }
        ctx.fill(Path(ellipseIn: led), with: .color(ledOn ? ledColor : Color(white: 0.35)))

        if case .pairing(let connected) = mode, let waves = ctx.resolveSymbol(id: Sym.waves) {
            var w = ctx
            w.opacity = connected ? 1 : 0.4 + 0.6 * abs(sin(t * 3))
            w.draw(waves, at: CGPoint(x: Self.bodyRect.maxX - 22, y: Self.bodyRect.minY + 42))
        }
    }

    private func isHighlighted(_ jack: String) -> Bool {
        switch mode {
        case .usb: return jack == "USB-C"
        case .pairing: return false
        case .cabling: return jack == "OUT 1L" || jack == "CAPTURE IN"
        }
    }

    private func drawJacks(_ ctx: inout GraphicsContext) {
        let top = Self.bodyRect.minY
        for jack in Self.jacks {
            let hi = isHighlighted(jack.name)
            let dim: Double = {
                if case .pairing = mode { return 0.6 }
                return hi ? 1 : 0.45
            }()
            let isUSB = jack.name == "USB-C"
            let socket = isUSB
                ? CGRect(x: jack.x - 9, y: top - 7, width: 18, height: 8)
                : CGRect(x: jack.x - 9, y: top - 10, width: 18, height: 11)
            ctx.fill(Path(roundedRect: socket, cornerRadius: isUSB ? 4 : 2), with: .color(Color(white: 0.55).opacity(dim)))
            if !isUSB {
                ctx.fill(Path(ellipseIn: CGRect(x: jack.x - 4, y: top - 8, width: 8, height: 8)), with: .color(.black.opacity(dim)))
            }
            if hi {
                ctx.stroke(Path(roundedRect: socket.insetBy(dx: -4, dy: -4), cornerRadius: 6),
                           with: .color(Brand.orange), lineWidth: 2)
            }
            ctx.draw(Text(jack.name).font(.system(size: 8.5, weight: hi ? .bold : .medium))
                        .foregroundColor(hi ? .primary : .secondary),
                     at: CGPoint(x: jack.x, y: top - 22), anchor: .center)
        }
    }

    private func drawFootswitches(_ ctx: inout GraphicsContext, t: Double) {
        let pairing: Bool
        let paired: Bool
        if case .pairing(let connected) = mode { pairing = true; paired = connected } else { pairing = false; paired = false }

        for (i, c) in Self.footswitches.enumerated() {
            if pairing && !paired {
                let pulse = 0.5 + 0.5 * sin(t * 4)
                let r = CGFloat(22 + 8 * pulse)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Brand.cyan.opacity(1 - pulse * 0.7)), lineWidth: 3)
            }
            let r: CGFloat = 18
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                     with: .color(Color(white: 0.12)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .radialGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.55)]),
                                           center: CGPoint(x: c.x - 5, y: c.y - 6), startRadius: 1, endRadius: r * 1.4))
            if pairing {
                if paired {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 6, y: c.y - r - 6, width: 2 * r + 12, height: 2 * r + 12)),
                               with: .color(.green), lineWidth: 2.5)
                } else if let hand = ctx.resolveSymbol(id: Sym.hand) {
                    let bob = 3 * sin(t * 4 + Double(i))
                    ctx.draw(hand, at: CGPoint(x: c.x, y: c.y - 38 + bob))
                }
            }
        }
        if pairing && !paired {
            ctx.draw(Text("HOLD BOTH").font(.system(size: 9, weight: .bold)).foregroundColor(Brand.cyan),
                     at: CGPoint(x: 260, y: Self.bodyRect.maxY + 14))
        }
    }

    private func drawUSBCable(_ ctx: inout GraphicsContext, t: Double) {
        let connected: Bool
        switch mode {
        case .usb(let c): connected = c
        default: connected = true
        }
        let emphasis: Double = { if case .usb = mode { return 1 } else { return 0.35 } }()

        if let laptop = ctx.resolveSymbol(id: Sym.laptop) {
            var l = ctx
            l.opacity = emphasis
            l.draw(laptop, at: CGPoint(x: 52, y: 214))
        }
        var cable = Path()
        cable.move(to: CGPoint(x: 86, y: 222))
        cable.addCurve(to: CGPoint(x: 145, y: Self.bodyRect.minY - 9),
                       control1: CGPoint(x: 128, y: 222),
                       control2: CGPoint(x: 145, y: 40))
        let color = connected ? Color.green : Color.secondary
        let style = connected
            ? StrokeStyle(lineWidth: 4, lineCap: .round)
            : StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 7], dashPhase: CGFloat(-t * 30))
        ctx.stroke(cable, with: .color(color.opacity(emphasis)), style: style)
    }

    private func drawPatchCable(_ ctx: inout GraphicsContext, state: CableState, t: Double) {
        let top = Self.bodyRect.minY - 10
        let start = CGPoint(x: 245, y: top - 12)
        let end = CGPoint(x: 345, y: top - 12)
        let c1 = CGPoint(x: 245, y: 10)
        let c2 = CGPoint(x: 345, y: 10)

        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)

        let color: Color
        switch state {
        case .idle, .testing: color = Brand.orange
        case .ok: color = .green
        case .failed: color = .red
        }
        ctx.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))

        // Plugs (TS): sleeve + tip into each jack
        for x in [CGFloat(245), CGFloat(345)] {
            ctx.fill(Path(roundedRect: CGRect(x: x - 7, y: top - 16, width: 14, height: 14), cornerRadius: 3),
                     with: .color(Color(white: 0.2)))
            ctx.fill(Path(CGRect(x: x - 3, y: top - 3, width: 6, height: 5)), with: .color(Color(white: 0.8)))
        }

        // Signal flow
        if state == .testing || state == .ok {
            for k in 0..<6 {
                var u = (t * 0.45 + Double(k) / 6).truncatingRemainder(dividingBy: 1)
                if u < 0 { u += 1 }
                let p = cubic(start, c1, c2, end, u)
                let r: CGFloat = 3.5
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(0.9)))
            }
        }

        let label: String
        switch state {
        case .idle: label = "short TS cable"
        case .testing: label = "pilot tone…"
        case .ok: label = "loop OK"
        case .failed: label = "no signal"
        }
        ctx.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(color),
                 at: CGPoint(x: 295, y: 44))
    }

    private func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ tt: Double) -> CGPoint {
        let t = CGFloat(tt)
        let mt: CGFloat = 1 - t
        let a: CGFloat = mt * mt * mt
        let b: CGFloat = 3 * mt * mt * t
        let c: CGFloat = 3 * mt * t * t
        let d: CGFloat = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}

#Preview {
    VStack {
        NanoDiagramView(mode: .usb(connected: false))
        NanoDiagramView(mode: .pairing(connected: false))
        NanoDiagramView(mode: .cabling(.testing))
    }
    .padding()
    .frame(width: 520, height: 900)
}
