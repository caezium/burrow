//
//  UpdatesModelTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

@MainActor
final class UpdatesModelTests: XCTestCase {
    func testSameCountInventoryChangeRepreparesSourceMetadata() async {
        let detections = LockedStringRecorder()
        let model = UpdatesModel(detectSource: { app in
            detections.append(app.path)
            return app.path.contains("Store") ? .appStore : .sparkle
        })

        model.prepare(apps: [app(id: "one", name: "Vendor", path: "/Applications/Vendor.app")])
        await eventually { model.appItems.first?.source == .sparkle }

        model.prepare(apps: [app(id: "one", name: "Store", path: "/Applications/Store.app")])
        await eventually { model.appItems.first?.source == .appStore }

        XCTAssertEqual(detections.values, ["/Applications/Vendor.app", "/Applications/Store.app"])
        XCTAssertEqual(model.appItems.first?.name, "Store")
    }

    func testNewestPrepareWinsWhenOlderDetectionFinishesLast() async {
        let oldStarted = expectation(description: "old detection started")
        let releaseOld = DispatchSemaphore(value: 0)
        let model = UpdatesModel(detectSource: { app in
            if app.id == "old" {
                oldStarted.fulfill()
                releaseOld.wait()
                return .sparkle
            }
            return .appStore
        })

        model.prepare(apps: [app(id: "old", name: "Old", path: "/Applications/Old.app")])
        await fulfillment(of: [oldStarted], timeout: 1)
        model.prepare(apps: [app(id: "new", name: "New", path: "/Applications/New.app")])
        await eventually { model.appItems.map(\.id) == ["new"] }

        releaseOld.signal()
        await settle()

        XCTAssertEqual(model.appItems.map(\.id), ["new"])
        XCTAssertTrue(model.uncheckableApps.isEmpty)
    }

    func testRemovedAppsDisappearBeforeReplacementDetectionCompletes() async {
        let replacementStarted = expectation(description: "replacement detection started")
        let releaseReplacement = DispatchSemaphore(value: 0)
        let model = UpdatesModel(detectSource: { app in
            if app.name == "Replacement" {
                replacementStarted.fulfill()
                releaseReplacement.wait()
            }
            return .sparkle
        })
        let keep = app(id: "keep", name: "Keep", path: "/Applications/Keep.app")
        let remove = app(id: "remove", name: "Remove", path: "/Applications/Remove.app")

        model.prepare(apps: [keep, remove])
        await eventually { Set(model.appItems.map(\.id)) == ["keep", "remove"] }
        let replacement = app(id: "keep", name: "Replacement", path: "/Applications/Keep.app")
        model.prepare(apps: [replacement])
        await fulfillment(of: [replacementStarted], timeout: 1)

        XCTAssertFalse(model.appItems.contains { $0.id == "remove" })
        XCTAssertFalse(model.uncheckableApps.contains { $0.id == "remove" })

        releaseReplacement.signal()
        await eventually { model.appItems.first?.name == "Replacement" }
    }

    func testSameInstalledAppIdentityRepreparesWhenBundleDetectionMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatesModelTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Mutable.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlist(
            ["CFBundleIdentifier": "dev.test.mutable", "SUFeedURL": "https://updates.example.com/appcast.xml"],
            to: contents.appendingPathComponent("Info.plist")
        )
        let installed = app(id: "stable", name: "Mutable", path: appURL.path)
        let model = UpdatesModel()

        model.prepare(apps: [installed])
        await eventually { model.appItems.first?.source == .sparkle }

        try writePlist(
            ["CFBundleIdentifier": "dev.test.mutable"],
            to: contents.appendingPathComponent("Info.plist")
        )
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Frameworks/Electron Framework.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        model.prepare(apps: [installed])
        await eventually { model.appItems.first?.source == .electron }

