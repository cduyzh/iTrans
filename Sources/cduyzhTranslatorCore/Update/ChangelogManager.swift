import Foundation

/// 单个版本的更新日志条目
public struct ReleaseNoteItem: Identifiable, Codable, Hashable {
    public var id: String { version }
    
    public let version: String
    public let buildNumber: Int
    public let releaseDate: String
    public let title: String
    public let summary: String
    public let highlights: [String]
    public let features: [String]
    public let improvements: [String]
    public let bugFixes: [String]
    public let downloadUrl: String?

    public init(
        version: String,
        buildNumber: Int,
        releaseDate: String,
        title: String,
        summary: String,
        highlights: [String] = [],
        features: [String] = [],
        improvements: [String] = [],
        bugFixes: [String] = [],
        downloadUrl: String? = nil
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.releaseDate = releaseDate
        self.title = title
        self.summary = summary
        self.highlights = highlights
        self.features = features
        self.improvements = improvements
        self.bugFixes = bugFixes
        self.downloadUrl = downloadUrl
    }

    /// 格式化为精美的 Markdown 文本
    public var markdownRepresentation: String {
        var lines: [String] = []
        lines.append("## \(version) (\(releaseDate)) - \(title)")
        lines.append("")
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        if !highlights.isEmpty {
            lines.append("### 🌟 核心亮点")
            for h in highlights {
                lines.append("- \(h)")
            }
            lines.append("")
        }
        if !features.isEmpty {
            lines.append("### ✨ 新增功能")
            for f in features {
                lines.append("- \(f)")
            }
            lines.append("")
        }
        if !improvements.isEmpty {
            lines.append("### ⚡️ 体验与性能优化")
            for i in improvements {
                lines.append("- \(i)")
            }
            lines.append("")
        }
        if !bugFixes.isEmpty {
            lines.append("### 🐞 问题修复")
            for b in bugFixes {
                lines.append("- \(b)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 本地 ReleaseHistory.json 解码模型
private struct LocalReleaseHistory: Decodable {
    let releases: [LocalReleaseEntry]
}

private struct LocalReleaseEntry: Decodable {
    let version: String
    let build: Int?
    let releaseDate: String?
    let title: String?
    let summary: String?
    let highlights: [String]?
    let changes: LocalReleaseChanges?
    let downloadUrl: String?
}

private struct LocalReleaseChanges: Decodable {
    let new: [String]?
    let improvements: [String]?
    let fixes: [String]?
}

/// 更新日志与发版记录管理器
public final class ChangelogManager {
    public static let shared = ChangelogManager()

    /// 内置历史版本全量更新日志
    public private(set) var releases: [ReleaseNoteItem] = []

    private init() {
        self.releases = Self.loadReleases()
    }

    /// 重置为初始内置发布历史 (用于状态重置与单元测试隔离)
    public func resetToDefaults() {
        self.releases = Self.loadReleases()
    }

    /// 从本地资源或默认列表加载发布日志
    public static func loadReleases() -> [ReleaseNoteItem] {
        if let history = loadFromReleaseHistoryJSON(), !history.isEmpty {
            return history
        }
        return loadDefaultReleases()
    }

    private static func loadFromReleaseHistoryJSON() -> [ReleaseNoteItem]? {
        let possibleUrls: [URL?] = [
            Bundle.main.url(forResource: "ReleaseHistory", withExtension: "json"),
            Bundle(for: ChangelogManager.self).url(forResource: "ReleaseHistory", withExtension: "json"),
            URL(fileURLWithPath: "Resources/ReleaseHistory.json")
        ]

        for case let url? in possibleUrls {
            guard let data = try? Data(contentsOf: url),
                  let history = try? JSONDecoder().decode(LocalReleaseHistory.self, from: data),
                  !history.releases.isEmpty else {
                continue
            }

            return history.releases.map { entry in
                ReleaseNoteItem(
                    version: entry.version,
                    buildNumber: entry.build ?? 1,
                    releaseDate: entry.releaseDate ?? "2026-11-06",
                    title: entry.title ?? "版本 v\(entry.version)",
                    summary: entry.summary ?? "",
                    highlights: entry.highlights ?? [],
                    features: entry.changes?.new ?? [],
                    improvements: entry.changes?.improvements ?? [],
                    bugFixes: entry.changes?.fixes ?? [],
                    downloadUrl: entry.downloadUrl
                )
            }
        }
        return nil
    }

    /// 获取最新版本更新日志
    public var latestRelease: ReleaseNoteItem? {
        return releases.first
    }

    /// 获取对应版本的更新日志
    public func release(for version: String) -> ReleaseNoteItem? {
        let clean = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return releases.first { $0.version == clean }
    }

    /// 导出为完整 Markdown 文档
    public func exportFullChangelogMarkdown() -> String {
        var doc = "# 极译 AI (iTrans) 更新日志与发布历史\n\n"
        for release in releases {
            doc += release.markdownRepresentation + "\n---\n\n"
        }
        return doc
    }

    /// 导出为 JSON 字符串
    public func exportAsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(releases),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    /// 注入/合并来自远端更新源的新版更新日志
    public func registerRemoteRelease(_ item: ReleaseNoteItem) {
        if let idx = releases.firstIndex(where: { $0.version == item.version }) {
            releases[idx] = item
        } else {
            // 按版本号逆序插入
            releases.insert(item, at: 0)
            releases.sort { (r1, r2) -> Bool in
                let v1 = AppVersion(string: r1.version) ?? AppVersion(major: 0, minor: 0, patch: 0)
                let v2 = AppVersion(string: r2.version) ?? AppVersion(major: 0, minor: 0, patch: 0)
                return v1 > v2
            }
        }
    }

    // MARK: - 内置发布历史数据
    private static func loadDefaultReleases() -> [ReleaseNoteItem] {
        return [
            ReleaseNoteItem(
                version: "1.0.0",
                buildNumber: 1,
                releaseDate: "2026-11-06",
                title: "极译 AI (iTrans) 官方正式版发布",
                summary: "专为 macOS 打造的原生极速划词翻译与 AI 深度思考工具，深度集成 Google 与 DeepSeek 双引擎，支持网络俚语深度释义与本地自学习记忆库。",
                highlights: [
                    "macOS 原生轻量架构，纯 Swift/SwiftUI 开发，内存占用仅约 25MB，启动低于 200ms。",
                    "Google Web RPC 与 DeepSeek 大模型双引擎支持，自带 Key 官方直连，告别月租订阅。",
                    "突破传统机翻瓶颈：支持网络俚语（如 wtf）与缩写语境深度释义，自动解析语气、用法与地道表达。",
                    "全局 Command+C+C 双击即选即译与 Option+Z 快捷键，无缝嵌入 Safari、Xcode 与各类阅读器。",
                    "纯原生 SwiftUI 毛玻璃卡片悬浮状态控制面板，支持开机启动、一键缓存释放与状态自检。"
                ],
                features: [
                    "Google 免费 RPC 与 DeepSeek 双引擎快速切换（Option+E）",
                    "网络俚语/缩写语境释义模式与反思模型思考过程展开",
                    "全局 Command+C+C 双击与 Option+Z 划词秒翻",
                    "本地自学习个人翻译记忆库与专业知识库管理",
                    "原生 SwiftUI 二级更多功能抽屉与开机自启动微开关",
                    "本地 Agent Gateway (127.0.0.1:11899) 与 CLI 接口"
                ],
                improvements: [
                    "优化状态栏悬浮面板层级与交互动效，提供沉浸式 Native 视觉体验",
                    "纯原生 SwiftUI + AppKit 架构，启动速度低于 200ms",
                    "API Key 与配置以 0600 权限保存在本机受保护目录，本地优先且零云端追踪"
                ],
                bugFixes: [
                    "首发版本正式发布并通过全部单元测试与安全合规门禁"
                ]
            )
        ]
    }
}
