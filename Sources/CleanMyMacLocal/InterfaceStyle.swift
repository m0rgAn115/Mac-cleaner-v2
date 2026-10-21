import SwiftUI

// Native shapes and system colors keep the interface light and appearance-aware.
enum CleanerStyle {
    static let accent = Color(red: 0.12, green: 0.72, blue: 0.62)
    static let ink = Color(red: 0.07, green: 0.13, blue: 0.19)
    static let sidebar = Color(red: 0.055, green: 0.095, blue: 0.14)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let muted = Color(red: 0.66, green: 0.73, blue: 0.79)

    static func color(for section: String) -> Color {
        switch section {
        case "Correo": .blue
        case "Archivos y papeleras": .orange
        case "Aplicaciones": .purple
        case "Desarrollo": .indigo
        default: accent
        }
    }
}

struct CleanerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(enabled ? CleanerStyle.ink : Color.secondary)
            .background(enabled ? CleanerStyle.accent : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed && enabled ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CategorySymbol: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

struct StorageRing: View {
    let fraction: Double
    let hasResults: Bool
    let busy: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: 12)
            Circle().trim(from: 0, to: hasResults ? min(max(fraction, 0), 1) : 0.74)
                .stroke(AngularGradient(colors: [CleanerStyle.accent.opacity(0.35), CleanerStyle.accent], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 8) {
                Image(systemName: busy ? "magnifyingglass" : "internaldrive")
                    .font(.system(size: 34, weight: .light))
                Text(hasResults ? "SELECCIONADO" : "ALMACENAMIENTO")
                    .font(.system(size: 8, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(CleanerStyle.muted)
            }.foregroundStyle(.white)
        }
        .frame(width: 144, height: 144)
        .accessibilityHidden(true)
    }
}

struct CleanerStat: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CategorySymbol(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(CleanerStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
    }
}
