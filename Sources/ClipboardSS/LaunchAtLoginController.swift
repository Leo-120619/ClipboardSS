import Foundation
import ServiceManagement

protocol LaunchAtLoginControlling: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

final class LaunchAtLoginController: LaunchAtLoginControlling {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isEnabled != enabled else { return }

        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
