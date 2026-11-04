import AppKit
import RoastierKit
import ServiceManagement

/// Assertions need no terminate hook: powerd releases them when the process exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let awake = AwakeController()
        awake.resumeSessionAfterRelaunch()
        let updates = AppUpdateManager.live {
            // Runs only after the install helper launches, so an update that fails its checks never saves a session.
            awake.saveSessionForRelaunch()
            NSApp.terminate(nil)
        }
        statusItemController = StatusItemController(
            awake: awake,
            launchAtLogin: LaunchAtLogin(service: SMAppService.mainApp),
            updates: updates
        )
        updates.startAutomaticChecks()
    }
}
