import SwiftUI

// MARK: - Liquid Glass (iOS 26) with a material fallback for older systems

extension View {
    /// Liquid Glass on iOS 26+, ultra-thin material before.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.legacyGlass(in: shape, tint: tint)
        }
        #else
        self.legacyGlass(in: shape, tint: tint)
        #endif
    }

    func glassCard(cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        glass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(in: Capsule(), tint: tint, interactive: interactive)
    }

    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background((tint ?? .white).opacity(tint == nil ? 0.04 : 0.18), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    fileprivate static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.35)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif
}

// MARK: - Animated background

struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.09)
            Circle()
                .fill(Color(red: 0.45, green: 0.3, blue: 1.0))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: animate ? -120 : -40, y: animate ? -260 : -180)
            Circle()
                .fill(Color(red: 1.0, green: 0.3, blue: 0.5))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: animate ? 140 : 60, y: animate ? 40 : 160)
            Circle()
                .fill(Color(red: 0.2, green: 0.7, blue: 1.0))
                .frame(width: 320, height: 320)
                .blur(radius: 110)
                .offset(x: animate ? -60 : 80, y: animate ? 360 : 260)
        }
        .opacity(0.9)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

// MARK: - Small components

struct RingGauge: View {
    let value: Double
    let color: Color
    let symbol: String
    let label: String
    let caption: String
    var size: CGFloat = 64

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: size * 0.1)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, value)))
                    .stroke(AngularGradient(colors: [color.opacity(0.5), color], center: .center),
                            style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
                Image(systemName: symbol).font(.system(size: size * 0.26, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: rect.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: rect.height * (1 - CGFloat(min(max(v, 0), 1))))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

struct PulseDot: View {
    let color: Color
    var active = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.4)).frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.4 : 0.6).opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 9, height: 9).shadow(color: color, radius: 4)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

extension Double {
    var bytesText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }
}
