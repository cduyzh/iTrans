import XCTest
@testable import cduyzhTranslatorCore

final class AppUpdateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChangelogManager.shared.resetToDefaults()
    }

    override func tearDown() {
        ChangelogManager.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - AppVersion 语义化版本测试
    func testVersionParsingAndFormatting() {
        let v1 = AppVersion(string: "1.0.0")
        XCTAssertNotNil(v1)
        XCTAssertEqual(v1?.major, 1)
        XCTAssertEqual(v1?.minor, 0)
        XCTAssertEqual(v1?.patch, 0)
        XCTAssertNil(v1?.prerelease)
        XCTAssertEqual(v1?.description, "1.0.0")

        let v2 = AppVersion(string: "v2.3.4-alpha.1", buildNumber: 42)
        XCTAssertNotNil(v2)
        XCTAssertEqual(v2?.major, 2)
        XCTAssertEqual(v2?.minor, 3)
        XCTAssertEqual(v2?.patch, 4)
        XCTAssertEqual(v2?.prerelease, "alpha.1")
        XCTAssertEqual(v2?.buildNumber, 42)
        XCTAssertEqual(v2?.fullDisplayString, "v2.3.4-alpha.1")
    }

    func testVersionComparison() {
        let v1_0_0 = AppVersion(string: "1.0.0")!
        let v1_0_1 = AppVersion(string: "1.0.1")!
        let v1_1_0 = AppVersion(string: "1.1.0")!
        let v2_0_0 = AppVersion(string: "2.0.0")!
        let v1_0_0_beta = AppVersion(string: "1.0.0-beta")!

        XCTAssertTrue(v1_0_0 < v1_0_1)
        XCTAssertTrue(v1_0_1 < v1_1_0)
        XCTAssertTrue(v1_1_0 < v2_0_0)
        XCTAssertTrue(v1_0_0_beta < v1_0_0)
        XCTAssertEqual(v1_0_0, AppVersion(string: "1.0.0")!)

        // Build 编号比对
        let vBuild1 = AppVersion(major: 1, minor: 0, patch: 0, buildNumber: 1)
        let vBuild2 = AppVersion(major: 1, minor: 0, patch: 0, buildNumber: 2)
        XCTAssertTrue(vBuild1 < vBuild2)
    }

    func testCurrentVersionNotNull() {
        let current = AppVersion.current
        XCTAssertGreaterThanOrEqual(current.major, 1)
        XCTAssertFalse(AppVersion.appName.isEmpty)
    }

    // MARK: - ChangelogManager 更新日志测试
    func testChangelogManager() {
        let manager = ChangelogManager.shared
        XCTAssertFalse(manager.releases.isEmpty)

        // 验证最新发布
        let latest = manager.latestRelease
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.version, "1.0.0")
        XCTAssertFalse(latest?.highlights.isEmpty ?? true)
        XCTAssertFalse(latest?.features.isEmpty ?? true)

        // 验证根据版本号查询
        let v100 = manager.release(for: "1.0.0")
        XCTAssertNotNil(v100)
        XCTAssertEqual(v100?.version, "1.0.0")

        // 验证 Markdown 与 JSON 导出
        let markdown = manager.exportFullChangelogMarkdown()
        XCTAssertTrue(markdown.contains("极译 AI (iTrans) 更新日志与发布历史"))
        XCTAssertTrue(markdown.contains("1.0.0"))

        let json = manager.exportAsJSON()
        XCTAssertTrue(json.contains("\"version\" : \"1.0.0\"") || json.contains("\"version\": \"1.0.0\""))
    }

    func testChangelogRegisterRemoteRelease() {
        let manager = ChangelogManager.shared
        let remoteItem = ReleaseNoteItem(
            version: "9.9.9",
            buildNumber: 99,
            releaseDate: "2029-01-01",
            title: "未来版本测试",
            summary: "测试远端更新注入",
            highlights: ["未来亮点"]
        )

        manager.registerRemoteRelease(remoteItem)
        XCTAssertEqual(manager.latestRelease?.version, "9.9.9")
        XCTAssertEqual(manager.release(for: "9.9.9")?.title, "未来版本测试")
    }

    // MARK: - AppUpdateChecker 检查更新测试
    @MainActor
    func testAppUpdateCheckerEvaluateManifest() {
        let checker = AppUpdateChecker.shared
        let currentVer = AppVersion(string: "1.0.0", buildNumber: 1)!

        // 1. 发现新版本测试
        let updateManifest = UpdateManifest(
            version: "1.2.0",
            build: 10,
            releaseDate: "2026-11-01",
            title: "新版发布",
            summary: "功能优化",
            downloadUrl: "https://example.com/download"
        )
        let result1 = checker.evaluateManifest(updateManifest, currentVer: currentVer)
        XCTAssertTrue(result1.isUpdateAvailable)
        if case .updateAvailable(let latest, let curr, let note, let url) = result1 {
            XCTAssertEqual(latest.description, "1.2.0")
            XCTAssertEqual(curr.description, "1.0.0")
            XCTAssertEqual(note?.title, "新版发布")
            XCTAssertEqual(url?.absoluteString, "https://example.com/download")
        } else {
            XCTFail("应返回 updateAvailable")
        }

        // 2. 当前已是最新版本测试
        let olderManifest = UpdateManifest(
            version: "1.0.0",
            build: 1,
            releaseDate: "2026-10-16",
            title: "当前版本"
        )
        let result2 = checker.evaluateManifest(olderManifest, currentVer: currentVer)
        XCTAssertFalse(result2.isUpdateAvailable)
        if case .upToDate(let curr) = result2 {
            XCTAssertEqual(curr.description, "1.0.0")
        } else {
            XCTFail("应返回 upToDate")
        }

        // 3. 非法版本号测试
        let invalidManifest = UpdateManifest(version: "abc..def")
        let result3 = checker.evaluateManifest(invalidManifest, currentVer: currentVer)
        if case .failed = result3 {
            // 通过
        } else {
            XCTFail("应返回 failed")
        }
    }

    // MARK: - GitHub Release 响应模型解析与评估测试
    @MainActor
    func testEvaluateGitHubRelease() {
        let checker = AppUpdateChecker.shared
        let currentVer = AppVersion(string: "1.0.0", buildNumber: 1)!

        // 1. 发现 GitHub 新版本
        let newerRelease = GitHubReleaseResponse(
            tagName: "v1.0.1",
            name: "iTrans v1.0.1 体验升级",
            body: "修复状态栏悬浮面板动画轻微抖动问题",
            htmlUrl: "https://github.com/cduyzh/iTrans/releases/tag/v1.0.1",
            publishedAt: "2026-11-08T08:00:00Z",
            assets: [
                GitHubReleaseAsset(name: "iTrans-1.0.1.dmg", browserDownloadUrl: "https://github.com/cduyzh/iTrans/releases/download/v1.0.1/iTrans-1.0.1.dmg")
            ]
        )

        let result1 = checker.evaluateGitHubRelease(newerRelease, currentVer: currentVer)
        XCTAssertTrue(result1.isUpdateAvailable)
        if case .updateAvailable(let latest, let curr, let note, let url) = result1 {
            XCTAssertEqual(latest.description, "1.0.1")
            XCTAssertEqual(curr.description, "1.0.0")
            XCTAssertEqual(note?.title, "iTrans v1.0.1 体验升级")
            XCTAssertEqual(url?.absoluteString, "https://github.com/cduyzh/iTrans/releases/download/v1.0.1/iTrans-1.0.1.dmg")
        } else {
            XCTFail("应返回 updateAvailable")
        }

        // 2. 当前版本即最新版
        let sameRelease = GitHubReleaseResponse(
            tagName: "v1.0.0",
            name: "iTrans v1.0.0 正式发布",
            body: "首发版",
            htmlUrl: "https://github.com/cduyzh/iTrans/releases/tag/v1.0.0"
        )
        let result2 = checker.evaluateGitHubRelease(sameRelease, currentVer: currentVer)
        XCTAssertFalse(result2.isUpdateAvailable)
        if case .upToDate(let curr) = result2 {
            XCTAssertEqual(curr.description, "1.0.0")
        } else {
            XCTFail("应返回 upToDate")
        }
    }

    // MARK: - UpdateCheckResult 状态与描述完整性测试
    func testUpdateCheckResultStates() {
        let curr = AppVersion(string: "1.0.0")!
        let latest = AppVersion(string: "1.1.0")!

        let r1 = UpdateCheckResult.upToDate(currentVersion: curr)
        XCTAssertFalse(r1.isUpdateAvailable)
        XCTAssertTrue(r1.statusDescription.contains("当前已是最新版本"))

        let r2 = UpdateCheckResult.updateAvailable(latest: latest, current: curr, releaseNote: nil, downloadUrl: nil)
        XCTAssertTrue(r2.isUpdateAvailable)
        XCTAssertTrue(r2.statusDescription.contains("发现新版本"))

        let r3 = UpdateCheckResult.noRelease
        XCTAssertFalse(r3.isUpdateAvailable)
        XCTAssertEqual(r3.statusDescription, "暂无已发布的正式版本")

        let r4 = UpdateCheckResult.rateLimited(message: "HTTP 403")
        XCTAssertFalse(r4.isUpdateAvailable)
        XCTAssertTrue(r4.statusDescription.contains("GitHub API 请求频率受限"))

        let r5 = UpdateCheckResult.failed(error: "超时")
        XCTAssertFalse(r5.isUpdateAvailable)
        XCTAssertTrue(r5.statusDescription.contains("检查更新失败: 超时"))
    }

    // MARK: - ReleaseHistory.json 与 Info.plist 版本号真值门禁校验
    func testReleaseHistoryMatchesInfoPlist() throws {
        let rhUrl = URL(fileURLWithPath: "Resources/ReleaseHistory.json")
        let rhData = try Data(contentsOf: rhUrl)
        let json = try JSONSerialization.jsonObject(with: rhData) as? [String: Any]
        let releases = json?["releases"] as? [[String: Any]]
        XCTAssertNotNil(releases)
        XCTAssertFalse(releases?.isEmpty ?? true)

        let firstRelease = releases?[0]
        let rhVer = firstRelease?["version"] as? String
        let rhBuild = firstRelease?["build"] as? Int

        XCTAssertEqual(rhVer, "1.0.0")
        XCTAssertEqual(rhBuild, 1)

        // 校验 Info.plist
        let infoUrl = URL(fileURLWithPath: "Info.plist")
        let infoData = try Data(contentsOf: infoUrl)
        let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        let plistVer = info?["CFBundleShortVersionString"] as? String
        let plistBuild = (info?["CFBundleVersion"] as? String).flatMap { Int($0) }

        XCTAssertEqual(plistVer, rhVer, "ReleaseHistory.json 版本必须与 Info.plist 保持一致")
        XCTAssertEqual(plistBuild, rhBuild, "ReleaseHistory.json 构建号必须与 Info.plist 保持一致")
    }

    // MARK: - 自动周期检查调度器生命周期测试
    @MainActor
    func testPeriodicCheckScheduler() {
        let checker = AppUpdateChecker.shared
        checker.startPeriodicCheck()
        // 确保不会崩溃并且可以安全多次调用
        checker.startPeriodicCheck()
        checker.stopPeriodicCheck()
    }

    // MARK: - 网关接口测试 (/v1/version & /v1/changelog)
    func testGatewayVersionEndpoints() async throws {
        let server = AgentGatewayServer.shared
        let testPort: UInt16 = 11989
        server.start(port: testPort)

        try await Task.sleep(nanoseconds: 300_000_000)

        // 测试 /v1/version
        let versionUrl = URL(string: "http://127.0.0.1:\(testPort)/v1/version")!
        let (verData, verResp) = try await URLSession.shared.data(from: versionUrl)
        XCTAssertEqual((verResp as? HTTPURLResponse)?.statusCode, 200)
        let verJson = try JSONSerialization.jsonObject(with: verData) as? [String: Any]
        XCTAssertNotNil(verJson?["version"])
        XCTAssertNotNil(verJson?["app_name"])

        // 测试 /v1/changelog
        let changelogUrl = URL(string: "http://127.0.0.1:\(testPort)/v1/changelog")!
        let (clData, clResp) = try await URLSession.shared.data(from: changelogUrl)
        XCTAssertEqual((clResp as? HTTPURLResponse)?.statusCode, 200)
        let clArray = try JSONSerialization.jsonObject(with: clData) as? [[String: Any]]
        XCTAssertNotNil(clArray)
        XCTAssertFalse(clArray?.isEmpty ?? true)

        server.stop()
    }
}
