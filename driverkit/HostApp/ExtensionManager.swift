//
//  ExtensionManager.swift — activate / deactivate the TouchDriverKit dext.
//
//  A .dext is never installed directly. It ships inside this host app's
//  Contents/Library/SystemExtensions/ and is activated at runtime via the
//  SystemExtensions framework. macOS then prompts the user to approve it in
//  System Settings > Privacy & Security (and, on first load, to allow the
//  developer in Login Items / System Extensions).
//
//  This object drives that lifecycle and reports status back to the UI.
//

import Foundation
import SystemExtensions
import os.log

/// Bundle identifier of the embedded driver extension. Must match the dext's
/// CFBundleIdentifier (see driverkit/TouchDriverKit/Info.plist).
private let kDextBundleID = "com.eriproject.touchdriver.driverkit"

private let log = Logger(subsystem: "com.eriproject.touchdriver.host",
                         category: "ExtensionManager")

@MainActor
final class ExtensionManager: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case activating
        case needsApproval          // user must approve in System Settings
        case activated
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    // MARK: Public API

    /// Request activation of the embedded dext. Safe to call repeatedly; macOS
    /// no-ops if it's already the active version.
    func activate() {
        log.info("Requesting activation of \(kDextBundleID, privacy: .public)")
        state = .activating
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: kDextBundleID,
            queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// Request deactivation (uninstall) of the dext.
    func deactivate() {
        log.info("Requesting deactivation of \(kDextBundleID, privacy: .public)")
        let req = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: kDextBundleID,
            queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension ExtensionManager: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        // Always move to the version bundled in this app (handles upgrades and
        // downgrades during development).
        log.info("Replacing dext \(existing.bundleVersion, privacy: .public) → \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.info("Dext needs user approval in System Settings")
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("Dext request finished: \(result.rawValue, privacy: .public)")
        Task { @MainActor in
            switch result {
            case .completed:
                self.state = .activated
            case .willCompleteAfterReboot:
                self.state = .needsApproval   // surfaces "reboot to finish"
            @unknown default:
                self.state = .failed("Unknown result \(result.rawValue)")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFailWithError error: Error) {
        let msg = (error as NSError).localizedDescription
        log.error("Dext request failed: \(msg, privacy: .public)")
        Task { @MainActor in self.state = .failed(msg) }
    }
}
