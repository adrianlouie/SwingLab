import SwiftUI
import SwiftData
import Charts

/// Trend charts over the whole library: overall score plus any single
/// metric, filterable by shot type.
struct ProgressTrendsView: View {
    @Query(sort: \SwingRecord.date) private var swings: [SwingRecord]

    @State private var shotFilter: ShotType = .fullSwing
    @State private var metricFilter: MetricKind = .xFactor

    private var filtered: [SwingRecord] {
        swings.filter { $0.shotType == shotFilter }
    }

    /// (date, value) pairs for the selected metric, averaged when a metric
    /// appears at more than one position.
    private var metricSeries: [(date: Date, value: Double)] {
        filtered.compactMap { swing in
            guard let metrics = swing.analysis?.metrics.filter({ $0.kind == metricFilter }),
                  !metrics.isEmpty else { return nil }
            let mean = metrics.map(\.measured).reduce(0, +) / Double(metrics.count)
            return (swing.date, mean)
        }
    }

    private var idealBand: (low: Double, high: Double)? {
        let targets = filtered.compactMap { swing -> MetricResult? in
            swing.analysis?.metrics.first { $0.kind == metricFilter }
        }
        guard let first = targets.first else { return nil }
        return (first.idealLow, first.idealHigh)
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.count < 2 {
                    ContentUnavailableView {
                        Label("Not enough swings", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Analyze at least two \(shotFilter.rawValue.lowercased()) swings and your trends will appear here.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Shot", selection: $shotFilter) {
                        ForEach(ShotType.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
        }
    }

    private var content: some View {
        List {
            Section("Overall Score") {
                Chart(filtered) { swing in
                    LineMark(x: .value("Date", swing.date),
                             y: .value("Score", swing.overallScore))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.fairway)
                    PointMark(x: .value("Date", swing.date),
                              y: .value("Score", swing.overallScore))
                    .foregroundStyle(Theme.scoreColor(swing.overallScore))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 200)
                .padding(.vertical, 6)

                summaryRow
            }

            Section("Metric Trend") {
                Picker("Metric", selection: $metricFilter) {
                    ForEach(MetricKind.allCases) { Text($0.rawValue).tag($0) }
                }

                if metricSeries.count >= 2 {
                    Chart {
                        if let band = idealBand {
                            RectangleMark(yStart: .value("Ideal low", band.low),
                                          yEnd: .value("Ideal high", band.high))
                            .foregroundStyle(Theme.good.opacity(0.15))
                        }
                        ForEach(metricSeries, id: \.date) { point in
                            LineMark(x: .value("Date", point.date),
                                     y: .value(metricFilter.rawValue, point.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.fairway)
                            PointMark(x: .value("Date", point.date),
                                      y: .value(metricFilter.rawValue, point.value))
                            .foregroundStyle(Theme.lime)
                        }
                    }
                    .frame(height: 200)
                    .padding(.vertical, 6)

                    Text(metricFilter.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No \(metricFilter.rawValue.lowercased()) measurements recorded for this shot type yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summaryRow: some View {
        let scores = filtered.map(\.overallScore)
        let best = scores.max() ?? 0
        let average = scores.reduce(0, +) / Double(max(scores.count, 1))
        let recent = Array(scores.suffix(3))
        let recentAverage = recent.reduce(0, +) / Double(max(recent.count, 1))

        return HStack {
            statTile(title: "Swings", value: "\(filtered.count)")
            Divider()
            statTile(title: "Best", value: "\(Int(best))")
            Divider()
            statTile(title: "Average", value: "\(Int(average))")
            Divider()
            statTile(title: "Last 3", value: "\(Int(recentAverage))")
        }
        .frame(maxWidth: .infinity)
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
