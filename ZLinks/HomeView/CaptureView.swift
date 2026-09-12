//
//  CaptureView.swift
//  ZLinks
//

import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var camera: CameraConnectionService

    var body: some View {
        VStack(spacing: 0) {
            liveViewPanel
            Spacer(minLength: 0)
        }
        .background(Color(.systemBackground))
        .task(id: liveViewSessionKey) {
            await camera.startLiveView()
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            } onCancel: {
                Task { @MainActor in
                    await camera.stopLiveView()
                }
            }
            await camera.stopLiveView()
        }
    }

    private var liveViewSessionKey: String {
        switch camera.state {
        case .connected:
            return "connected:\(camera.connectedHost ?? "")"
        case .connecting:
            return "connecting"
        case .failed(let message):
            return "failed:\(message)"
        case .disconnected:
            return "disconnected"
        }
    }

    private var liveViewPanel: some View {
        ZStack {
            Color.black

            if let image = camera.liveViewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                liveViewPlaceholder
            }

            VStack {
                HStack {
                    liveViewBadge
                    Spacer()
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipped()
    }

    private var liveViewPlaceholder: some View {
        VStack(spacing: 10) {
            if case .connecting = camera.state {
                ProgressView()
                    .tint(.white)
                Text("正在连接相机…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            } else if case .connected = camera.state {
                if camera.isLiveViewActive {
                    ProgressView()
                        .tint(.white)
                    Text("正在获取实时画面…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                } else if let liveViewError = camera.liveViewError {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(liveViewError)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 24)
                } else {
                    ProgressView()
                        .tint(.white)
                    Text("准备实时图传…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Image(systemName: "camera.metering.none")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
                Text("连接相机后显示实时画面")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveViewBadge: some View {
        let title: String
        let color: Color
        switch camera.state {
        case .connected where camera.liveViewImage != nil:
            title = "实时"
            color = .green
        case .connected where camera.isLiveViewActive:
            title = "启动中"
            color = .yellow
        case .connected:
            title = camera.liveViewError == nil ? "等待图传" : "不可用"
            color = camera.liveViewError == nil ? .yellow : .orange
        case .connecting:
            title = "连接中"
            color = .yellow
        default:
            title = "未连接"
            color = .gray
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

#Preview {
    CaptureView()
        .environmentObject(CameraConnectionService())
}
