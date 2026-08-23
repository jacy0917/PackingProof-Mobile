import SQLite3
import XCTest

final class IosDeviceSecurityTests: XCTestCase {
  func testSystemKeychainRoundTripUsesIsolatedNamespace() throws {
    let client = SystemIosKeychainClient()
    let service = isolatedService()
    let account = "access-key-\(UUID().uuidString)"
    defer { try? client.delete(service: service, account: account) }
    let expected = Data("device-test-access-key".utf8)

    try client.save(expected, service: service, account: account)
    XCTAssertEqual(try client.read(service: service, account: account), expected)
    try client.delete(service: service, account: account)
    XCTAssertNil(try client.read(service: service, account: account))
  }

  func testCredentialStoreMigratesAndScrubsIsolatedLegacyCopies() throws {
    let client = SystemIosKeychainClient()
    let service = isolatedService()
    let account = "access-key-\(UUID().uuidString)"
    let suiteName = "app.packingproof.mobile.devicetest.defaults.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      try? client.delete(service: service, account: account)
      defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("legacy-access-key", forKey: "ios_backup_access_key")
    defaults.set(
      ["accessKey": "legacy-connection-key", "baseUrl": "http://test.invalid"],
      forKey: "ios_backup_connection"
    )
    let store = IosBackupCredentialStore(
      defaults: defaults,
      keychain: client,
      service: service,
      account: account
    )

    XCTAssertEqual(try store.load(), "legacy-access-key")
    XCTAssertEqual(
      try client.read(service: service, account: account),
      Data("legacy-access-key".utf8)
    )
    XCTAssertNil(defaults.object(forKey: "ios_backup_access_key"))
    let connection = try XCTUnwrap(
      defaults.dictionary(forKey: "ios_backup_connection")
    )
    XCTAssertNil(connection["accessKey"])
    XCTAssertEqual(connection["baseUrl"] as? String, "http://test.invalid")

    try store.delete()
    XCTAssertNil(try client.read(service: service, account: account))
  }

  func testCleanupIntentPaginationIsBoundedAndKeysetBased() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    for index in 0..<101 {
      let id = String(format: "intent-%03d", index)
      var job = makeBackupJob(id: id)
      job["state"] = "paused"
      try store.upsert(job)
      XCTAssertNotNil(
        try store.beginCleanupIntent(
          jobId: id, expectedGeneration: "generation-\(id)",
          allowedStates: ["paused"], originalPath: "/recordings/\(id).mp4",
          tombstonePath: "/recordings/.\(id).tombstone", expectedBytes: 1024,
          expectedModifiedAtMilliseconds: 1_800_000_000_000,
          expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
          reason: "测试清理", completedState: nil, completedErrorMessage: nil
        ))
    }

    let first = try store.cleanupIntents(limit: 100)
    let second = try store.cleanupIntents(afterToken: first.last?.token, limit: 100)
    XCTAssertEqual(first.count, 100)
    XCTAssertEqual(second.count, 1)
    XCTAssertThrowsError(try store.cleanupIntents(limit: 101))
  }

  func testActiveCleanupIntentBlocksDifferentJobUsingSamePath() throws {
    let fixture = try makeBackupStoreFixture()
    defer { removeBackupStoreFixture(fixture) }
    let store = try IosBackupJobStore(
      databaseURL: fixture.databaseURL, defaults: fixture.defaults
    )
    let sharedPath = "/recordings/shared-cleanup.mp4"
    var cleanupJob = makeBackupJob(id: "cleanup-owner")
    cleanupJob["state"] = "failed"
    cleanupJob["filePath"] = sharedPath
    cleanupJob["failureKind"] = "incompatible_version"
    cleanupJob["destinationComputerId"] = "cleanup-computer"
    var queuedJob = makeBackupJob(id: "same-path-queued")
    queuedJob["filePath"] = sharedPath
    var movableJob = makeBackupJob(id: "move-onto-cleanup-path")
    movableJob["state"] = "paused"
    try store.upsert(cleanupJob)
    try store.upsert(queuedJob)
    try store.upsert(movableJob)
    let claimed = try XCTUnwrap(
      store.beginCleanupIntent(
        jobId: "cleanup-owner", expectedGeneration: "generation-cleanup-owner",
        allowedStates: ["failed"], originalPath: sharedPath,
        tombstonePath: "/recordings/.shared-cleanup.tombstone",
        expectedBytes: 1024,
        expectedModifiedAtMilliseconds: 1_800_000_000_000,
        expectedDevice: 0, expectedInode: 0, expectedSha256: nil,
        reason: "测试同路径屏障", completedState: nil,
        completedErrorMessage: nil
      ))
    XCTAssertNotNil(try store.activateCleanupIntent(token: claimed.token))
    XCTAssertEqual(
      try store.recoverIncompatibleFailures(
        destinationComputerId: "cleanup-computer"
      ),
      0
    )
    XCTAssertEqual(
      try store.readJob(id: "cleanup-owner")?["state"] as? String,
      "failed"
    )

    var newJob = makeBackupJob(id: "same-path-new")
    newJob["filePath"] = sharedPath
    XCTAssertThrowsError(try store.upsert(newJob)) { error in
      XCTAssertEqual((error as? IosBackupStoreError)?.code, SQLITE_BUSY)
    }
    XCTAssertThrowsError(
      try store.updateJob(id: "move-onto-cleanup-path") {
        $0["filePath"] = sharedPath
      }
    ) { error in
      XCTAssertEqual((error as? IosBackupStoreError)?.code, SQLITE_BUSY)
    }
    XCTAssertNil(try store.claimNextUploadJob())
    XCTAssertEqual(
      try store.readJob(id: "same-path-queued")?["state"] as? String,
      "pending"
    )
  }

  private func isolatedService() -> String {
    "app.packingproof.mobile.devicetest.lan-backup.\(UUID().uuidString)"
  }

  private typealias BackupStoreFixture = (
    root: URL, databaseURL: URL, defaults: UserDefaults, suiteName: String
  )

  private func makeBackupStoreFixture() throws -> BackupStoreFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "app.packingproof.mobile.devicetest.cleanup.\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true
    )
    let suiteName =
      "app.packingproof.mobile.devicetest.cleanup.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (
      root, root.appendingPathComponent("lan_backup.db"), defaults, suiteName
    )
  }

  private func removeBackupStoreFixture(_ fixture: BackupStoreFixture) {
    fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  private func makeBackupJob(id: String) -> [String: Any] {
    [
      "id": id,
      "generation": "generation-\(id)",
      "filePath": "/recordings/\(id).mp4",
      "state": "pending",
      "uploadedBytes": 0,
      "totalBytes": 1024,
      "lastModified": 1_800_000_000_000,
      "sessions": [["id": "session-\(id)", "trackingNumber": "tracking-\(id)"]],
    ]
  }
}
