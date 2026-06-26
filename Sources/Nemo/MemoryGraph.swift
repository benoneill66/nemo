import SwiftUI

// MARK: - Memory graph (Obsidian-style "brain")

/// A force-directed map of the memory graph. Each memory is a node tinted by its category and
/// sized by importance; edges are the explicit `links` between memories (solid) plus the
/// implicit connections formed by shared `entities` (faint). The layout settles under a tiny
/// physics simulation that runs while the view is on screen, and reheats when nodes are dragged
/// or the underlying memories change. Pan by dragging the canvas, zoom with a pinch/scroll, tap
/// a node to open it in the detail panel.

/// One undirected edge between two memories. `strong` edges are explicit links; weak edges come
/// from a shared entity.
struct GraphEdge: Hashable {
    let a: UUID
    let b: UUID
    let strong: Bool
}

/// Builds the edge set for a slice of memories. Explicit links win over shared-entity links, and
/// every pair is emitted once. Large entity clusters fall back to a star (everyone linked to a
/// representative) so a popular name doesn't explode into O(n²) hairballs.
func graphEdges(for memories: [Memory]) -> [GraphEdge] {
    let present = Set(memories.map(\.id))
    var strong = Set<[UUID]>()      // unordered key [min,max]
    var weak = Set<[UUID]>()

    func key(_ x: UUID, _ y: UUID) -> [UUID] { x.uuidString < y.uuidString ? [x, y] : [y, x] }

    for m in memories {
        for l in m.links where present.contains(l) && l != m.id {
            strong.insert(key(m.id, l))
        }
    }

    // Group memories by entity, then connect them.
    var byEntity: [String: [UUID]] = [:]
    for m in memories {
        for e in m.entities {
            let norm = e.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty else { continue }
            byEntity[norm, default: []].append(m.id)
        }
    }
    for (_, ids) in byEntity {
        let uniq = Array(Set(ids))
        guard uniq.count >= 2 else { continue }
        if uniq.count <= 6 {
            for i in 0..<uniq.count {
                for j in (i + 1)..<uniq.count { weak.insert(key(uniq[i], uniq[j])) }
            }
        } else {
            let hub = uniq[0]
            for other in uniq.dropFirst() { weak.insert(key(hub, other)) }
        }
    }

    var edges = strong.map { GraphEdge(a: $0[0], b: $0[1], strong: true) }
    for w in weak where !strong.contains(w) {
        edges.append(GraphEdge(a: w[0], b: w[1], strong: false))
    }
    return edges
}

// MARK: - Simulation

/// A lightweight force-directed layout. Kept as a plain reference object (no `@Published`) so the
/// per-frame `step` doesn't trigger SwiftUI re-renders — the enclosing `TimelineView` drives redraw.
final class GraphSim: ObservableObject {
    private struct Body { var pos: CGPoint; var vel: CGVector = .zero }

    private var bodies: [UUID: Body] = [:]
    private var order: [UUID] = []          // stable order for deterministic initial placement
    private(set) var edges: [GraphEdge] = []
    var dragging: UUID? = nil
    private var center = CGPoint(x: 400, y: 300)
    private var alpha: Double = 1           // cooling factor; reheats to 1 on interaction

    // Tuned for a layout spanning a few hundred points.
    private let repulsion: CGFloat = 2600
    private let spring: CGFloat = 0.045
    private let restStrong: CGFloat = 78
    private let restWeak: CGFloat = 120
    private let centerPull: CGFloat = 0.013
    private let damping: CGFloat = 0.85

    func position(_ id: UUID) -> CGPoint? { bodies[id]?.pos }

    /// Pin a node to a point (used while dragging).
    func place(_ id: UUID, at p: CGPoint) {
        bodies[id]?.pos = p
        bodies[id]?.vel = .zero
    }

    func reheat() { alpha = 1 }

