import SwiftUI

/// Static launch and real preparation share this image, size and background.
/// Keep LaunchScreen.storyboard's 192pt constraints in sync with this value.
enum StartupAppearance {
    static let imageName = "LaunchLogo"
    static let backgroundName = "LaunchBackground"
    static let iconSize: CGFloat = 192
}

/// The root still owns real preparation and the transition to home.
@MainActor
struct StartupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        StartupContent(phase: state.launchPhase, issue: state.launchIssue,
                       onRetry: { state.retryLaunch() },
                       onOpenHome: { state.openHomeAfterLaunchFailure() })
    }
}

/// One static image is the entire visible surface, including on failure.
/// Rendering never starts work, requests permission or advances launch state.
@MainActor
struct StartupContent: View {
    let phase: AppState.LaunchPhase
    let issue: String?
    let onRetry: () -> Void
    let onOpenHome: () -> Void

    var canRecover: Bool { phase == .failed }

    // VoiceOver-only information; no status/error text is drawn on screen.
    var accessibilityStatus: String {
        switch phase {
        case .failed:
            guard let issue, !issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "启动暂未完成"
            }
            return IQStyle.diagnosticText(issue)
        case .ready: return "准备就绪"
        default: return "正在准备应用"
        }
    }

    func retryIfFailed() {
        guard canRecover else { return }
        onRetry()
    }

    func openHomeIfFailed() {
        guard canRecover else { return }
        onOpenHome()
    }

    var body: some View {
        ZStack {
            Color(StartupAppearance.backgroundName)
                .accessibilityHidden(true)
            if canRecover {
                logo
                    .contentShape(Rectangle())
                    // A long press must not also trigger the retry tap.
                    .gesture(LongPressGesture(minimumDuration: 1).exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first(let completed):
                                if completed { openHomeIfFailed() }
                            case .second: retryIfFailed()
                            }
                        })
                    .accessibilityLabel("应用图标，启动暂未完成")
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityHint("轻点重试；长按先进入应用。也可使用辅助功能操作。")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("startup-recovery-icon")
                    .accessibilityAction { retryIfFailed() }
                    .accessibilityAction(named: Text("重试")) { retryIfFailed() }
                    .accessibilityAction(named: Text("先进入应用")) { openHomeIfFailed() }
            } else {
                logo
                    .accessibilityLabel("应用图标")
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityIdentifier("startup-icon")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .transaction { transaction in transaction.animation = nil }
    }

    private var logo: some View {
        Image(StartupAppearance.imageName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: StartupAppearance.iconSize, height: StartupAppearance.iconSize)
            .accessibilityElement(children: .ignore)
    }
}