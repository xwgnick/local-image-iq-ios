import Foundation
import SwiftUI

/// The app entry owns start() and the transition to home. Merely rendering this
/// view must not request permission, start work or restart preparation.
@MainActor
struct StartupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        StartupContent(phase: state.launchPhase, issue: state.launchIssue,
                       onRetry: { state.retryLaunch() },
                       onOpenHome: { state.openHomeAfterLaunchFailure() })
    }
}

/// A render-only surface: no AppState instance, Photos, models or tasks required.
/// `issue` must be the parent's sanitized launchIssue, never a raw error dump.
@MainActor
struct StartupContent: View {
    let phase: AppState.LaunchPhase
    let issue: String?
    let onRetry: () -> Void
    let onOpenHome: () -> Void

    var phaseText: String {
        switch phase {
        case .pending: return "等待启动准备"
        case .checkingLibrary: return "检查照片访问与索引"
        case .preparingSearch: return "准备本机搜索模型"
        case .failed: return "启动暂未完成"
        case .ready: return "准备就绪"
        }
    }

    var isLoading: Bool {
        phase == .checkingLibrary || phase == .preparingSearch
    }

    var showsRecoveryActions: Bool { phase == .failed }

    var detailText: String {
        switch phase {
        case .pending:
            return "即将检查已有照片索引。"
        case .checkingLibrary:
            return "检查现有记录，不会重新处理照片。"
        case .preparingSearch:
            return "请保持应用在前台，完成后会自动进入。"
        case .failed:
            guard let issue, !issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "暂时无法完成启动准备。可以重试，或先进入应用查看状态。"
            }
            return IQStyle.diagnosticText(issue)
        case .ready:
            return "即将进入应用。"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(spacing: 32) {
                        brand
                        preparation
                    }
                    .frame(maxWidth: 420)
                    Spacer(minLength: 32)
                    privacy
                        .frame(maxWidth: 420)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                // A minimum, not a fixed viewport height: large text and long
                // sanitized errors grow naturally and remain scrollable.
                .frame(minHeight: max(0, geometry.size.height))
            }
        }
        .background(IQStyle.background.ignoresSafeArea())
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .accessibilityElement(children: .contain)
        // Do not put an identifier on this ancestor: SwiftUI can propagate it
        // to child buttons. The visible brand Text is the screen-presence anchor.
    }

    private var brand: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(IQStyle.accent)
                Image(systemName: "photo")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(IQStyle.onAccent)
                    .offset(x: -5, y: -5)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(IQStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(IQStyle.accentSoft, in: Circle())
                    .overlay(Circle().strokeBorder(IQStyle.accent, lineWidth: 3))
                    .offset(x: 24, y: 23)
            }
            .frame(width: 92, height: 92)
            .accessibilityHidden(true)

            Text("Image IQ")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("startup-screen")
            Text("找回那一刻。")
                .font(.title3)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }

    private var preparation: some View {
        VStack(spacing: 16) {
            if isLoading {
                // Indeterminate system spinner only while real work is active.
                // The phase Text carries its accessible meaning, without a
                // second spinner announcement or fabricated completion value.
                ProgressView()
                    .progressViewStyle(.circular)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: phase == .failed ? "exclamationmark.circle" :
                        (phase == .ready ? "checkmark.circle" : "hourglass"))
                    .font(.title2)
                    .foregroundStyle(IQStyle.accent)
                    .accessibilityHidden(true)
            }

            Text(phaseText)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("startup-phase")
                .accessibilityLabel("启动状态")
                .accessibilityValue(phaseText)
            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsRecoveryActions {
                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        actionLabel("重试")
                            .foregroundStyle(IQStyle.onAccent)
                            .background(IQStyle.accent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityIdentifier("startup-retry")
                    .accessibilityHint("重新检查照片访问、索引与本机搜索准备")

                    Button(action: onOpenHome) {
                        actionLabel("先进入应用")
                            .foregroundStyle(IQStyle.accent)
                            .background(IQStyle.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityIdentifier("startup-open-home")
                    .accessibilityHint("进入应用查看状态；搜索是否可用取决于准备结果")
                }
                .buttonStyle(.plain)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(IQStyle.line))
    }

    private func actionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
    }

    private var privacy: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.body)
                .foregroundStyle(IQStyle.secondary)
                .padding(10)
                .background(IQStyle.muted, in: Circle())
                .accessibilityHidden(true)
            Text("本机处理 · 不上传照片或搜索内容到应用服务器")
            Text("不会重新建立照片索引")
        }
        .font(.footnote)
        .foregroundStyle(IQStyle.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}