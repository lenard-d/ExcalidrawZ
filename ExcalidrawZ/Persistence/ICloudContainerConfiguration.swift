import Foundation
import CoreData
import CoreFoundation

/// Uses the same build setting as the cloud entitlements. Invalid configuration
/// disables cloud access instead of selecting another app's container.
struct ICloudContainerConfiguration {
    static let current = ICloudContainerConfiguration(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    let identifier: String?
    let isCloudKitEnabled: Bool

    enum CloudSyncPreferenceReaction {
        case none
        case restartRequired
        case accountUnavailable
    }

    init(infoDictionary: [String: Any]) {
        if let value = infoDictionary["ExcalidrawZCloudKitEnabled"] {
            if let boolean = value as? NSNumber,
               CFGetTypeID(boolean) == CFBooleanGetTypeID() {
                isCloudKitEnabled = boolean.boolValue
            } else {
                isCloudKitEnabled = false
            }
        } else {
            isCloudKitEnabled = true
        }

        guard let value = infoDictionary["ExcalidrawZICloudContainerIdentifier"] as? String,
              value.range(
                of: #"\AiCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\z"#,
                options: .regularExpression
              ) != nil else {
            identifier = nil
            return
        }
        identifier = value
    }

    var cloudKitContainerOptions: NSPersistentCloudKitContainerOptions? {
        guard isCloudKitEnabled else { return nil }
        return identifier.map { NSPersistentCloudKitContainerOptions(containerIdentifier: $0) }
    }

    /// Gives a fresh installation the matching preference without replacing a
    /// user's stored choice. The build setting still prevents CloudKit access.
    func registerCloudSyncDefaults(in defaults: UserDefaults) {
        if !isCloudKitEnabled {
            defaults.register(defaults: ["DisableCloudSync": true])
        }
    }

    func isCloudSyncDisabled(userPreference: Bool, hasICloudAccount: Bool) -> Bool {
        !isCloudKitEnabled || !hasICloudAccount || userPreference
    }

    func cloudSyncPreferenceReaction(
        disabled: Bool,
        hasICloudAccount: Bool
    ) -> CloudSyncPreferenceReaction {
        guard isCloudKitEnabled else { return .none }
        return disabled || hasICloudAccount ? .restartRequired : .accountUnavailable
    }

    func ubiquityContainerURL(
        resolve: (String) -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: $0)
        }
    ) -> URL? {
        guard let identifier else { return nil }
        return resolve(identifier)
    }
}
