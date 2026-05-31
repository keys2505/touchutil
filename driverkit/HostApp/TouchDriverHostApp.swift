//
//  TouchDriverHostApp.swift — minimal SwiftUI host app for the dext.
//
//  Its only job is to embed the TouchDriverKit dext and let the user
//  activate / deactivate it. Once the dext is approved and running, the
//  driver works on its own; this app does not need to stay open.
//

import SwiftUI

@main
struct TouchDriverHostApp: App {
    @StateObject private var manager = ExtensionManager()

    var body: some Scene {
        WindowGroup("TouchDriver") {
            ContentView()
                .environmentObject(manager)
                .frame(width: 420, height: 260)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject private var manager: ExtensionManager

    var body: some View {
        VStack(spacing: 16) {
            Text("TouchDriver multi-touch extension")
                .font(.headline)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Install / Activate") { manager.activate() }
                    .keyboardShortcut(.defaultAction)
                Button("Uninstall") { manager.deactivate() }
            }

            if case .needsApproval = manager.state {
                Button("Open System Settings → Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(24)
    }

    private var statusText: String {
        switch manager.state {
        case .idle:          return "Click Install to load the driver extension."
        case .activating:    return "Activating…"
        case .needsApproval: return "Approve “TouchDriverKit” in System Settings → Privacy & Security, then it will finish loading."
        case .activated:     return "✅ Driver extension active. Multi-touch enabled."
        case .failed(let m): return "❌ Failed: \(m)"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .activated:  return .green
        case .failed:     return .red
        case .needsApproval: return .orange
        default:          return .secondary
        }
    }
}