        XCTAssertEqual(model.appItems.map(\.id), ["stable"])
    }

    func testDetectionFingerprintIncludesElectronAppUpdateConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatesFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Mutable.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = resources.appendingPathComponent("app-update.yml")
        try Data("provider: generic\nurl: https://one.example.com".utf8).write(to: config, options: .atomic)
        let before = UpdateSources.detectionFingerprint(appPath: root.appendingPathComponent("Mutable.app").path)

        try Data("provider: generic\nurl: https://two.example.com".utf8).write(to: config, options: .atomic)
        let after = UpdateSources.detectionFingerprint(appPath: root.appendingPathComponent("Mutable.app").path)

        XCTAssertNotEqual(before, after)
    }

    func testTransientCheckAutomaticallyRetriesOnceAndPublishesTheRecoveredUpdate() async {
        let responses = LockedCheckResponseQueue([
            .failure(id: "electron", failure: .offline),
            .available(id: "electron", version: "2.0.0"),
        ])
        let retryDelays = LockedUInt64Recorder()
        let model = UpdatesModel(
            checkItem: { item in responses.next(for: item.id) },
            retrySleep: { delay in retryDelays.append(delay) },
            loadBrewOutdated: { _ in .empty }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]

        model.checkNow()
        await eventually { model.checked }

        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(retryDelays.values.count, 1)
        XCTAssertLessThanOrEqual(retryDelays.values[0], 2_000_000_000)
        XCTAssertEqual(model.appItems.first?.latestVersion, "2.0.0")
        XCTAssertEqual(model.phase(for: "electron"), .available)
    }

    func testAutomaticRetryIsBoundedAndPreservesTheLastConfirmedUpdate() async {
        let responses = LockedCheckResponseQueue([
            .failure(id: "electron", failure: .decoding),
            .failure(id: "electron", failure: .decoding),
            .available(id: "electron", version: "9.9.9"),
        ])
        let retryDelays = LockedUInt64Recorder()
        let model = UpdatesModel(
            checkItem: { item in responses.next(for: item.id) },
            retrySleep: { delay in retryDelays.append(delay) },
            loadBrewOutdated: { _ in .empty }
        )
        model.appItems = [updateItem(
            id: "electron",
            installed: "1.0.0",
            source: .electron,
            latest: "2.0.0"
        )]

        model.checkNow()
        await eventually { model.checked }

        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(retryDelays.values.count, 1)
        XCTAssertEqual(model.appItems.first?.latestVersion, "2.0.0")
        XCTAssertEqual(model.phase(for: "electron"), .failed(.decoding))
    }

    func testRetryAfterCheckFailureRerunsTheCheckEvenWhenAKnownUpdateWasPreserved() async {
        let responses = LockedCheckResponseQueue([
            .failure(id: "electron", failure: .offline),
            .failure(id: "electron", failure: .offline),
            .available(id: "electron", version: "2.1.0"),
        ])
        let model = UpdatesModel(
            checkItem: { item in responses.next(for: item.id) },
            retrySleep: { _ in },
            loadBrewOutdated: { _ in .empty }
        )
        model.appItems = [updateItem(
            id: "electron",
            installed: "1.0.0",
            source: .electron,
            latest: "2.0.0"
        )]

        model.checkNow()
        await eventually { model.checked && model.phase(for: "electron") == .failed(.offline) }
        model.retry(model.appItems[0])
        await eventually { !model.checking && model.appItems.first?.latestVersion == "2.1.0" }

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(model.phase(for: "electron"), .available)
    }

    func testOlderForcedResponsePreservesPreviouslyConfirmedAvailability() async {
        let responses = LockedCheckResponseQueue([
            .completed(id: "electron", version: "0.9.0"),
        ])
        let model = UpdatesModel(
            checkItem: { item in responses.next(for: item.id) },
            loadBrewOutdated: { _ in .empty }
        )
        model.appItems = [updateItem(
            id: "electron",
            installed: "1.0.0",
            source: .electron,
            latest: "2.0.0"
        )]

        model.checkNow()
        await eventually { model.checked }

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(model.appItems.first?.latestVersion, "2.0.0")
        XCTAssertEqual(model.availableItems.map(\.id), ["electron"])
        XCTAssertEqual(model.phase(for: "electron"), .available)
    }

    func testOlderForcedCheckCannotOverwriteANewerGeneration() async {
        let oldStarted = expectation(description: "older check started")
        let responder = OutOfOrderCheckResponder(onOldStart: { oldStarted.fulfill() })
        let model = UpdatesModel(
            detectSource: { _ in .electron },
            sourceFingerprint: { $0.path },
            checkItem: { item in await responder.response(for: item.id) },
            loadBrewOutdated: { _ in .empty }
        )

        model.prepare(apps: [app(id: "old", name: "Old", path: "/Applications/Old.app")])
        await eventually { model.appItems.map(\.id) == ["old"] }
        model.checkNow()
        await fulfillment(of: [oldStarted], timeout: 1)

        model.prepare(apps: [app(id: "new", name: "New", path: "/Applications/New.app")])
        await eventually { model.appItems.map(\.id) == ["new"] }
        model.checkNow()
        await eventually { model.checked && model.appItems.first?.latestVersion == "3.0.0" }

        await responder.finishOldResponse()
        await settle()

        XCTAssertEqual(model.appItems.map(\.id), ["new"])
        XCTAssertEqual(model.appItems.first?.latestVersion, "3.0.0")
        XCTAssertEqual(model.phase(for: "new"), .available)
        XCTAssertEqual(model.phase(for: "old"), .idle)
    }

    func testUpdateAllDoesNotStartWhileARowUpdateIsRunning() async {
        let rowStageStarted = expectation(description: "row stage started")
        let staging = FirstBlockingElectronStage(onFirstStart: { rowStageStarted.fulfill() })
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let model = UpdatesModel(
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in await staging.stage() }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]
        model.checkNow()
        await eventually { model.checked }

        model.update(model.appItems[0])
        await fulfillment(of: [rowStageStarted], timeout: 1)
        model.updateAllApps()

        XCTAssertFalse(model.updateAllRunning)
        await staging.finishFirst(with: .failure(.cancelled))
        await eventually { model.phase(for: "electron") == .failed(.cancelled) }
        let callCount = await staging.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testRowUpdateDoesNotStartWhileUpdateAllIsRunning() async {
        let batchStageStarted = expectation(description: "batch stage started")
        let staging = FirstBlockingElectronStage(onFirstStart: { batchStageStarted.fulfill() })
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let model = UpdatesModel(
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in await staging.stage() }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]
        model.checkNow()
        await eventually { model.checked }

        model.updateAllApps()
        model.update(model.appItems[0])
        await fulfillment(of: [batchStageStarted], timeout: 1)
        await staging.finishFirst(with: .failure(.cancelled))
        await eventually { !model.updateAllRunning }
        await settle()

        let callCount = await staging.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testRemovedAppCannotBeResurrectedWhenUpdateAllStageFinishesLate() async throws {
        let stagingRoot = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let stageStarted = expectation(description: "batch stage started")
        let staging = FirstBlockingElectronStage(onFirstStart: { stageStarted.fulfill() })
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let staged = stagedElectronUpdate(in: stagingRoot)
        var confirmationCount = 0
        var installCount = 0
        let installed = app(
            id: "electron",
            name: "Electron",
            path: "/Applications/Electron.app"
        )
        let model = UpdatesModel(
            detectSource: { _ in .electron },
            sourceFingerprint: { $0.path },
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in await staging.stage() },
            installElectron: { _ in
                installCount += 1
                return .installed
            },
            confirmRestart: { _ in
                confirmationCount += 1
                return true
            }
        )

        model.prepare(apps: [installed])
        await eventually { model.appItems.map(\.id) == ["electron"] }
        model.checkNow()
        await eventually { model.checked && model.availableItems.map(\.id) == ["electron"] }

        model.updateAllApps()
        await fulfillment(of: [stageStarted], timeout: 1)
        model.prepare(apps: [])
        XCTAssertTrue(model.appItems.isEmpty)

        await staging.finishFirst(with: .ready(staged))
        await eventually {
            !model.updateAllRunning && !FileManager.default.fileExists(atPath: stagingRoot.path)
        }

        XCTAssertTrue(model.appItems.isEmpty)
        XCTAssertEqual(model.phase(for: "electron"), .idle)
        XCTAssertEqual(model.updateAllCompleted, 0)
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(installCount, 0)
    }

    func testRestartConsentCannotInstallAnAppRemovedWhileTheModalIsOpen() async throws {
        let stagingRoot = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let staged = stagedElectronUpdate(in: stagingRoot)
        let installed = app(
            id: "electron",
            name: "Electron",
            path: "/Applications/Electron.app"
        )
        var reentrantModel: UpdatesModel?
        var installCount = 0
        let model = UpdatesModel(
            detectSource: { _ in .electron },
            sourceFingerprint: { $0.path },
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in .ready(staged) },
            installElectron: { _ in
                installCount += 1
                return .installed
            },
            confirmRestart: { _ in
                reentrantModel?.prepare(apps: [])
                return true
            }
        )
        reentrantModel = model

        model.prepare(apps: [installed])
        await eventually { model.appItems.map(\.id) == ["electron"] }
        model.checkNow()
        await eventually { model.checked && model.availableItems.map(\.id) == ["electron"] }
        model.update(model.appItems[0])
        await eventually { model.phase(for: "electron") == .readyToInstall }

        model.installReady(model.appItems[0])
        await settle()

        XCTAssertTrue(model.appItems.isEmpty)
        XCTAssertEqual(model.phase(for: "electron"), .idle)
        XCTAssertEqual(installCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testCancelledRowTaskCannotRemoveTrackingForItsReplacement() async throws {
        let stagingRoot = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let firstStageStarted = expectation(description: "first row stage started")
        let replacementStageStarted = expectation(description: "replacement row stage started")
        let staging = SequencedBlockingElectronStages(onStart: { call in
            if call == 1 { firstStageStarted.fulfill() }
            if call == 2 { replacementStageStarted.fulfill() }
        })
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let cancelledStage = StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Electron.app"),
            candidateURL: stagingRoot.appendingPathComponent("Electron.app"),
            stagingDirectory: stagingRoot,
            stagingDirectoryIdentity: try XCTUnwrap(
                ElectronReplacementInstaller.stagingDirectoryIdentity(at: stagingRoot)
            ),
            canonicalStagingDirectoryURL: stagingRoot.resolvingSymlinksInPath().standardizedFileURL,
            expectedIdentity: BundleUpdateIdentity(
                bundleID: "dev.test.electron",
                signingIdentifier: "dev.test.electron",
                teamIdentifier: "TEAM123",
                signatureValid: true
            )
        )
        let model = UpdatesModel(
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in await staging.stage() }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]
        model.checkNow()
        await eventually { model.checked }

        model.update(model.appItems[0])
        await fulfillment(of: [firstStageStarted], timeout: 1)
        model.cancel(model.appItems[0])
        model.update(model.appItems[0])
        await fulfillment(of: [replacementStageStarted], timeout: 1)

        await staging.finish(call: 1, with: .ready(cancelledStage))
        await eventually { !FileManager.default.fileExists(atPath: stagingRoot.path) }
        model.updateAllApps()

        XCTAssertFalse(model.updateAllRunning)
        await staging.finish(call: 2, with: .failure(.offline))
        await eventually { model.phase(for: "electron") == .failed(.offline) }
        let callCount = await staging.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testCancelledRowTaskFinishingAfterReplacementCannotOverwriteReplacementState() async throws {
        let cancelledRoot = try PrivateUpdateDirectory.create()
        let replacementRoot = try PrivateUpdateDirectory.create()
        defer {
            try? FileManager.default.removeItem(at: cancelledRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }
        let firstStageStarted = expectation(description: "first row stage started")
        let replacementStageStarted = expectation(description: "replacement row stage started")
        let staging = SequencedBlockingElectronStages(onStart: { call in
            if call == 1 { firstStageStarted.fulfill() }
            if call == 2 { replacementStageStarted.fulfill() }
        })
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let cancelledStage = stagedElectronUpdate(in: cancelledRoot)
        let replacementStage = stagedElectronUpdate(in: replacementRoot)
        var installedCandidate: URL?
        let model = UpdatesModel(
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in await staging.stage() },
            installElectron: { staged in
                installedCandidate = staged.candidateURL
                return .installed
            },
            confirmRestart: { _ in true }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]
        model.checkNow()
        await eventually { model.checked }

        model.update(model.appItems[0])
        await fulfillment(of: [firstStageStarted], timeout: 1)
        model.cancel(model.appItems[0])
        model.update(model.appItems[0])
        await fulfillment(of: [replacementStageStarted], timeout: 1)

        await staging.finish(call: 2, with: .ready(replacementStage))
        await eventually { model.phase(for: "electron") == .readyToInstall }
        await staging.finish(call: 1, with: .ready(cancelledStage))
        await eventually { !FileManager.default.fileExists(atPath: cancelledRoot.path) }

        XCTAssertEqual(model.phase(for: "electron"), .readyToInstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementRoot.path))
        model.installReady(model.appItems[0])
        await eventually { model.phase(for: "electron") == .completed }
        XCTAssertEqual(installedCandidate, replacementStage.candidateURL)
    }

    func testUpdateAllStagesElectronThenRequiresExplicitRestartConsent() async throws {
        let stagingRoot = try PrivateUpdateDirectory.create()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let descriptor = ElectronUpdateDescriptor(
            version: "2.0.0",
            archiveURL: URL(string: "https://updates.example.com/Electron.zip")!,
            sha512: Data("digest".utf8)
        )
        let staged = StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Electron.app"),
            candidateURL: stagingRoot.appendingPathComponent("Electron.app"),
            stagingDirectory: stagingRoot,
            stagingDirectoryIdentity: try XCTUnwrap(
                ElectronReplacementInstaller.stagingDirectoryIdentity(at: stagingRoot)
            ),
            canonicalStagingDirectoryURL: stagingRoot.resolvingSymlinksInPath().standardizedFileURL,
            expectedIdentity: BundleUpdateIdentity(
                bundleID: "dev.test.electron",
                signingIdentifier: "dev.test.electron",
                teamIdentifier: "TEAM123",
                signatureValid: true
            )
        )
        let workflow = LockedElectronWorkflow(staged: staged)
        let model = UpdatesModel(
            checkItem: { item in
                .available(id: item.id, version: descriptor.version, electronDescriptor: descriptor)
            },
            loadBrewOutdated: { _ in .empty },
            stageElectron: { _, _ in workflow.stage() },
            installElectron: { staged in workflow.install(staged) },
            confirmRestart: { item in workflow.confirmRestart(for: item.name) }
        )
        model.appItems = [updateItem(id: "electron", installed: "1.0.0", source: .electron)]
        model.checkNow()
        await eventually { model.checked }

        model.updateAllApps()
        await eventually { !model.updateAllRunning && model.phase(for: "electron") == .readyToInstall }

        XCTAssertEqual(workflow.stageCount, 1)
        XCTAssertEqual(workflow.installCount, 0)
        XCTAssertEqual(workflow.confirmedNames, ["Electron"])
        XCTAssertEqual(workflow.events, ["stage", "confirm:Electron"])

        workflow.allowRestart()
        model.installReady(model.appItems[0])
        await eventually { model.phase(for: "electron") == .completed }

        XCTAssertEqual(workflow.installCount, 1)
        XCTAssertEqual(workflow.confirmedNames, ["Electron", "Electron"])
        XCTAssertEqual(workflow.events, ["stage", "confirm:Electron", "confirm:Electron", "install"])
    }

    // MARK: Homebrew half (#424)

    func testAutoSurfaceReadsTheLocalIndexOnceAndSurfacesAProblem() async {
        let loads = LockedStringRecorder()
        let model = UpdatesModel(loadBrewOutdated: { refresh in
            loads.append(refresh ? "refresh" : "local")
            return BrewOutdated(problem: .failed("Error: git fetch exited with 128"))
        })

        model.autoSurface()
        await eventually { model.brewLoaded }

        XCTAssertEqual(model.brewProblem, .failed("Error: git fetch exited with 128"))
        XCTAssertTrue(model.brewItems.isEmpty)
        XCTAssertFalse(model.brewLoading)

        // A second open and the app check both leave Homebrew alone.
        model.autoSurface()
        model.checkNow()
        await eventually { model.checked }
        XCTAssertEqual(loads.values, ["local"])
    }

    func testRefreshBrewRunsTheNetworkStepAndReplacesTheList() async {
        let loads = LockedStringRecorder()
        let model = UpdatesModel(loadBrewOutdated: { refresh in
            loads.append(refresh ? "refresh" : "local")
            return refresh ? BrewOutdated(items: [brew("git")]) : .empty
        })
        model.autoSurface()
        await eventually { model.brewLoaded }
        XCTAssertTrue(model.brewItems.isEmpty)

        model.refreshBrew()
        XCTAssertTrue(model.brewLoading)
        XCTAssertTrue(model.brewRefreshing)
        await eventually { model.brewItems.map(\.name) == ["git"] }

        XCTAssertNil(model.brewProblem)
        XCTAssertFalse(model.brewRefreshing)
        XCTAssertEqual(loads.values, ["local", "refresh"])
    }

    func testUpgradeAllBrewsRunsSeriallyThenReloadsSoFinishedRowsDropOut() async {
        let upgraded = LockedStringRecorder()
        let model = UpdatesModel(
            loadBrewOutdated: { _ in
                let done = Set(upgraded.values)
                return BrewOutdated(items: [brew("git"), brew("wget")].filter { !done.contains($0.name) })
            },
            upgradeBrew: { item, _ in
                upgraded.append(item.name)
                return 0
            }
        )
        model.autoSurface()
        await eventually { model.brewItems.count == 2 }

        model.upgradeAllBrews()
        XCTAssertTrue(model.updateAllRunning)
        XCTAssertEqual(model.updateAllSource, .homebrew)
        XCTAssertEqual(model.updateAllTotal, 2)
        await eventually { !model.updateAllRunning && !model.brewLoading && model.brewItems.isEmpty }

        XCTAssertEqual(upgraded.values, ["git", "wget"])
        XCTAssertEqual(model.updateAllCompleted, 2)
        XCTAssertNil(model.updateAllSource)
        XCTAssertEqual(model.phase(for: "formula:git"), .idle)
        XCTAssertEqual(model.phase(for: "formula:wget"), .idle)
    }

    func testBrewBatchStopsAfterTheCurrentItemAndKeepsAFailureOnItsRow() async {
        let upgraded = LockedStringRecorder()
        let gate = BrewGate()
        let model = UpdatesModel(
            loadBrewOutdated: { _ in BrewOutdated(items: [brew("git"), brew("wget")]) },
            upgradeBrew: { item, _ in
                upgraded.append(item.name)
                return await gate.wait()
            }
        )
        model.autoSurface()
        await eventually { model.brewItems.count == 2 }

        model.upgradeAllBrews()
        await eventually { upgraded.values == ["git"] }
        model.cancelUpdateAll()
        XCTAssertTrue(model.cancelUpdateAllAfterCurrent)
        await gate.release(1)
        await eventually { !model.updateAllRunning && !model.brewLoading }

        XCTAssertEqual(upgraded.values, ["git"], "the stop lands between transactions")
        XCTAssertEqual(model.updateAllCompleted, 1)
        guard case .failed = model.phase(for: "formula:git") else {
            return XCTFail("the still-outdated row keeps its failure, got \(model.phase(for: "formula:git"))")
        }
        XCTAssertEqual(model.phase(for: "formula:wget"), .idle)
    }

    func testOneBatchAtATimeAcrossBothSources() async {
        let gate = BrewGate()
        let model = UpdatesModel(
            checkItem: { item in .available(id: item.id, version: "2.0.0") },
            loadBrewOutdated: { _ in BrewOutdated(items: [brew("git")]) },
            upgradeBrew: { _, _ in await gate.wait() }
        )
        model.appItems = [updateItem(id: "sparkle", installed: "1.0.0", source: .sparkle)]
        model.autoSurface()
        model.checkNow()
        await eventually { model.checked && model.brewItems.count == 1 }
        XCTAssertEqual(model.availableItems.map(\.id), ["sparkle"])

        model.upgradeAllBrews()
        XCTAssertEqual(model.updateAllSource, .homebrew)
        model.updateAllApps()
        XCTAssertEqual(model.updateAllSource, .homebrew, "the app batch waits its turn")
        model.refreshBrew()
        XCTAssertFalse(model.brewLoading, "no reload underneath a running upgrade")

        await gate.release(0)
        await eventually { !model.updateAllRunning && !model.brewLoading }
        XCTAssertNil(model.updateAllSource)
    }

    private func app(id: String, name: String, path: String) -> InstalledApp {
        InstalledApp(
            id: id,
            name: name,
            bundleId: "dev.test.\(id)",
            source: "App",
            uninstallName: name,
            path: path,
            sizeStr: "1 B",
            sizeBytes: 1,
            lastUsed: nil
        )
    }

    private func updateItem(
        id: String,
        installed: String,
        source: UpdateSources.Source,
        latest: String? = nil
    ) -> AppUpdateItem {
        AppUpdateItem(
            id: id,
            name: id.capitalized,
            path: "/Applications/\(id.capitalized).app",
            bundleID: "dev.test.\(id)",
            installedVersion: installed,
            sizeStr: "1 B",
            source: source,
            latestVersion: latest,
            pageURL: nil,
            releaseNotesURL: nil,
            lastUsed: nil,
            minimumOS: nil
        )
    }

    private func stagedElectronUpdate(in root: URL) -> StagedElectronUpdate {
        StagedElectronUpdate(
            targetURL: URL(fileURLWithPath: "/Applications/Electron.app"),
            candidateURL: root.appendingPathComponent("Electron.app"),
            stagingDirectory: root,
            stagingDirectoryIdentity: ElectronReplacementInstaller.stagingDirectoryIdentity(at: root)
                ?? .init(device: 0, inode: 0),
            canonicalStagingDirectoryURL: root.resolvingSymlinksInPath().standardizedFileURL,
            expectedIdentity: BundleUpdateIdentity(
                bundleID: "dev.test.electron",
                signingIdentifier: "dev.test.electron",
                teamIdentifier: "TEAM123",
                signatureValid: true
            )
        )
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

private final class LockedCheckResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [AppUpdateCheckResult]
    private var calls = 0

    init(_ responses: [AppUpdateCheckResult]) {
        self.responses = responses
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next(for id: String) -> AppUpdateCheckResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !responses.isEmpty else {
            return .failure(id: id, failure: .invalidResponse)
        }
        return responses.removeFirst()
    }
}

