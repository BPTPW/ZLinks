//
//  CameraDiscoveryService.swift
//  ZLinks
//

import Combine
import Darwin
import Foundation
import Network

@MainActor
final class CameraDiscoveryService: ObservableObject {
    struct Camera: Identifiable {
        let host: String

        var id: String { host }
        var name: String { host }
        var endpoint: NWEndpoint { .hostPort(host: .init(host), port: 15740) }
    }

    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var isSearching = false
    @Published private(set) var statusMessage = "准备扫描当前 Wi-Fi 网络"

    private var scanTask: Task<Void, Never>?

    func start() {
        stop()
        guard let subnet = Self.currentWiFiSubnet() else {
            statusMessage = "未检测到 Wi-Fi 网络"
            return
        }

        isSearching = true
        statusMessage = "正在扫描 \(subnet).0/24 网络"
        scanTask = Task { [weak self] in
            let hosts = (1 ... 254).map { "\(subnet).\($0)" }
            let foundHosts = await Self.findPTPIPHosts(in: hosts)
            guard !Task.isCancelled else { return }
            self?.cameras = foundHosts.map(Camera.init(host:))
            self?.isSearching = false
            self?.statusMessage = foundHosts.isEmpty
                ? "未发现相机，请确认相机已开启 Wi-Fi 与 PTP/IP。"
                : "已发现 \(foundHosts.count) 台可连接相机"
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isSearching = false
        cameras = []
    }

    private nonisolated static func currentWiFiSubnet() -> String? {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return nil
        }
        defer { freeifaddrs(interfaceAddresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let name = String(cString: interface.pointee.ifa_name)
            guard ["en0", "bridge100", "ap1"].contains(name),
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET)
            else {
                continue
            }

            var ipv4Address = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4Address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let addressString = String(cString: buffer)
            let parts = addressString.split(separator: ".")
            guard parts.count == 4 else { continue }
            return parts.prefix(3).joined(separator: ".")
        }
        return nil
    }

    private nonisolated static func findPTPIPHosts(in hosts: [String]) async -> [String] {
        var matches: [String] = []
        let batchSize = 24

        for startIndex in stride(from: 0, to: hosts.count, by: batchSize) {
            if Task.isCancelled { break }
            let endIndex = min(startIndex + batchSize, hosts.count)
            let batch = hosts[startIndex ..< endIndex]
            let batchMatches = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for host in batch {
                    group.addTask {
                        await isPTPIPPortOpen(host: host) ? host : nil
                    }
                }

                var found: [String] = []
                for await host in group {
                    if let host {
                        found.append(host)
                    }
                }
                return found
            }
            matches.append(contentsOf: batchMatches)
        }
        return matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private nonisolated func isPTPIPPortOpen(host: String) async -> Bool {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: .init(host), port: 15740, using: .tcp)
        let completion = PortProbeCompletion(connection: connection, continuation: continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                completion.finish(true)
            case .failed, .cancelled:
                completion.finish(false)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
            completion.finish(false)
        }
    }
}

private final nonisolated class PortProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
