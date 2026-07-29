//
//  LaunchAtLoginService.swift
//  Docky
//

import Foundation
import ServiceManagement

struct LaunchAtLoginBackend {
    let observedStatus: () -> LaunchAtLoginObservedStatus
    let register: () throws -> Void
    let unregister: () throws -> Void

    static let live = LaunchAtLoginBackend(
        observedStatus: {
            switch SMAppService.mainApp.status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notFound, .notRegistered:
                return .disabled
            @unknown default:
                return .unavailable
            }
        },
        register: {
            try SMAppService.mainApp.register()
        },
        unregister: {
            try SMAppService.mainApp.unregister()
        }
    )
}

final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private let backend: LaunchAtLoginBackend

    var observedStatus: LaunchAtLoginObservedStatus {
        backend.observedStatus()
    }

    var isEnabled: Bool {
        switch observedStatus {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    var requiresApproval: Bool {
        observedStatus == .requiresApproval
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginMutationResult {
        var mutationErrorDescription: String?

        do {
            if enabled {
                switch observedStatus {
                case .enabled:
                    return .enabled
                case .requiresApproval:
                    return .requiresApproval
                case .disabled:
                    try backend.register()
                case .unavailable:
                    break
                }
            } else {
                switch observedStatus {
                case .disabled:
                    return .disabled
                case .enabled, .requiresApproval:
                    try backend.unregister()
                case .unavailable:
                    break
                }
            }
        } catch {
            mutationErrorDescription = error.localizedDescription
            NSLog(
                "[Docky] Login item request threw before verification: "
                    + error.localizedDescription
            )
        }

        return LaunchAtLoginMutationVerificationPolicy.result(
            requestedValue: enabled,
            observedStatus: observedStatus,
            mutationErrorDescription: mutationErrorDescription
        )
    }

    init(backend: LaunchAtLoginBackend = .live) {
        self.backend = backend
    }
}
