import SwiftUI

enum Brand {
    static let orange = Color(red: 1.0, green: 0.54, blue: 0.11)
    static let pink = Color(red: 1.0, green: 0.28, blue: 0.47)
    static let violet = Color(red: 0.59, green: 0.38, blue: 1.0)
    static let cyan = Color(red: 0.16, green: 0.83, blue: 0.94)
    static let gradient = LinearGradient(colors: [orange, pink, violet, cyan], startPoint: .leading, endPoint: .trailing)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

struct StatusBadge: View {
    enum Kind { case ok, pending, warning, error, info }

    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .ok: return .green
        case .pending: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .info: return .accentColor
        }
    }

    private var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .pending: return "circle.dotted"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if kind == .pending {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(0.35)))
    }
}

/// Title + body text block used at the top of each step.
struct StepHeader: View {
    let title: String
    let instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(instructions)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded "card" container.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

/// Label/value row for technical summaries.
struct InfoRow: View {
    let label: String
    let value: String
    var highlight: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value)
                .fontWeight(highlight == nil ? .regular : .semibold)
                .foregroundStyle(highlight ?? .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
