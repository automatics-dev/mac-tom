import SwiftUI

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (i, pos) in result.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }
    private struct R { var size: CGSize; var positions: [CGPoint] }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> R {
        let w = proposal.width ?? .infinity
        var p: [CGPoint] = []; var x: CGFloat = 0; var y: CGFloat = 0; var rh: CGFloat = 0; var th: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rh + spacing; rh = 0 }
            p.append(CGPoint(x: x, y: y)); rh = max(rh, sz.height); x += sz.width + spacing; th = y + rh
        }
        return R(size: CGSize(width: w, height: th), positions: p)
    }
}
