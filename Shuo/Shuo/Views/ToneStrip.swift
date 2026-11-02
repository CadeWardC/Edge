import SwiftUI

/// One chip per syllable of the learner's sentence, colored by the tone check.
struct ToneStrip: View {
    let checks: [ToneCheck]

    private var judged: Int { checks.filter { $0.verdict == .good || $0.isWrong }.count }
    private var right: Int { checks.filter { $0.verdict == .good }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Tones", systemImage: "waveform.path")
                    .font(.caption.bold())
                if judged > 0 {
                    Text("\(right) of \(judged) right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("rough guide")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            FlowLayout(spacing: 6) {
                ForEach(checks) { ToneChip(check: $0) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ToneChip: View {
    let check: ToneCheck

    var body: some View {
        VStack(spacing: 1) {
            Text(check.syllable.spokenMarked)
                .font(.caption2)
            Text(check.syllable.character)
                .font(.title3)
            if case .wrong(let heard) = check.verdict {
                Text("sounded \(ToneCheck.toneName(heard).replacingOccurrences(of: " tone", with: ""))")
                    .font(.system(size: 9))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var color: Color {
        switch check.verdict {
        case .good: return .green
        case .wrong: return .red
        case .unclear, .notJudged: return .secondary
        }
    }

    private var accessibilityText: String {
        let s = check.syllable
        switch check.verdict {
        case .good: return "\(s.character), \(s.spokenMarked), correct"
        case .wrong(let heard):
            return "\(s.character), expected \(ToneCheck.toneName(s.spokenTone)), sounded like \(ToneCheck.toneName(heard))"
        case .unclear: return "\(s.character), \(s.spokenMarked), unclear"
        case .notJudged: return "\(s.character), neutral tone"
        }
    }
}

extension ToneCheck {
    var isWrong: Bool {
        if case .wrong = verdict { return true }
        return false
    }
}

/// Lays out children left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
