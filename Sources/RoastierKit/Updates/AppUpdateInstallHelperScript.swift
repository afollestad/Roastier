import Foundation

/// The zsh helper that replaces the app bundle once the running app quits, rolling back to the old bundle and
/// staged metadata if the copy or relaunch fails.
struct AppUpdateInstallHelperScript: Sendable {
    static let live = AppUpdateInstallHelperScript(
        copyExecutableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
        openExecutableURL: URL(fileURLWithPath: "/usr/bin/open"),
        relaunchGraceSeconds: 3
    )

    let copyExecutableURL: URL
    let openExecutableURL: URL
    let relaunchGraceSeconds: TimeInterval

    func arguments(for invocation: AppUpdateInstallHelperInvocation) -> [String] {
        [
            "\(invocation.runningProcessIdentifier)",
            invocation.stagedAppURL.path,
            invocation.stagedDirectoryURL.path,
            invocation.targetAppURL.path,
            invocation.backupAppURL.path,
            invocation.logURL.path,
            invocation.metadataURL.path,
            invocation.quarantinedMetadataURL.path,
            invocation.helperURL.path,
            copyExecutableURL.path,
            openExecutableURL.path,
            "\(relaunchGraceSeconds)"
        ]
    }

    /// Quarantines the staged metadata before relaunch, so the new app never re-offers the update it is running.
    var contents: String {
        #"""
        set -u

        RUNNING_PID="$1"
        STAGED_APP="$2"
        STAGED_DIRECTORY="$3"
        TARGET_APP="$4"
        BACKUP_APP="$5"
        LOG_FILE="$6"
        METADATA_FILE="$7"
        QUARANTINED_METADATA_FILE="$8"
        HELPER_FILE="$9"
        COPY_EXECUTABLE="${10}"
        OPEN_EXECUTABLE="${11}"
        GRACE_SECONDS="${12}"

        exec >>"$LOG_FILE" 2>&1
        echo "Starting Roastier update install at $(date)"

        reopen_target() {
          if [ -e "$TARGET_APP" ]; then
            "$OPEN_EXECUTABLE" "$TARGET_APP" || true
          fi
        }

        restore_metadata() {
          if [ -e "$QUARANTINED_METADATA_FILE" ]; then
            mv "$QUARANTINED_METADATA_FILE" "$METADATA_FILE"
          fi
        }

        restore_backup() {
          rm -rf "$TARGET_APP"
          if [ -e "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
        }

        rollback() {
          echo "$1"
          restore_backup || true
          restore_metadata || true
          reopen_target
          exit 1
        }

        while kill -0 "$RUNNING_PID" 2>/dev/null; do
          sleep 0.2
        done

        if ! rm -rf "$BACKUP_APP"; then
          echo "Could not clear the update backup path"
          reopen_target
          exit 1
        fi

        if ! mv "$METADATA_FILE" "$QUARANTINED_METADATA_FILE"; then
          echo "Could not quarantine staged update metadata"
          reopen_target
          exit 1
        fi

        if [ -e "$TARGET_APP" ] && ! mv "$TARGET_APP" "$BACKUP_APP"; then
          echo "Could not move the installed app to its backup path"
          restore_metadata || true
          reopen_target
          exit 1
        fi

        if ! "$COPY_EXECUTABLE" "$STAGED_APP" "$TARGET_APP"; then
          rollback "Failed to copy staged app; restoring backup"
        fi

        if ! "$OPEN_EXECUTABLE" "$TARGET_APP"; then
          rollback "Failed to relaunch updated app; restoring backup"
        fi

        sleep "$GRACE_SECONDS"
        rm -rf "$BACKUP_APP"
        rm -f "$QUARANTINED_METADATA_FILE"
        rm -rf "$STAGED_DIRECTORY"
        rm -f "$HELPER_FILE"
        echo "Roastier update install completed at $(date)"
        exit 0
        """#
    }
}

struct AppUpdateInstallHelperInvocation: Sendable {
    let runningProcessIdentifier: Int32
    let stagedAppURL: URL
    let stagedDirectoryURL: URL
    let targetAppURL: URL
    let backupAppURL: URL
    let logURL: URL
    let metadataURL: URL
    let quarantinedMetadataURL: URL
    let helperURL: URL
}
