//
//  BluetoothGPSView.swift
//  ZLinks
//

import MapKit
import SwiftUI

struct BluetoothGPSSection: View {
    @ObservedObject var camera: CameraConnectionService
    @State private var isPresented = false

    var body: some View {
        Button {
            camera.openBluetoothGPSSession()
            isPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "mappin.and.ellipse.circle")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPS同步")
                        .font(.headline.weight(.semibold))
                    Text("蓝牙配对相机并进行定位同步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .fullScreenCover(isPresented: $isPresented, onDismiss: {
            camera.closeBluetoothGPSSession()
        }) {
            BluetoothGPSConnectionView(camera: camera)
        }
    }
}

private struct BluetoothGPSConnectionView: View {
    @ObservedObject var camera: CameraConnectionService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MapOffsetCorrectionMode.preferenceKey)
    private var mapOffsetCorrectionMode = MapOffsetCorrectionMode.automatic
    @AppStorage(MapLocationMarkerStyle.preferenceKey)
    private var mapLocationMarkerStyle = MapLocationMarkerStyle.accuracyCircle
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var coordinateFormat: CoordinateFormat = .degrees
    @State private var placeName: String?
    @State private var placeLookupFailed = false

    private var gps: NikonBluetoothGPSService { camera.bluetoothGPS }

    private enum CoordinateFormat {
        case degrees
        case degreesMinutes
        case degreesMinutesSeconds

        var next: CoordinateFormat {
            switch self {
            case .degrees: .degreesMinutes
            case .degreesMinutes: .degreesMinutesSeconds
            case .degreesMinutesSeconds: .degrees
            }
        }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "mappin.and.ellipse.circle.fill")
                        .font(.system(size: 62, weight: .medium))
                        .foregroundStyle(statusTint)
                        .padding(.top, 18)

                    Text("GPS 同步")
                        .font(.largeTitle.bold())

                    Text(gps.state.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusTint)

                    Text(gps.connectionStepDescription)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                        .padding(14)
                        .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if case .failed = gps.state {
                        Button {
                            gps.retry()
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                    }

                    if let location = gps.lastLocation {
                        locationSummary(location)
                    }

                    Map(position: $mapPosition) {
                        if let location = gps.lastLocation {
                            mapLocationContent(for: location)
                        }
                    }
                    .frame(minHeight: 260, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                    }

                    HStack(spacing: 12) {
                        Label("同步频率", systemImage: "timer")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Picker("同步频率", selection: Binding(
                            get: { gps.syncStrategy },
                            set: { gps.syncStrategy = $0 }
                        )) {
                            ForEach(NikonBluetoothGPSService.SyncStrategy.allCases) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(role: .destructive) {
                dismiss()
            } label: {
                Text("停止 GPS 同步")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color(red: 1.5, green: 1, blue: 1))
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .interactiveDismissDisabled()
        .onAppear { recenterMap() }
        .onChange(of: gps.lastLocation?.timestamp) { _, _ in recenterMap() }
        .onChange(of: mapOffsetCorrectionMode) { _, _ in recenterMap() }
        .onChange(of: mapLocationMarkerStyle) { _, _ in recenterMap() }
    }

    private func locationSummary(_ location: CLLocation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                coordinateFormat = coordinateFormat.next
            } label: {
                Text(formattedCoordinates(location.coordinate))
                    .font(.headline.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("坐标，\(coordinateFormatAccessibilityName)")
            .accessibilityHint("轻点切换坐标格式")
            Text(placeName ?? (placeLookupFailed ? "未能识别位置" : "定位中…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(String(format: "误差 %.1f 米", max(location.horizontalAccuracy, 0)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let date = gps.lastSyncDate {
                Text("上次同步 \(Self.dateFormatter.string(from: date))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: reverseGeocodingKey(for: location.coordinate)) {
            placeName = nil
            placeLookupFailed = false
            guard let name = await fetchPlaceName(for: location.coordinate) else {
                if !Task.isCancelled { placeLookupFailed = true }
                return
            }
            guard !Task.isCancelled else { return }
            placeName = name
        }
    }

    private func reverseGeocodingKey(for coordinate: CLLocationCoordinate2D) -> String {
        "\(Int((coordinate.latitude * 1000).rounded())),\(Int((coordinate.longitude * 1000).rounded()))"
    }

    private var coordinateFormatAccessibilityName: String {
        switch coordinateFormat {
        case .degrees: "度"
        case .degreesMinutes: "度分"
        case .degreesMinutesSeconds: "度分秒"
        }
    }

    private func formattedCoordinates(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(formattedCoordinate(coordinate.latitude, isLatitude: true))    \(formattedCoordinate(coordinate.longitude, isLatitude: false))"
    }

    private func formattedCoordinate(_ value: CLLocationDegrees, isLatitude: Bool) -> String {
        let absoluteValue = abs(value)
        let degrees = Int(absoluteValue)
        let hemisphere = isLatitude
            ? (value < 0 ? "S" : "N")
            : (value < 0 ? "W" : "E")

        switch coordinateFormat {
        case .degrees:
            return String(format: "%.5f°%@", locale: Locale(identifier: "en_US_POSIX"), absoluteValue, hemisphere)
        case .degreesMinutes:
            let minutes = (absoluteValue - Double(degrees)) * 60
            return String(format: "%d°%.4f′%@", locale: Locale(identifier: "en_US_POSIX"), degrees, minutes, hemisphere)
        case .degreesMinutesSeconds:
            let totalMinutes = (absoluteValue - Double(degrees)) * 60
            let minutes = Int(totalMinutes)
            let seconds = (totalMinutes - Double(minutes)) * 60
            return String(format: "%d°%d′%04.2f″%@", locale: Locale(identifier: "en_US_POSIX"), degrees, minutes, seconds, hemisphere)
        }
    }

    private func fetchPlaceName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let mapItems = try await request.mapItems
            guard let mapItem = mapItems.first else { return nil }
            let placemark = mapItem.placemark
            let components = [
                placemark.administrativeArea,
                placemark.locality,
                placemark.subAdministrativeArea ?? placemark.subLocality,
                mapItem.name ?? placemark.name
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { uniqueComponents, component in
                if !uniqueComponents.contains(where: { $0.localizedCaseInsensitiveCompare(component) == .orderedSame }) {
                    uniqueComponents.append(component)
                }
            }
            return components.isEmpty ? nil : components.joined(separator: " ")
        } catch {
            return nil
        }
    }

    private func recenterMap() {
        guard let location = gps.lastLocation else { return }
        let coordinate = mapCoordinate(for: location)
        withAnimation(.smooth(duration: 0.8)) {
            switch mapLocationMarkerStyle {
            case .pin:
                mapPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))
            case .accuracyCircle:
                mapPosition = .camera(
                    MapCamera(
                        centerCoordinate: coordinate,
                        distance: mapDistance(for: location)
                    )
                )
            }
        }
    }

    private func mapDistance(for location: CLLocation) -> CLLocationDistance {
        let accuracy = mapAccuracy(for: location)
        let logAccuracy = log10(accuracy)
        let weight = 1 / (1 + exp(-4 * (logAccuracy - 3)))
        let distance = (1 - weight) * (2000 * logAccuracy - 1000)
            + weight * (5 * accuracy)
        return max(distance, 1000)
    }

    private func mapAccuracy(for location: CLLocation) -> CLLocationDistance {
        max(location.horizontalAccuracy, 1)
    }

    private func mapCoordinate(for location: CLLocation) -> CLLocationCoordinate2D {
        MapCoordinateCorrection.coordinateForMap(
            location.coordinate,
            mode: mapOffsetCorrectionMode
        )
    }

    @MapContentBuilder
    private func mapLocationContent(for location: CLLocation) -> some MapContent {
        let coordinate = mapCoordinate(for: location)
        switch mapLocationMarkerStyle {
        case .pin:
            Marker("当前位置", coordinate: coordinate)
                .tint(.cyan)
        case .accuracyCircle:
            MapCircle(
                center: coordinate,
                radius: mapAccuracy(for: location)
            )
            .foregroundStyle(.blue.opacity(0.22))
            .stroke(.blue, lineWidth: 2)
        }
    }

    private var statusTint: Color {
        switch gps.state {
        case .ready: return .green
        case .failed: return .red
        case .unavailable: return .orange
        case .idle: return .secondary
        case .scanning, .connecting, .pairing, .reconnecting: return .blue
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
