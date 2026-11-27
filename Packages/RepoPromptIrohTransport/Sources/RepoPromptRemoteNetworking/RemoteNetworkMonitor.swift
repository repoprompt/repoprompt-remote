import Foundation
import Network

public final class RemoteNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.repoprompt.remote.network-monitor")
    private let onChange: @MainActor (NWPath.Status, String) -> Void

    public init(onChange: @escaping @MainActor (NWPath.Status, String) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        monitor.pathUpdateHandler = { [onChange] path in
            let interface: String
            if path.usesInterfaceType(.wifi) {
                interface = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                interface = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                interface = "wiredEthernet"
            } else {
                interface = path.availableInterfaces.first.map { String(describing: $0.type) } ?? "unknown"
            }
            Task { @MainActor in
                onChange(path.status, interface)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
