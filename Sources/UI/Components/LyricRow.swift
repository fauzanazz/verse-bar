import SwiftUI

struct LyricRow: View {
    let line: LyricLine
    let isActive: Bool
    var scale: CGFloat = 1
    @ObservedObject private var settings = AppSettings.shared

    private var hasRomanized: Bool {
        settings.showRomanization && line.romanized != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasRomanized ? 2 : 0) {
            Text(line.text)
                .font(.system(size: (isActive ? 16 : 14) * scale, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundColor(isActive ? .accentColor : .primary)
                .opacity(isActive ? 1.0 : 0.5)

            if hasRomanized, let romanized = line.romanized {
                Text(romanized)
                    .font(.system(size: (isActive ? 12 : 11) * scale, weight: .regular, design: .rounded))
                    .foregroundColor(isActive ? .accentColor.opacity(0.85) : .secondary)
                    .opacity(isActive ? 0.9 : 0.45)
            }
        }
        .padding(.vertical, (hasRomanized ? 6 : 2) * scale)
        .padding(.horizontal, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ?
            Color.accentColor.opacity(0.12)
                .cornerRadius(8)
            : Color.clear.cornerRadius(0)
        )
        .scaleEffect(isActive ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
    }
}
