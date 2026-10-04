import Foundation
import SwiftUI

/// Display metadata only. The caller owns debug gating and bottom-leading
/// placement; this view never requests, renders or inspects the source image.
@MainActor
struct ThumbnailDiagnosticOverlay: View {
    private let thumbnail: CachedThumbnail

    init(thumbnail: CachedThumbnail) {
        self.thumbnail = thumbnail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: ThumbnailDiagnosticPresentation.selectedLines(for: thumbnail)
                .joined(separator: "\n"))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: ThumbnailDiagnosticPresentation.attemptSummary(for: thumbnail))
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.78))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pure text seam shared with native presentation tests. Four logical lines may
/// wrap. Only the route is visually limited to three lines (with an ellipsis);
/// selected metadata is not shrunk or silently truncated to fit a small tile.
enum ThumbnailDiagnosticPresentation {
    static func lines(for thumbnail: CachedThumbnail) -> [String] {
        selectedLines(for: thumbnail) + [attemptSummary(for: thumbnail)]
    }

    static func selectedLines(for thumbnail: CachedThumbnail) -> [String] {
        let result = thumbnail.result
        let delivery = thumbnail.cacheHit ? "缓存命中" : "本次请求"
        let degraded: String
        switch result.degraded {
        case true?: degraded = "是"
        case false?: degraded = "否"
        case nil: degraded = "未知"
        }
        return [
            "\(result.stage.rawValue) · \(delivery)",
            "返回 \(dimensions(result.returnedSize)) · 请求 \(dimensions(result.requestedSize))",
            "降质：\(degraded) · \(cacheSummary(for: thumbnail))"
        ]
    }

    static func attemptSummary(for thumbnail: CachedThumbnail) -> String {
        let attempts = thumbnail.result.attempts
        let label = thumbnail.cacheHit ? "尝试（缓存记录）" : "尝试"
        guard !attempts.isEmpty else { return "\(label)：未记录" }
        let countLabel = thumbnail.cacheHit ? "尝试（缓存记录·\(attempts.count)）" : "尝试（\(attempts.count)）"
        let route = attempts.map { "\(shortStage($0.stage)) \(shortOutcome($0.outcome))" }
            .joined(separator: " → ")
        return "\(countLabel)：\(route)"
    }

    /// Raw metadata, not oriented dimensions or UIImage point sizes. Preserve
    /// finite fractions rather than rounding a request up or a tiny value to 0.
    static func dimensions(_ size: CGSize) -> String {
        guard hasDimensions(size) else { return "未知" }
        return "\(dimension(size.width))×\(dimension(size.height))"
    }

    static func cacheSummary(for thumbnail: CachedThumbnail) -> String {
        if thumbnail.cacheHit { return "已缓存" }
        let result = thumbnail.result
        // Eligibility is NOT a promise that NSCache still retains this entry.
        // In particular, a nil degraded flag is allowed by the actual policy.
        if result.isReusable { return "可缓存" }
        var reasons: [String] = []
        if !result.isSufficientForDisplay {
            reasons.append(hasDimensions(result.returnedSize) && hasDimensions(result.requestedSize)
                           ? "像素不足" : "尺寸未知")
        }
        if result.degraded == true { reasons.append("降质") }
        if result.stage == .localFast224 { reasons.append("Fast") }
        if result.stage == .unknown { reasons.append("来源未知") }
        // Do not invent a cause if the result's cache policy gains a new rule.
        return "未缓存(\(reasons.isEmpty ? "原因未知" : reasons.joined(separator: "/")))"
    }

    private static func hasDimensions(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func dimension(_ value: CGFloat) -> String {
        let text = String(describing: value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func shortStage(_ stage: DisplayThumbnailStage) -> String {
        switch stage {
        case .localHQ: return "大图HQ"
        case .localHQ224: return "HQ224"
        case .networkHQ: return "联网HQ"
        case .localFast224: return "Fast224"
        case .unknown: return "未知"
        }
    }

    private static func shortOutcome(_ outcome: String) -> String {
        // Exact fixed loader labels only. Never interpolate an unknown string:
        // adapters could put error descriptions or private metadata in it.
        switch outcome {
        case "native return": return "返回"
        case "需网络": return "需网"
        case "无可用像素": return "无图"
        default: return "未知"
        }
    }
}