import Foundation
import AppKit

/// 检查更新状态结果 (遵循 cduyzh Mac 规范 v2026-10-28.1：明确区分新版可用、已是最新、无正式发布、网络限流与异常失败)
public enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: AppVersion)
    case updateAvailable(latest: AppVersion, current: AppVersion, releaseNote: ReleaseNoteItem?, downloadUrl: URL?)
    case noRelease
    case rateLimited(message: String)
    case failed(error: String)

    public var isUpdateAvailable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var statusDescription: String {
        switch self {
        case .upToDate(let curr):
            return "当前已是最新版本 (v\(curr.description))"
        case .updateAvailable(let latest, let curr, _, _):
            return "发现新版本 v\(latest.description) (当前: v\(curr.description))"
        case .noRelease:
            return "暂无已发布的正式版本"
        case .rateLimited(let msg):
            return "GitHub API 请求频率受限: \(msg)"
        case .failed(let err):
            return "检查更新失败: \(err)"
        }
    }
}

/// GitHub Release 资产结构
public struct GitHubReleaseAsset: Codable, Equatable {
    public let name: String
    public let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }

    public init(name: String, browserDownloadUrl: String) {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }
}

/// GitHub Release 响应模型
public struct GitHubReleaseResponse: Codable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlUrl: String?
    public let publishedAt: String?
    public let assets: [GitHubReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        htmlUrl: String? = nil,
        publishedAt: String? = nil,
        assets: [GitHubReleaseAsset]? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

/// 远端更新清单数据结构 (用于 JSON 解析)
public struct UpdateManifest: Codable, Equatable {
    public let version: String
    public let build: Int?
    public let releaseDate: String?
    public let title: String?
    public let summary: String?
    public let highlights: [String]?
    public let features: [String]?
    public let improvements: [String]?
    public let bugFixes: [String]?
    public let downloadUrl: String?
    public let minMacosVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case releaseDate = "release_date"
        case title
        case summary
        case highlights
        case features
        case improvements
        case bugFixes = "bug_fixes"
        case downloadUrl = "download_url"
        case minMacosVersion = "min_macos_version"
    }

    public init(
        version: String,
        build: Int? = nil,
        releaseDate: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        highlights: [String]? = nil,
        features: [String]? = nil,
        improvements: [String]? = nil,
        bugFixes: [String]? = nil,
        downloadUrl: String? = nil,
        minMacosVersion: String? = nil
    ) {
        self.version = version
        self.build = build
        self.releaseDate = releaseDate
        self.title = title
        self.summary = summary
        self.highlights = highlights
        self.features = features
        self.improvements = improvements
        self.bugFixes = bugFixes
        self.downloadUrl = downloadUrl
        self.minMacosVersion = minMacosVersion
    }
}

/// 应用版本更新检测控制器
@MainActor
public final class AppUpdateChecker: ObservableObject {
    public static let shared = AppUpdateChecker()

    @Published public var isChecking: Bool = false
    @Published public var lastCheckDate: Date?
    @Published public var checkResult: UpdateCheckResult?
    @Published public var hasUpdate: Bool = false
    @Published public var latestVersion: AppVersion?
    @Published public var latestReleaseNote: ReleaseNoteItem?
    @Published public var downloadURL: URL?
    @Published public var errorMessage: String?

    /// 核心更新检测地址配置
    public static let defaultGitHubReleasesAPI = "https://api.github.com/repos/cduyzh/iTrans/releases/latest"
    public static let defaultGitHubRepoAPI = "https://api.github.com/repos/cduyzh/iTrans"
    public static let defaultMirrorManifestURL = "https://apps.cduyzh.top/itrans/version_manifest.json"
    public static let defaultRawManifestURL = "https://raw.githubusercontent.com/cduyzh/iTrans/main/Resources/version_manifest.json"
    public static let defaultProjectReleaseURL = "https://github.com/cduyzh/iTrans/releases"
    public static let defaultManifestURL = defaultRawManifestURL // 兼容旧接口别名

