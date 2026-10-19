import XCTest
@testable import ExcalidrawZ

final class ICloudContainerConfigurationTests: XCTestCase {
    func testCloudKitUsesConfiguredContainer() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test"
        ])

        XCTAssertEqual(
            configuration.cloudKitContainerOptions?.containerIdentifier,
            "iCloud.example.separate-test"
        )
        XCTAssertTrue(configuration.isCloudKitEnabled)
    }

    func testExplicitBooleanTrueAllowsConfiguredCloudKitContainer() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
            "ExcalidrawZCloudKitEnabled": true
        ])

        XCTAssertEqual(
            configuration.cloudKitContainerOptions?.containerIdentifier,
            "iCloud.example.separate-test"
        )
    }

    func testDisabledCloudKitRetainsTheConfiguredDriveIdentifier() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
            "ExcalidrawZCloudKitEnabled": false
        ])
        let expectedURL = URL(fileURLWithPath: "/isolated-test-container")

        XCTAssertFalse(configuration.isCloudKitEnabled)
        XCTAssertNil(configuration.cloudKitContainerOptions)
        XCTAssertEqual(configuration.identifier, "iCloud.example.separate-test")
        XCTAssertEqual(configuration.ubiquityContainerURL { identifier in
            XCTAssertEqual(identifier, "iCloud.example.separate-test")
            return expectedURL
        }, expectedURL)
    }

    func testMalformedBuildFlagDisablesCloudKit() {
        let malformedValues: [Any] = [
            "true", "YES", "false", "NO", "$(CLOUDKIT_ENABLED)", "",
            0, 1, 2, 1.0, NSNumber(value: 0), NSNumber(value: 1), NSNull(), [], [:]
        ]

        for value in malformedValues {
            let configuration = ICloudContainerConfiguration(infoDictionary: [
                "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
                "ExcalidrawZCloudKitEnabled": value
            ])

            XCTAssertFalse(configuration.isCloudKitEnabled, "Malformed value: \(value)")
            XCTAssertNil(configuration.cloudKitContainerOptions, "Malformed value: \(value)")
            XCTAssertEqual(configuration.identifier, "iCloud.example.separate-test")
        }
    }

    func testPropertyListBooleanTypesControlCloudKit() throws {
        for enabled in [true, false] {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
                "ExcalidrawZCloudKitEnabled": enabled
            ], format: .xml, options: 0)
            let info = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            let configuration = ICloudContainerConfiguration(infoDictionary: info)

            XCTAssertEqual(configuration.isCloudKitEnabled, enabled)
            XCTAssertEqual(configuration.cloudKitContainerOptions != nil, enabled)
        }
    }

    func testBuildDefaultDisablesSyncOnFirstLaunchWithoutArguments() throws {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
            "ExcalidrawZCloudKitEnabled": false
        ])
        let suiteName = "ICloudContainerConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        configuration.registerCloudSyncDefaults(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "DisableCloudSync"))
        XCTAssertNil(configuration.cloudKitContainerOptions)
    }

    func testBuildDisableCannotBeOverriddenByStoredCloudPreference() throws {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
            "ExcalidrawZCloudKitEnabled": false
        ])
        let suiteName = "ICloudContainerConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "DisableCloudSync")

        configuration.registerCloudSyncDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: "DisableCloudSync"))
        XCTAssertNil(configuration.cloudKitContainerOptions)
    }

    func testEnabledBuildPreservesStoredSyncPreference() throws {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test",
            "ExcalidrawZCloudKitEnabled": true
        ])
        let suiteName = "ICloudContainerConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "DisableCloudSync")

        configuration.registerCloudSyncDefaults(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "DisableCloudSync"))
    }

    func testBuildFlagCannotEnableAMalformedContainer() {
        for enabled in [true, false] {
            let configuration = ICloudContainerConfiguration(infoDictionary: [
                "ExcalidrawZICloudContainerIdentifier": "iCloud.example/test",
                "ExcalidrawZCloudKitEnabled": enabled
            ])

            XCTAssertNil(configuration.identifier)
            XCTAssertNil(configuration.cloudKitContainerOptions)
            XCTAssertNil(configuration.ubiquityContainerURL { _ in
                XCTFail("An invalid container must not be resolved")
                return nil
            })
        }
    }

    func testICloudDriveUsesTheSameConfiguredContainer() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test"
        ])
        let expectedURL = URL(fileURLWithPath: "/isolated-test-container")
        var requestedIdentifier: String?

        let url = configuration.ubiquityContainerURL { identifier in
            requestedIdentifier = identifier
            return expectedURL
        }

        XCTAssertEqual(requestedIdentifier, configuration.cloudKitContainerOptions?.containerIdentifier)
        XCTAssertEqual(requestedIdentifier, "iCloud.example.separate-test")
        XCTAssertEqual(url, expectedURL)
    }

    func testInvalidConfigurationDoesNotAccessAnyContainer() {
        let invalidValues: [Any] = [
            "", "$(ICLOUD_CONTAINER)", "iCloud.$(NAME)", "iCloud.",
            " iCloud.example.test", "iCloud.example.test\n", "example.test", 42,
            "iCloud.example/test", "iCloud.example:container", "iCloud..",
            "iCloud.example.*", "iCloud.example..test"
        ]

        for value in invalidValues {
            let configuration = ICloudContainerConfiguration(infoDictionary: [
                "ExcalidrawZICloudContainerIdentifier": value
            ])
            var didResolve = false

            let url = configuration.ubiquityContainerURL { _ in
                didResolve = true
                return URL(fileURLWithPath: "/unexpected-container")
            }

            XCTAssertNil(configuration.identifier, "Invalid value: \(value)")
            XCTAssertNil(configuration.cloudKitContainerOptions, "Invalid value: \(value)")
            XCTAssertNil(url)
            XCTAssertFalse(didResolve)
        }
    }

    func testMissingConfigurationDoesNotSelectProductionContainer() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [:])

        XCTAssertNil(configuration.identifier)
        XCTAssertNil(configuration.cloudKitContainerOptions)
        XCTAssertNil(configuration.ubiquityContainerURL { _ in
            XCTFail("Missing configuration must not perform a container lookup")
            return nil
        })
    }

    func testUnavailableConfiguredContainerDoesNotTryAnotherContainer() {
        let configuration = ICloudContainerConfiguration(infoDictionary: [
            "ExcalidrawZICloudContainerIdentifier": "iCloud.example.separate-test"
        ])
        var requestedIdentifiers: [String] = []

        let url = configuration.ubiquityContainerURL { identifier in
            requestedIdentifiers.append(identifier)
            return nil
        }

        XCTAssertNil(url)
        XCTAssertEqual(requestedIdentifiers, ["iCloud.example.separate-test"])
    }
}
