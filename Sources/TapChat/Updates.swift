import AppKit
import Sparkle
import SwiftUI

// Updates, as in Fandy: Sparkle checks the signed appcast on the repository's
// `updates` branch, downloads in the background when automatic updates are on,
// and asks once before installing.

enum UpdateFrequency: String, CaseIterable, Identifiable {
    case daily, weekly, monthly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var interval: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_592_000
        }
    }
}

struct UpdatePolicy: Equatable {
    // A downloaded update not installed yet: asked again after two weeks.
    static let reminderInterval: TimeInterval = 1_209_600
    var automatic = Settings.automaticUpdates
    var frequency = Settings.updateFrequency
}

/// Keep Sparkle's offer and progress UI; an accepted update needs no second confirmation.
final class AcceptedUpdateDriver: SPUStandardUserDriver {
    var acceptedInstallation = false
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if acceptedInstallation { reply(.install) } else { super.showReady(toInstallAndRelaunch: reply) }
    }
    override func dismissUpdateInstallation() {
        acceptedInstallation = false
        super.dismissUpdateInstallation()
    }
}

@Observable final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private var driver: AcceptedUpdateDriver!
    @ObservationIgnored private var installDownloaded: (() -> Void)?
    @ObservationIgnored private var reminderAt: Date?
    @ObservationIgnored private var appliedPolicy: UpdatePolicy?
    private(set) var installationPending = false
    private(set) var status = ""
    private(set) var canCheck = false

    override init() {
        super.init()
        driver = AcceptedUpdateDriver(hostBundle: .main, delegate: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        synchronize()
        do { try updater.start() } catch { status = "Updates unavailable. Please reinstall the latest release." }
        synchronize()
    }

    func synchronize() {
        let policy = UpdatePolicy()
        if appliedPolicy != policy {
            updater.updateCheckInterval = policy.frequency.interval
            updater.automaticallyDownloadsUpdates = policy.automatic
            updater.automaticallyChecksForUpdates = policy.automatic
            updater.sendsSystemProfile = false
            appliedPolicy = policy
        }
        canCheck = updater.canCheckForUpdates || installationPending
        if policy.automatic, let reminderAt, Date() >= reminderAt, canCheck {
            self.reminderAt = Date().addingTimeInterval(UpdatePolicy.reminderInterval)
            presentPendingUpdate()
        }
    }

    func check() {
        guard canCheck else { return }
        if installationPending { presentPendingUpdate() } else { updater.checkForUpdates() }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installationPending = true
        installDownloaded = immediateInstallationBlock
        reminderAt = Date().addingTimeInterval(UpdatePolicy.reminderInterval)
        status = "Update downloaded. Ready to install."
        return true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .install { driver.acceptedInstallation = true }
        if choice == .skip { clearPending(); status = "Update skipped" }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        clearPending()
        status = "Update check failed. Try again later."
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue {
            status = "Update check failed. Try again later."
        } else if !installationPending {
            status = "Up to date"
        }
        synchronize()
    }

    private func presentPendingUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A TapChat update is ready to install"
        alert.informativeText = "Install the downloaded update and restart TapChat now?"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installNow() }
    }

    func installNow() { installDownloaded?() }

    private func clearPending() {
        installationPending = false
        installDownloaded = nil
        reminderAt = nil
        driver.acceptedInstallation = false
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverWillShowModalAlert() { NSApp.activate(ignoringOtherApps: true) }
}

struct UpdateSettings: View {
    @State private var updates = UpdateController.shared
    @State private var automatic = Settings.automaticUpdates
    @State private var frequency = Settings.updateFrequency

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Toggle("Automatic updates", isOn: $automatic)
                .onChange(of: automatic) { Settings.automaticUpdates = automatic; updates.synchronize() }
            Picker("Check frequency", selection: $frequency) {
                ForEach(UpdateFrequency.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: frequency) { Settings.updateFrequency = frequency; updates.synchronize() }
            .disabled(!automatic)
            Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            if updates.installationPending { Button("Install Update") { updates.installNow() } }
            if !updates.status.isEmpty { Text(updates.status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