    private let session: URLSession
    private var periodicTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    public init(session: URLSession = .shared) {
        self.session = session
        // 从偏好加载上次检查时间与状态
        self.lastCheckDate = AppSettings.shared.lastUpdateCheckDate
        self.hasUpdate = AppSettings.shared.hasNewUpdateAvailable
        if let verStr = AppSettings.shared.latestAvailableVersion {
            self.latestVersion = AppVersion(string: verStr)
        }
    }

    // MARK: - 核心更新检查逻辑 (阶梯式多源回退)

    /// 执行更新检查
    /// - Parameters:
    ///   - customUrlString: 可选的指定清单或发布地址（通常用于测试）
    ///   - isManual: 是否为用户主动点击手动检查
    @discardableResult
    public func checkForUpdates(customUrlString: String? = nil, isManual: Bool = false) async -> UpdateCheckResult {
        isChecking = true
        errorMessage = nil

        let currentVer = AppVersion.current

        // 1. 若传入自定义更新源，优先请求该源
        if let customUrlStr = customUrlString?.trimmingCharacters(in: .whitespacesAndNewlines), !customUrlStr.isEmpty {
            guard let url = URL(string: customUrlStr) else {
                let res = UpdateCheckResult.failed(error: "无效的更新地址: \(customUrlStr)")
                applyResult(res)
                return res
            }
            let res = await checkSingleURL(url, currentVer: currentVer)
            applyResult(res)
            return res
        }

        // 2. 主线阶梯链路 1: 官方 GitHub Releases API
        let ghResult = await checkGitHubReleasesAPI(currentVer: currentVer)
        switch ghResult {
        case .updateAvailable, .upToDate, .noRelease:
            applyResult(ghResult)
            return ghResult
        case .rateLimited, .failed:
            // GitHub API 遇到限流或网络故障，自动切换至国内高可用 CDN 镜像
            break
        }

        // 3. 主线阶梯链路 2: 国内高速 CDN 镜像 (apps.cduyzh.top/itrans/version_manifest.json)
        if let mirrorURL = URL(string: Self.defaultMirrorManifestURL) {
            let mirrorResult = await checkManifestURL(mirrorURL, currentVer: currentVer)
            switch mirrorResult {
            case .updateAvailable, .upToDate:
                applyResult(mirrorResult)
                return mirrorResult
            case .noRelease, .rateLimited, .failed:
                break
            }
        }

        // 4. 主线阶梯链路 3: Raw GitHub 远端清单兜底
        if let rawURL = URL(string: Self.defaultRawManifestURL) {
            let rawResult = await checkManifestURL(rawURL, currentVer: currentVer)
            switch rawResult {
            case .updateAvailable, .upToDate:
                applyResult(rawResult)
                return rawResult
            case .noRelease, .rateLimited, .failed:
                break
            }
        }

        // 5. 离线兜底: 检查本地更新历史中是否有比当前版本更新的记录
        if let localLatest = ChangelogManager.shared.latestRelease,
           let localLatestVer = AppVersion(string: localLatest.version, buildNumber: localLatest.buildNumber),
           localLatestVer > currentVer {
            let download = localLatest.downloadUrl.flatMap { URL(string: $0) } ?? URL(string: Self.defaultProjectReleaseURL)
            let res = UpdateCheckResult.updateAvailable(
                latest: localLatestVer,
                current: currentVer,
                releaseNote: localLatest,
                downloadUrl: download
            )
            applyResult(res)
            return res
        }

        // 若全部链路均未能成功探查，返回首选 GitHub 探查结果
        applyResult(ghResult)
        return ghResult
    }

    // MARK: - 网络请求子方法

