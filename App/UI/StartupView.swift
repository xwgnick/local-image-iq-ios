import SwiftUI

/// Static launch and real preparation share this image, size and background.
/// Keep LaunchScreen.storyboard's 192pt constraints in sync with this value.
enum StartupAppearance {
    static let imageName = "LaunchLogo"
    static let backgroundName = "LaunchBackground"
    static let iconSize: CGFloat = 192
    static let progressWidth: CGFloat = 144
    static let progressHeight: CGFloat = 3
    static let progressGap: CGFloat = 28
}

/// The root still owns real preparation and the transition to home.
@MainActor
struct StartupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        StartupContent(phase: state.launchPhase, issue: state.launchIssue,
                       onRetry: { state.retryLaunch() },
                       onOpenHome: { state.openHomeAfterLaunchFailure() },
                       progressFraction: state.startupProgressFraction)
    }
}

/// Normally icon-only; the parent may supply real completed-step progress for a
/// slow preparation. Failure remains icon-only with the original recovery actions.
/// Rendering never starts work, requests permission or advances launch state.
@MainActor
struct StartupContent: View {
    let phase: AppState.LaunchPhase
    let issue: String?
    let onRetry: () -> Void
    let onOpenHome: () -> Void
    let progressFraction: Double?

    init(phase: AppState.LaunchPhase, issue: String?,
         onRetry: @escaping () -> Void, onOpenHome: @escaping () -> Void,
         progressFraction: Double? = nil) {
        self.phase = phase
        self.issue = issue
        self.onRetry = onRetry
        self.onOpenHome = onOpenHome
        self.progressFraction = progressFraction
    }

    var canRecover: Bool { phase == .failed }

    var visibleProgressFraction: Double? {
        guard phase == .checkingLibrary || phase == .preparingSearch else { return nil }
        return StartupStepProgressBar.sanitizedFraction(progressFraction)
    }

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

    func handleRecoveryGesture(_ result: ExclusiveGesture<LongPressGesture, TapGesture>.Value) {
        switch result {
        case .first(let completed):
            if completed { openHomeIfFailed() }
        case .second: retryIfFailed()
        }
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
                        .onEnded(handleRecoveryGesture))
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
        .overlay(alignment: .center) {
            if let fraction = visibleProgressFraction {
                StartupStepProgressBar(fraction: fraction)
                    .offset(y: StartupAppearance.iconSize / 2 + StartupAppearance.progressGap
                            + StartupAppearance.progressHeight / 2)
            }
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
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

/// A deterministic, noninteractive capsule. No clock, estimated progress or
/// animation: the width changes only when the caller supplies another fraction.
struct StartupStepProgressBar: View {
    let fraction: Double

    static func sanitizedFraction(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    var fillWidth: CGFloat {
        StartupAppearance.progressWidth * CGFloat(Self.sanitizedFraction(fraction) ?? 0)
    }

    // VoiceOver only; never rendered as a label on the launch screen.
    var accessibilityProgress: String {
        let percent = Int(((Self.sanitizedFraction(fraction) ?? 0) * 100).rounded())
        return "已完成 \(percent)%"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(IQStyle.line)
            if fillWidth > 0 {
                Capsule().fill(IQStyle.accent)
                    .frame(width: fillWidth)
            }
        }
        .frame(width: StartupAppearance.progressWidth, height: StartupAppearance.progressHeight)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("启动准备进度")
        .accessibilityValue(accessibilityProgress)
        .accessibilityIdentifier("startup-step-progress")
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}