private final class LockedUInt64Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: UInt64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private actor OutOfOrderCheckResponder {
    private var oldContinuation: CheckedContinuation<Void, Never>?
    private let onOldStart: () -> Void

    init(onOldStart: @escaping () -> Void) {
        self.onOldStart = onOldStart
    }

    func response(for id: String) async -> AppUpdateCheckResult {
        if id == "old" {
            onOldStart()
            await withCheckedContinuation { continuation in
                oldContinuation = continuation
            }
            return .available(id: id, version: "2.0.0")
        }
        return .available(id: id, version: "3.0.0")
    }

    func finishOldResponse() {
        oldContinuation?.resume()
        oldContinuation = nil
    }
}

private actor FirstBlockingElectronStage {
    private var calls = 0
    private var firstContinuation: CheckedContinuation<ElectronStageOutcome, Never>?
    private let onFirstStart: () -> Void

    init(onFirstStart: @escaping () -> Void) {
        self.onFirstStart = onFirstStart
    }

    var callCount: Int { calls }

    func stage() async -> ElectronStageOutcome {
        calls += 1
        guard calls == 1 else { return .failure(.cancelled) }
        onFirstStart()
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func finishFirst(with outcome: ElectronStageOutcome) {
        firstContinuation?.resume(returning: outcome)
        firstContinuation = nil
    }
}

private actor SequencedBlockingElectronStages {
    private var calls = 0
    private var continuations: [Int: CheckedContinuation<ElectronStageOutcome, Never>] = [:]
    private let onStart: (Int) -> Void

    init(onStart: @escaping (Int) -> Void) {
        self.onStart = onStart
    }

    var callCount: Int { calls }

    func stage() async -> ElectronStageOutcome {
        calls += 1
        let call = calls
        guard call <= 2 else { return .failure(.cancelled) }
        onStart(call)
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func finish(call: Int, with outcome: ElectronStageOutcome) {
        continuations.removeValue(forKey: call)?.resume(returning: outcome)
    }
}

private final class LockedElectronWorkflow: @unchecked Sendable {
    private let lock = NSLock()
    private let stagedUpdate: StagedElectronUpdate
    private var restartAllowed = false
    private var stages = 0
    private var installs = 0
    private var names: [String] = []
    private var recordedEvents: [String] = []

    init(staged: StagedElectronUpdate) {
        stagedUpdate = staged
    }

    var stageCount: Int { locked { stages } }
    var installCount: Int { locked { installs } }
    var confirmedNames: [String] { locked { names } }
    var events: [String] { locked { recordedEvents } }

    func stage() -> ElectronStageOutcome {
        locked {
            stages += 1
            recordedEvents.append("stage")
        }
        return .ready(stagedUpdate)
    }

    func install(_ staged: StagedElectronUpdate) -> ElectronInstallOutcome {
        locked {
            installs += 1
            recordedEvents.append("install")
        }
        return .installed
    }

    func confirmRestart(for name: String) -> Bool {
        locked {
            names.append(name)
            recordedEvents.append("confirm:\(name)")
            return restartAllowed
        }
    }

    func allowRestart() {
        locked { restartAllowed = true }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func brew(_ name: String, kind: String = "formula") -> OutdatedItem {
    OutdatedItem(id: "\(kind):\(name)", name: name, installed: "1.0", latest: "2.0", kind: kind)
}

/// Holds a fake `brew upgrade` open until the test releases it, so a stop
/// can be requested while an item is mid-flight. A release that arrives
/// before the wait is kept, never lost.
private actor BrewGate {
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var pending: [Int32] = []

    func wait() async -> Int32 {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ code: Int32) {
        if waiters.isEmpty { pending.append(code) } else { waiters.removeFirst().resume(returning: code) }
    }
}