    /// Reconcile the body set with the current memories/edges, preserving positions of survivors
    /// and seeding newcomers on a golden-angle spiral around the current center.
    func sync(ids: [UUID], edges: [GraphEdge]) {
        self.edges = edges
        let wanted = Set(ids)
        bodies = bodies.filter { wanted.contains($0.key) }
        order.removeAll { !wanted.contains($0) }
        for id in ids where bodies[id] == nil {
            let i = order.count
            let angle = Double(i) * 2.399963229728653       // golden angle
            let r = 36 + 15 * sqrt(Double(i))
            bodies[id] = Body(pos: CGPoint(x: center.x + CGFloat(cos(angle)) * CGFloat(r),
                                           y: center.y + CGFloat(sin(angle)) * CGFloat(r)))
            order.append(id)
        }
        reheat()
    }

    /// Advance the simulation one tick toward `center`. Returns the body count so it can be invoked
    /// from a `ViewBuilder` via `let _ = ...`.
    @discardableResult
    func step(center: CGPoint) -> Int {
        self.center = center
        // Lazily seed any body that hasn't been placed near a real center yet is already handled in sync.
        guard alpha > 0.012 || dragging != nil else { return bodies.count }
        alpha = max(0, alpha * 0.985)

        let ids = order
        var force: [UUID: CGVector] = [:]
        for id in ids { force[id] = .zero }

        // Repulsion between every pair.
        for i in 0..<ids.count {
            let a = ids[i]
            guard let pa = bodies[a]?.pos else { continue }
            for j in (i + 1)..<ids.count {
                let b = ids[j]
                guard let pb = bodies[b]?.pos else { continue }
                var dx = pa.x - pb.x, dy = pa.y - pb.y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = CGFloat(i - j); dy = CGFloat((i + j) % 7 - 3); d2 = dx * dx + dy * dy + 0.01 }
                let dist = sqrt(d2)
                let mag = min(repulsion / d2, 60)
                let ux = dx / dist, uy = dy / dist
                force[a]?.dx += ux * mag; force[a]?.dy += uy * mag
                force[b]?.dx -= ux * mag; force[b]?.dy -= uy * mag
            }
        }

        // Springs along edges.
        for e in edges {
            guard let pa = bodies[e.a]?.pos, let pb = bodies[e.b]?.pos else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let dist = max(sqrt(dx * dx + dy * dy), 0.01)
            let rest = e.strong ? restStrong : restWeak
            let mag = spring * (dist - rest) * (e.strong ? 1 : 0.5)
            let ux = dx / dist, uy = dy / dist
            force[e.a]?.dx += ux * mag; force[e.a]?.dy += uy * mag
            force[e.b]?.dx -= ux * mag; force[e.b]?.dy -= uy * mag
        }

        // Gentle centering + integration.
        for id in ids {
            guard var body = bodies[id] else { continue }
            if id == dragging { continue }
            var f = force[id] ?? .zero
            f.dx += (center.x - body.pos.x) * centerPull
            f.dy += (center.y - body.pos.y) * centerPull
            body.vel.dx = (body.vel.dx + f.dx) * damping
            body.vel.dy = (body.vel.dy + f.dy) * damping
            let speed = sqrt(body.vel.dx * body.vel.dx + body.vel.dy * body.vel.dy)
            if speed > 40 { body.vel.dx *= 40 / speed; body.vel.dy *= 40 / speed }
            body.pos.x += body.vel.dx * CGFloat(alpha)
            body.pos.y += body.vel.dy * CGFloat(alpha)
            bodies[id] = body
        }
        return bodies.count
    }
}

// MARK: - Graph view

struct MemoryGraphView: View {
    let memories: [Memory]
    let selectedId: UUID?
    let onSelect: (Memory) -> Void

    @StateObject private var sim = GraphSim()
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var hoverId: UUID? = nil
    @State private var dragNodeStart: CGPoint? = nil

    /// A cheap signature of the graph's *shape* so we only re-sync when nodes/links/entities
    /// change — not on every reinforcement tweak to a memory's weight.
    private var signature: String {
        memories.map { "\($0.id.uuidString)|\($0.links.count)|\($0.entities.joined(separator: ","))" }
            .joined(separator: ";")
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // Pan surface.
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { v in pan = CGSize(width: panBase.width + v.translation.width,
                                                           height: panBase.height + v.translation.height) }
                            .onEnded { _ in panBase = pan }
                    )

