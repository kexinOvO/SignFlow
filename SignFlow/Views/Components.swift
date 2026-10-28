import SwiftUI
import AppKit

struct Surface<Content: View>: View {
    var title: String?
    var fillsHeight: Bool
    @ViewBuilder var content: Content
    init(_ title: String? = nil, fillsHeight: Bool = false, @ViewBuilder content: () -> Content) { self.title = title; self.fillsHeight = fillsHeight; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PageHeading<Actions: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions
    init(_ title: String, subtitle: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) { self.title = title; self.subtitle = subtitle; self.actions = actions() }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 28, weight: .bold)); Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 12); actions
        }.padding(.bottom, 8)
    }
}

struct StatusPill: View {
    var title: String
    var color: Color = .secondary
    var symbol: String = "circle.fill"
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
            .lineLimit(1).fixedSize()
    }
}

struct InstalledProfileEstimateView: View {
    var status: InstalledProfileEstimateStatus
    var showExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch status {
            case .available(let estimate):
                Text("预计 Profile 到期：\(estimate.expirationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                Text("上次安装确认：\(estimate.installationConfirmedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                if showExplanation {
                    Text("依据 SignFlow 安装记录推算；设备签名未直接读取。其他方式重新安装可能改变期限。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .unavailable(let reason):
                Text("预计 Profile 到期：无法确认（\(reason.description)）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

extension SignatureHealth {
    var color: Color { switch self { case .valid: return .green; case .expiring: return .orange; case .expired, .invalid: return .red; default: return .secondary } }
    var symbol: String { switch self { case .valid: return "checkmark.circle.fill"; case .expiring: return "clock.fill"; case .expired, .invalid: return "exclamationmark.circle.fill"; default: return "questionmark.circle" } }
}
extension TaskPhase {
    var color: Color { switch self { case .completed: return .green; case .failed: return .red; case .partialSuccess, .waitingUser, .retryableFailure: return .orange; case .cancelled: return .secondary; default: return .blue } }
}
extension InstallationState {
    var color: Color { switch self { case .installed: return .green; case .failed: return .red; case .awaitingWatchSync: return .orange; default: return .secondary } }
}

struct EmptyPanel: View {
    var title: String
    var detail: String
    var symbol: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(.blue).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6) }
        }.frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}

struct InfoRow: View {
    var title: String
    var value: String
    var isIdentifier = false

    var body: some View {
        Group {
            if isIdentifier {
                stackedContent
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        titleText
                        Spacer(minLength: 0)
                        valueText.fixedSize()
                    }
                    stackedContent
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value.isEmpty ? "未识别" : value)
    }

    private var titleText: some View {
        Text(title).foregroundStyle(.secondary).fixedSize()
    }

    private var valueText: some View {
        Text(value.isEmpty ? "未识别" : value)
            .font(isIdentifier ? .system(.callout, design: .monospaced) : .body)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
            valueText
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ErrorPanel: View {
    var error: FlowError
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            if !error.suggestion.isEmpty { Text(error.suggestion).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !error.technical.isEmpty { DisclosureGroup("技术信息") { Text(error.technical).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProjectArtwork: View {
    var project: ManagedProject
    var size: CGFloat = 52
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    private var request: ProjectIconRequest {
        ProjectIconRequest(projectPath: project.path, targetName: project.primaryTarget?.name,
                           otherTargetNames: project.targets.filter { $0.id != project.primaryTarget?.id }.map(\.name),
                           platform: project.primaryTarget?.platform,
                           artifactPath: project.artifactPath, customIconPath: project.customIconPath,
                           prefersDark: colorScheme == .dark)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.blue.opacity(0.12)
                Image(systemName: project.primaryTarget?.platform == .watchOS ? "applewatch" : "app.dashed")
                    .font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.blue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil
            let current = request
            let loaded = await Task.detached(priority: .utility) { ProjectIconResolver.resolve(current) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct ExpiryView: View {
    var signatures: [SignedBundle]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let summary = SignatureExpirySummary(signatures: signatures, at: context.date) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("本地产物有效期").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(summary.remainingText).font(.caption.weight(.medium)).foregroundStyle(summary.health.color)
                    }
                    ProgressView(value: summary.remainingFraction).tint(summary.health.color)
                    Text(summary.expirationDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack { Image(systemName: "clock.badge.questionmark"); Text("尚无本地产物签名基线") }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
            }
        }
    }
}

extension SignatureExpirySummary {
    var remainingText: String { remainingDays.map { "剩余 \($0) 天" } ?? "已到期" }
}
