import SwiftUI

/// Horizontal segmented level meter with peak hold.
///
/// Two scales: dBFS (Mac side, -60...0) and the Nano's raw capture meters (0...255,
/// red above 240 as in Cortex Cloud).
struct LevelMeterView: View {
    enum Scale {
        case dbfs
        case nanoRaw

        func fraction(_ v: Float) -> Double {
            switch self {
            case .dbfs: return Double(max(0, min(1, (v + 60) / 60)))
            case .nanoRaw: return Double(max(0, min(1, v / 255)))
            }
        }

        /// (yellow start, red start) as fractions.
        var zones: (Double, Double) {
            switch self {
            case .dbfs: return (fraction(-12), fraction(-3))
            case .nanoRaw: return (200.0 / 255, 240.0 / 255)
            }
        }

        func text(_ v: Float) -> String {
            switch self {
            case .dbfs: return v <= -119 ? "−∞" : String(format: "%.1f dBFS", v)
            case .nanoRaw: return "\(Int(v))/255"
            }
        }
    }

    let title: String
    let value: Float
    var scale: Scale = .dbfs

    @State private var peak: Float = -120
    @State private var peakDate = Date.distantPast

    // Explicit: the private @State properties would make the memberwise init private.
    init(title: String, value: Float, scale: Scale = .dbfs) {
        self.title = title
        self.value = value
        self.scale = scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(scale.text(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let (yellow, red) = scale.zones
                let f = scale.fraction(value)
                let pf = scale.fraction(peak)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    // Coloured bar, masked to the current level.
                    HStack(spacing: 0) {
                        Rectangle().fill(.green).frame(width: w * yellow)
                        Rectangle().fill(.yellow).frame(width: w * (red - yellow))
                        Rectangle().fill(.red)
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: w * f) }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    // Segment grid
                    HStack(spacing: 0) {
                        ForEach(0..<30, id: \.self) { _ in
                            Color.clear.overlay(alignment: .trailing) {
                                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.7)).frame(width: 1)
                            }
                        }
                    }
                    Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 2).offset(x: max(0, w * pf - 2))
                        .opacity(pf > 0.001 ? 1 : 0)
                }
            }
            .frame(height: 10)
        }
        .onChange(of: value) { _, newValue in
            let now = Date()
            if newValue >= peak || now.timeIntervalSince(peakDate) > 1.5 {
                peak = newValue
                peakDate = now
            }
        }
    }
}

extension LevelMeterView {
    init(title: String, nanoRaw: Int) {
        self.init(title: title, value: Float(nanoRaw), scale: .nanoRaw)
    }
}
