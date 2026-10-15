import AppKit
import SwiftUI

/// Sections stacked top to bottom, each as tall as its share of the room, with a handle between
/// each pair that drags height from one to the other. The shares are kept under `key` across
/// launches; double-clicking a handle puts the shares back to `defaults`.
struct SplitColumn: View {
    let key: String
    /// Each section's share of the room at first; they need not sum to 1.
    let defaults: [Double]
    /// The least height of each section, in points: a drag stops there.
    let minimums: [CGFloat]
    /// The handle's height: the gap between sections.
    var gap: CGFloat = 12
    let sections: [AnyView]

    @AppStorage private var stored: String
    @State private var dragStart: [Double]?
    /// The shares while a handle is dragged; saved when it is let go, not at every step.
    @State private var live: [Double]?
    @State private var hovered: Int?

    init(key: String, defaults: [Double], minimums: [CGFloat], gap: CGFloat = 12, sections: [AnyView]) {
        self.key = key
        self.defaults = defaults
        self.minimums = minimums
        self.gap = gap
        self.sections = sections
        _stored = AppStorage(wrappedValue: "", key)
    }

    /// The shares now: those kept, if they fit this column, else the defaults.
    private var shares: [Double] {
        if let live { return live }
        let kept = stored.split(separator: ",").compactMap { Double($0) }
        let raw = kept.count == sections.count && kept.allSatisfy({ $0 > 0 }) ? kept : defaults
        let sum = raw.reduce(0, +)
        return raw.map { $0 / max(sum, 0.0001) }
    }

    var body: some View {
        GeometryReader { geo in
            let room = max(geo.size.height - gap * CGFloat(sections.count - 1), 0)
            let heights = Self.layout(shares, room: room, minimums: minimums)
            VStack(spacing: 0) {
                ForEach(sections.indices, id: \.self) { i in
                    sections[i].frame(height: heights[i])
                    if i < sections.count - 1 { handle(i, room: room) }
                }
            }
        }
    }

    /// Heights from shares: each its share of the room, but none under its minimum, the room a
    /// minimum takes coming out of the others in proportion.
    static func layout(_ shares: [Double], room: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
        var h = shares.map { CGFloat($0) * room }
        for _ in 0..<shares.count {
            let short = h.indices.filter { h[$0] < minimums[$0] }
            guard !short.isEmpty else { break }
            let need = short.reduce(0) { $0 + minimums[$1] - h[$1] }
            for i in short { h[i] = minimums[i] }
            let others = h.indices.filter { !short.contains($0) && h[$0] > minimums[$0] }
            let spare = others.reduce(0) { $0 + h[$1] - minimums[$1] }
            guard spare > 0 else { break }
            for i in others { h[i] -= need * (h[i] - minimums[i]) / spare }
        }
        return h
    }

    private func handle(_ i: Int, room: CGFloat) -> some View {
        Rectangle().fill(.clear).frame(height: gap).frame(maxWidth: .infinity).contentShape(Rectangle())
            .overlay {
                // Always faintly there, so the gap reads as something to drag; plain on hover.
                Capsule().fill(Alive.ink3.opacity(hovered == i || dragStart != nil ? 0.6 : 0.22))
                    .frame(width: hovered == i || dragStart != nil ? 52 : 36, height: 4)
                    .animation(.easeOut(duration: 0.12), value: hovered)
            }
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push(); hovered = i } else { NSCursor.pop(); hovered = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = dragStart ?? shares
                        if dragStart == nil { dragStart = start }
                        guard room > 0 else { return }
                        let pair = start[i] + start[i + 1]
                        let lo = Double(minimums[i] / room), hi = pair - Double(minimums[i + 1] / room)
                        guard hi > lo else { return }
                        var s = start
                        s[i] = min(max(start[i] + Double(v.translation.height / room), lo), hi)
                        s[i + 1] = pair - s[i]
                        live = s
                    }
                    .onEnded { _ in
                        if let live { stored = live.map { String(format: "%.4f", $0) }.joined(separator: ",") }
                        live = nil
                        dragStart = nil
                    }
            )
            .onTapGesture(count: 2) {
                live = nil
                stored = ""
            }
            .help("Drag to resize; double-click to put the sizes back")
    }
}