                TimelineView(.animation) { tl in
                    let _ = tl.date
                    let _ = sim.step(center: center)
                    ZStack {
                        Canvas { ctx, _ in
                            for e in sim.edges {
                                guard let a = sim.position(e.a), let b = sim.position(e.b) else { continue }
                                let lit = e.a == selectedId || e.b == selectedId
                                    || e.a == hoverId || e.b == hoverId
                                var path = Path()
                                path.move(to: a); path.addLine(to: b)
                                let base = e.strong ? 0.16 : 0.06
                                ctx.stroke(path,
                                           with: .color(.white.opacity(lit ? base + 0.35 : base)),
                                           lineWidth: e.strong ? (lit ? 1.8 : 1.0) : (lit ? 1.0 : 0.5))
                            }
                        }
                        ForEach(memories) { mem in
                            if let p = sim.position(mem.id) {
                                NodeDot(mem: mem,
                                        selected: mem.id == selectedId,
                                        hovered: mem.id == hoverId)
                                    .position(p)
                                    .onHover { hoverId = $0 ? mem.id : (hoverId == mem.id ? nil : hoverId) }
                                    .gesture(nodeGesture(mem))
                            }
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(pan)
                }
                .allowsHitTesting(true)

                controls
            }
            .clipped()
            .onAppear { sim.sync(ids: memories.map(\.id), edges: graphEdges(for: memories)) }
            .onChange(of: signature) { _ in
                sim.sync(ids: memories.map(\.id), edges: graphEdges(for: memories))
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { zoom = min(max(zoomBase * $0, 0.35), 2.6) }
                .onEnded { _ in zoomBase = zoom }
        )
    }

    private func nodeGesture(_ mem: Memory) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragNodeStart == nil {
                    dragNodeStart = sim.position(mem.id)
                    sim.dragging = mem.id
                }
                if let s = dragNodeStart {
                    sim.place(mem.id, at: CGPoint(x: s.x + v.translation.width / zoom,
                                                  y: s.y + v.translation.height / zoom))
                    sim.reheat()
                }
            }
            .onEnded { v in
                let moved = abs(v.translation.width) + abs(v.translation.height)
                if moved < 5 { onSelect(mem) }
                dragNodeStart = nil
                sim.dragging = nil
            }
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    GraphIconButton(symbol: "minus.magnifyingglass") { setZoom(zoom - 0.25) }
                    GraphIconButton(symbol: "plus.magnifyingglass") { setZoom(zoom + 0.25) }
                    GraphIconButton(symbol: "arrow.counterclockwise") {
                        withAnimation(.easeOut(duration: 0.25)) {
                            zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
                        }
                        sim.reheat()
                    }
                }
                .padding(6)
                .glassCard(cornerRadius: 12)
            }
            Spacer()
            HStack {
                Text("drag the canvas to pan · pinch to zoom · tap a node to open")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
        }
        .padding(10)
        .allowsHitTesting(true)
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) { zoom = min(max(z, 0.35), 2.6); zoomBase = zoom }
    }
}

// MARK: - Pieces

/// A single memory rendered as a glowing dot, sized by importance, with a label that appears on
/// hover/selection (and for the most important nodes, always).
private struct NodeDot: View {
    let mem: Memory
    let selected: Bool
    let hovered: Bool

    private var color: Color { Color(hue: mem.categoryEnum.hue, saturation: 0.7, brightness: 1) }
    private var size: CGFloat { 13 + CGFloat(mem.importance) * 3 + (mem.pinned ? 3 : 0) }
    private var showLabel: Bool { selected || hovered || mem.importance >= 4 }

    var body: some View {
        Circle()
            .fill(color.opacity(selected ? 1 : 0.82))
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3),
                                      lineWidth: selected ? 2 : 0.6)
            )
            .overlay(alignment: .top) {
                if mem.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 7))
                        .foregroundStyle(.yellow.opacity(0.9)).offset(y: -3)
                }
            }
            .shadow(color: color.opacity(selected || hovered ? 0.8 : 0.5),
                    radius: selected || hovered ? 12 : 5)
            .overlay(alignment: .bottom) {
                if showLabel {
                    Text(mem.title)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.35)))
                        .offset(y: size / 2 + 11)
                }
            }
            .animation(.easeOut(duration: 0.18), value: selected)
            .animation(.easeOut(duration: 0.18), value: hovered)
    }
}

private struct GraphIconButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}
