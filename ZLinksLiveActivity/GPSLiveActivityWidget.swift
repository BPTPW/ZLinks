//
//  GPSLiveActivityWidget.swift
//  ZLinksLiveActivity
//

import ActivityKit
import SwiftUI
import WidgetKit

struct GPSLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GPSLiveActivityAttributes.self) { context in
            LockScreenGPSView(context: context)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusView(context.state, compact: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.syncStrategy)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 20) {
                        activityMetric(
                            title: "上次同步",
                            value: syncTime(context.state.lastSyncDate),
                            icon: "clock"
                        )
                        activityMetric(
                            title: "坐标",
                            value: coordinate(context.state),
                            icon: "location.fill"
                        )
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: statusSymbol(context.state.connectionStatus))
                    .foregroundStyle(statusColor(context.state.connectionStatus))
            } compactTrailing: {
                Text(context.state.syncStrategy)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(statusColor(context.state.connectionStatus))
            }
            .keylineTint(.cyan)
        }
    }

    private func statusView(
        _ state: GPSLiveActivityAttributes.ContentState,
        compact: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol(state.connectionStatus))
            Text(state.connectionStatus)
                .lineLimit(1)
        }
        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(statusColor(state.connectionStatus))
    }

    private func activityMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "连接成功": return "checkmark.circle.fill"
        case "连接失败": return "exclamationmark.triangle.fill"
        case "蓝牙不可用": return "antenna.radiowaves.left.and.right.slash"
        case "未连接": return "circle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "连接成功": return .green
        case "连接失败": return .red
        case "蓝牙不可用": return .orange
        case "未连接": return .secondary
        default: return .cyan
        }
    }

    private func syncTime(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func coordinate(_ state: GPSLiveActivityAttributes.ContentState) -> String {
        guard let latitude = state.latitude, let longitude = state.longitude else {
            return "等待首次同步"
        }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

private struct LockScreenGPSView: View {
    let context: ActivityViewContext<GPSLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "location.fill.viewfinder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.sessionTitle)
                        .font(.headline)
                    Text(context.state.connectionStatus)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 8)

                Text(context.state.syncStrategy)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.cyan.opacity(0.14), in: Capsule())
            }

            Divider()

            HStack(spacing: 16) {
                metric(
                    title: "上次同步",
                    value: context.state.lastSyncDate?.formatted(date: .omitted, time: .standard) ?? "尚未同步"
                )
                metric(title: "坐标", value: coordinate)
            }
        }
        .padding(16)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coordinate: String {
        guard let latitude = context.state.latitude,
              let longitude = context.state.longitude
        else { return "等待首次同步" }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    private var statusColor: Color {
        switch context.state.connectionStatus {
        case "连接成功": return .green
        case "连接失败": return .red
        case "蓝牙不可用": return .orange
        case "未连接": return .secondary
        default: return .cyan
        }
    }
}