    private func checkGitHubReleasesAPI(currentVer: AppVersion) async -> UpdateCheckResult {
        guard let url = URL(string: Self.defaultGitHubReleasesAPI) else {
            return .failed(error: "GitHub Releases API 地址配置无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iTrans/\(currentVer.description) (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(error: "非法的网络响应")
            }

            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubReleaseResponse.self, from: data)
                return evaluateGitHubRelease(release, currentVer: currentVer)
            case 404:
                if await verifyGitHubRepoExists() {
                    return .noRelease
                }
                return .failed(error: "GitHub 仓库不存在或无法访问 (HTTP 404)")
            case 403, 429:
                return .rateLimited(message: "GitHub API 请求过于频繁或受限 (HTTP \(httpResponse.statusCode))")
            default:
                return .failed(error: "GitHub API 响应异常 (HTTP \(httpResponse.statusCode))")
            }
        } catch {
            return .failed(error: formatNetworkError(error))
        }
    }

    private func verifyGitHubRepoExists() async -> Bool {
        guard let url = URL(string: Self.defaultGitHubRepoAPI) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iTrans (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func checkManifestURL(_ url: URL, currentVer: AppVersion) async -> UpdateCheckResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("iTrans/\(currentVer.description) (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .failed(error: "HTTP 响应错误: \(code)")
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            return evaluateManifest(manifest, currentVer: currentVer)
        } catch {
            return .failed(error: formatNetworkError(error))
        }
    }

    private func checkSingleURL(_ url: URL, currentVer: AppVersion) async -> UpdateCheckResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json, application/json", forHTTPHeaderField: "Accept")
        request.setValue("iTrans/\(currentVer.description) (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(error: "非法的网络响应")
            }

            if httpResponse.statusCode == 404 {
                return .noRelease
            }
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                return .rateLimited(message: "请求受限 (HTTP \(httpResponse.statusCode))")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                return .failed(error: "HTTP 错误: \(httpResponse.statusCode)")
            }

            // 先尝试解码为 GitHubReleaseResponse
            if let release = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: data), !release.tagName.isEmpty {
                return evaluateGitHubRelease(release, currentVer: currentVer)
            }

            // 尝试解码为 UpdateManifest
            if let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) {
                return evaluateManifest(manifest, currentVer: currentVer)
            }

            return .failed(error: "无法识别的更新数据格式")
        } catch {
            return .failed(error: formatNetworkError(error))
        }
    }

    // MARK: - 评估结果并生成 ReleaseNoteItem

    public func evaluateGitHubRelease(_ release: GitHubReleaseResponse, currentVer: AppVersion = AppVersion.current) -> UpdateCheckResult {
        guard let remoteVer = AppVersion(string: release.tagName) else {
            return .failed(error: "无法解析 GitHub Release 版本号: \(release.tagName)")
        }

        // 优先在 assets 中寻找 .dmg 安装包下载链接
        var downloadURL: URL? = nil
        if let dmgAsset = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
            downloadURL = URL(string: dmgAsset.browserDownloadUrl)
        }
        if downloadURL == nil, let htmlUrl = release.htmlUrl {
            downloadURL = URL(string: htmlUrl)
        }
        if downloadURL == nil {
            downloadURL = URL(string: Self.defaultProjectReleaseURL)
        }

        let releaseDateStr: String
        if let pub = release.publishedAt, pub.count >= 10 {
            releaseDateStr = String(pub.prefix(10))
        } else {
            releaseDateStr = "最新发布"
        }

        let noteItem = ReleaseNoteItem(
            version: remoteVer.description,
            buildNumber: remoteVer.buildNumber ?? 1,
            releaseDate: releaseDateStr,
            title: release.name ?? "极译 AI v\(remoteVer.description)",
            summary: release.body ?? "包含功能优化与问题修复",
            highlights: [release.body ?? "包含新版升级特性"],
            features: [],
            improvements: [],
            bugFixes: [],
            downloadUrl: downloadURL?.absoluteString
        )

        ChangelogManager.shared.registerRemoteRelease(noteItem)

        if remoteVer > currentVer {
            return .updateAvailable(
                latest: remoteVer,
                current: currentVer,
                releaseNote: noteItem,
                downloadUrl: downloadURL
            )
        } else {
            return .upToDate(currentVersion: currentVer)
        }
    }

    public func evaluateManifest(_ manifest: UpdateManifest, currentVer: AppVersion = AppVersion.current) -> UpdateCheckResult {
        guard let remoteVer = AppVersion(string: manifest.version, buildNumber: manifest.build) else {
            return .failed(error: "更新清单中的版本格式无法解析: \(manifest.version)")
        }

        let download = manifest.downloadUrl.flatMap { URL(string: $0) } ?? URL(string: Self.defaultProjectReleaseURL)
        let noteItem = ReleaseNoteItem(
            version: manifest.version,
            buildNumber: manifest.build ?? 1,
            releaseDate: manifest.releaseDate ?? "未知日期",
            title: manifest.title ?? "版本更新",
            summary: manifest.summary ?? "",
            highlights: manifest.highlights ?? [],
            features: manifest.features ?? [],
            improvements: manifest.improvements ?? [],
            bugFixes: manifest.bugFixes ?? [],
            downloadUrl: manifest.downloadUrl
        )

        ChangelogManager.shared.registerRemoteRelease(noteItem)

        if remoteVer > currentVer {
            return .updateAvailable(
                latest: remoteVer,
                current: currentVer,
                releaseNote: noteItem,
                downloadUrl: download
            )
        } else {
            return .upToDate(currentVersion: currentVer)
        }
    }

    // MARK: - 结果应用与状态持久化

    private func applyResult(_ result: UpdateCheckResult) {
        self.isChecking = false
        self.checkResult = result
        self.lastCheckDate = Date()
        AppSettings.shared.lastUpdateCheckDate = self.lastCheckDate

        switch result {
        case .updateAvailable(let latest, _, let note, let download):
            self.hasUpdate = true
            self.latestVersion = latest
            self.latestReleaseNote = note
            self.downloadURL = download
            self.errorMessage = nil
            AppSettings.shared.hasNewUpdateAvailable = true
            AppSettings.shared.latestAvailableVersion = latest.description
        case .upToDate:
            self.hasUpdate = false
            self.latestVersion = nil
            self.latestReleaseNote = nil
            self.errorMessage = nil
            AppSettings.shared.hasNewUpdateAvailable = false
            AppSettings.shared.latestAvailableVersion = nil
        case .noRelease:
            self.hasUpdate = false
            self.latestVersion = nil
            self.latestReleaseNote = nil
            self.errorMessage = nil
            AppSettings.shared.hasNewUpdateAvailable = false
            AppSettings.shared.latestAvailableVersion = nil
        case .rateLimited(let msg):
            self.errorMessage = msg
        case .failed(let err):
            self.errorMessage = err
        }
    }

    private func formatNetworkError(_ error: Error) -> String {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost:
                return "无法连接至网络或服务器，请检查网络连接。"
            case NSURLErrorTimedOut:
                return "网络请求超时，请检查网络或配置自定义镜像更新源。"
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - 外部操作与自动化调度

    /// 在默认浏览器中打开下载或发布页面
    public func openDownloadPage() {
        let url = downloadURL ?? URL(string: Self.defaultProjectReleaseURL)!
        NSWorkspace.shared.open(url)
    }

    /// 启动周期性自动检查及系统唤醒监听 (默认每 6 小时检查一次)
    public func startPeriodicCheck() {
        stopPeriodicCheck()

        // 1. 定时器：每 6 小时自动后台检查
        let timer = Timer.scheduledTimer(withTimeInterval: 6.0 * 3600.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutoCheckIfNeeded()
            }
        }
        timer.tolerance = 300.0 // 容许 5 分钟节能窗口
        self.periodicTimer = timer

        // 2. 监听 Mac 系统唤醒通知
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutoCheckIfNeeded()
            }
        }

        // 3. 应用刚启动时延迟 3 秒触发初次静默检查
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.performAutoCheckIfNeeded()
            }
        }
    }

    /// 停止周期检查与清理监听器
    public func stopPeriodicCheck() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// 仅在满足策略且开启偏好时执行自动静默检查
    public func performAutoCheckIfNeeded() {
        guard AppSettings.shared.autoCheckUpdateEnabled else { return }

        // 若距离上次检查不足 6 小时且上次已有确定结果，则跳过以节省带宽
        if let lastDate = AppSettings.shared.lastUpdateCheckDate {
            let hours = Date().timeIntervalSince(lastDate) / 3600.0
            if hours < 6.0 && checkResult != nil {
                return
            }
        }

        Task {
            await checkForUpdates(isManual: false)
        }
    }
}
