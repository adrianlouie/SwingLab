import SwiftUI

/// A quick, scannable summary of every measured metric, grouped by
/// `MetricCategory` — "In Zone" or a signed "Over/Under by X" badge per
/// (metric, position). Sits ABOVE the existing detailed `metricsSection`
/// (`MetricCard`/`GaugeBar`, which already show the measured value, ideal
/// range, and a gauge) rather than replacing it — this is the fast at-a-
/// glance pass, the cards below are the drill-down, and both read the same
/// `MetricResult`s so they can never disagree.
///
/// Direction wording is deliberately generic ("Over"/"Under by X°") rather
/// than metric-specific ("Up by One", "Forward by Two") — several metrics
/// here (rotation especially) don't have an honest, unambiguous direction
/// word the way lateral drift might, and guessing wrong would be actively
/// misleading. `MetricResult.delta`'s sign already carries the real
/// information (which side of the ideal range) without inventing vocabulary
/// this app can't back up.
struct MetricChecklistView: View {
    let metrics: [MetricResult]

    private var groupedByCategory: [(category: MetricCategory, metrics: [MetricResult])] {
        MetricCategory.allCases.compactMap { category in
            let matching = metrics.filter { $0.kind.category == category }
                .sorted { a, b in
                    a.kind != b.kind ? a.kind.rawValue < b.kind.rawValue : a.position.rawValue < b.position.rawValue
                }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    var body: some View {
        if !metrics.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Checklist")
                    .font(.headline)
                ForEach(groupedByCategory, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.category.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(group.metrics) { metric in
                                MetricChecklistRow(metric: metric)
                                if metric.id != group.metrics.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetricChecklistRow: View {
    let metric: MetricResult

    private var isGood: Bool { metric.status == .good }

    private var statusText: String {
        guard !isGood else { return "In Zone" }
        let magnitude = String(format: "%.1f", abs(metric.delta))
        let word = metric.delta < 0 ? "Under" : "Over"
        return "\(word) by \(magnitude)\(metric.kind.unit)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(isGood ? Theme.good : Theme.amber)
            Text("\(metric.kind.rawValue) — \(metric.position.shortLabel)")
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(statusText)
                .font(.caption.bold())
                .foregroundStyle(isGood ? Theme.good : Theme.amber)
        }
        .padding(.vertical, 9)
        .accessibilityIdentifier("checklistRow.\(metric.kind.rawValue).\(metric.position.rawValue)")
    }
}
