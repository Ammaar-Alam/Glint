import SwiftUI

// maps source seconds to points along a timeline of the given width
struct VideoTimelineScale: Equatable {
    var duration: Double
    var width: Double
    var inset: Double = 16

    static let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]

    var pointsPerSecond: Double { duration > 0 ? max(0, width - inset * 2) / duration : 0 }
    var tickStep: Double { Self.steps.first { $0 * pointsPerSecond >= 72 } ?? Self.steps[Self.steps.count - 1] }

    func x(_ time: Double) -> Double { inset + min(duration, max(0, time)) * pointsPerSecond }

    func time(_ x: Double) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return min(duration, max(0, (x - inset) / pointsPerSecond))
    }
}

enum VideoFrameStrip {
    // power of two so a denser strip reuses every frame already decoded
    static func density(for tiles: Int) -> Int {
        var density = 8
        while density < min(512, tiles) { density *= 2 }
        return density
    }

    static func times(duration: Double, density: Int) -> [Double] {
        guard duration > 0, density > 0 else { return [] }
        return (0..<density).map { Double($0) * duration / Double(density) }
    }
}

struct VideoFrame {
    let time: Double
    let image: CGImage
}

private enum Lane {
    static let ruler: CGFloat = 22
    static let strip: CGFloat = 52
    static let zoom: CGFloat = 24
    static let cut: CGFloat = 20
    static let gap: CGFloat = 7
    static let height = ruler + strip + zoom + cut + gap * 3 + 12
    static let space = "timeline"
}

struct VideoTimelineView: View {
    @Bindable var model: VideoEditorModel
    let project: VideoProject
    @State private var zoom = 1.0
    @State private var pinchBase: Double?
    @State private var viewport = 0.0
    @State private var offset = 0.0
    @State private var position = ScrollPosition(x: 0)

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                gutter
                GeometryReader { geometry in
                    let scale = scale(viewport: geometry.size.width, zoom: zoom)
                    ScrollView(.horizontal) {
                        lanes(scale)
                    }
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x } action: { offset = $1 }
                    .onAppear { viewport = geometry.size.width }
                    .onChange(of: geometry.size.width) { viewport = $1 }
                    .task(id: tiles(scale)) { model.loadFrames(tiles: tiles(scale)) }
                }
            }
            .frame(height: Lane.height)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchBase == nil { pinchBase = zoom }
                    setZoom((pinchBase ?? zoom) * value.magnification)
                }
                .onEnded { _ in pinchBase = nil })
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { model.removeRange(start: model.sourceTime, end: model.sourceTime + 1) } label: { Image(systemName: "scissors") }
                .help("Cut at playhead")
            Button { model.addZoom() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Add zoom")
            Button(action: model.smartZooms) { Image(systemName: "wand.and.sparkles") }
                .help("Zoom on clicks").disabled(project.clicks.isEmpty)
            Divider().frame(height: 16).padding(.horizontal, 6)
            Button { model.edit { $0.trimStart = 0; $0.trimEnd = project.duration; $0.cuts = [] } } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Restore full length")
                .disabled(project.edits.cuts.isEmpty && project.edits.trimStart == 0 && project.edits.trimEnd == project.duration)
            Spacer()
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus") }
                .help("Zoom out").disabled(zoom <= 1)
            Slider(value: Binding(get: { log(zoom) }, set: { setZoom(exp($0)) }), in: 0...log(20))
                .controlSize(.mini).frame(width: 92)
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus") }
                .help("Zoom in").disabled(zoom >= 20)
        }
        .buttonStyle(ToolButtonStyle(size: CGSize(width: 28, height: 26)))
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var gutter: some View {
        VStack(spacing: Lane.gap) {
            Color.clear.frame(height: Lane.ruler)
            icon("film", height: Lane.strip)
            icon("plus.magnifyingglass", height: Lane.zoom)
            icon("scissors", height: Lane.cut)
        }
        .frame(width: 30)
        .padding(.leading, 6)
    }

    private func icon(_ name: String, height: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).frame(height: height)
    }

    private func lanes(_ scale: VideoTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Lane.gap) {
                TimelineRuler(scale: scale, offset: offset, viewport: viewport)
                    .frame(width: scale.width, height: Lane.ruler, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(scrub(scale))
                FrameStripLane(model: model, project: project, scale: scale, offset: offset, viewport: viewport, scrub: scrub(scale))
                ZoomLane(model: model, project: project, scale: scale)
                CutLane(model: model, project: project, scale: scale)
            }
            TimelinePlayhead(model: model, project: project, scale: scale, offset: offset, viewport: viewport, position: $position)
        }
        .frame(width: scale.width, alignment: .leading)
        .padding(.bottom, 12)
        .coordinateSpace(.named(Lane.space))
    }

    private func scrub(_ scale: VideoTimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Lane.space)).onChanged { value in
            model.seek(to: project.outputTime(at: scale.time(value.location.x)))
        }
    }

    private func scale(viewport: Double, zoom: Double) -> VideoTimelineScale {
        VideoTimelineScale(duration: project.duration, width: max(1, viewport) * zoom)
    }

    private func tiles(_ scale: VideoTimelineScale) -> Int {
        let tile = Lane.strip * Double(project.width) / Double(max(1, project.height))
        return Int(ceil((scale.width - scale.inset * 2) / max(8, tile)))
    }

    private func setZoom(_ value: Double) {
        let next = min(20, max(1, value))
        guard next != zoom, viewport > 0 else { return }
        let current = scale(viewport: viewport, zoom: zoom), target = scale(viewport: viewport, zoom: next)
        let playhead = current.x(model.sourceTime) - offset
        let anchor = (0...viewport).contains(playhead) ? model.sourceTime : current.time(offset + viewport / 2)
        let onScreen = current.x(anchor) - offset
        zoom = next
        position.scrollTo(x: min(max(0, target.width - viewport), max(0, target.x(anchor) - onScreen)))
    }
}

private struct TimelineRuler: View {
    let scale: VideoTimelineScale
    let offset: Double
    let viewport: Double

    var body: some View {
        Canvas { context, size in
            let step = scale.tickStep
            var time = max(0, floor(scale.time(offset) / step) * step)
            while time <= scale.duration + step / 2 {
                let x = scale.x(time) - offset
                if x > size.width + 60 { break }
                context.fill(Path(CGRect(x: x - 0.5, y: size.height - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.7)))
                for minor in 1..<4 {
                    let minorTime = time + step * Double(minor) / 4
                    guard minorTime < scale.duration else { break }
                    context.fill(Path(CGRect(x: scale.x(minorTime) - offset - 0.5, y: size.height - 3, width: 1, height: 3)), with: .color(.secondary.opacity(0.35)))
                }
                if x + 30 < size.width { context.draw(Text(Self.label(time, step: step)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 4, y: size.height / 2 - 2), anchor: .leading) }
                time += step
            }
        }
        .frame(width: max(1, viewport))
        .offset(x: offset)
    }

    static func label(_ time: Double, step: Double) -> String {
        let minutes = Int(time) / 60, seconds = time - Double(minutes * 60)
        return step < 1 ? String(format: "%d:%04.1f", minutes, seconds) : String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }
}

private struct FrameStripLane<Scrub: Gesture>: View {
    let model: VideoEditorModel
    let project: VideoProject
    let scale: VideoTimelineScale
    let offset: Double
    let viewport: Double
    let scrub: Scrub
    @State private var dragOrigin: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(width: max(1, viewport), height: Lane.strip)
                .offset(x: offset)
                .contentShape(Rectangle())
                .gesture(scrub)
            bracket
        }
        .frame(width: scale.width, height: Lane.strip, alignment: .topLeading)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let track = CGRect(x: scale.x(0) - offset, y: 0, width: scale.x(scale.duration) - scale.x(0), height: size.height)
        let shape = Path(roundedRect: track, cornerRadius: 7, style: .continuous)
        context.fill(shape, with: .color(.primary.opacity(0.08)))
        context.clip(to: shape)
        let tile = size.height * Double(project.width) / Double(max(1, project.height))
        var index = max(0, Int(floor((offset - scale.inset) / tile)))
        while true {
            let x = scale.inset + Double(index) * tile
            if x - offset > size.width || x >= scale.x(scale.duration) { break }
            if let image = model.frame(near: scale.time(x + tile / 2)) {
                context.draw(Image(decorative: image, scale: 2), in: CGRect(x: x - offset, y: 0, width: tile, height: size.height))
            }
            index += 1
        }
        func span(_ start: Double, _ end: Double) -> CGRect {
            CGRect(x: scale.x(start) - offset, y: 0, width: max(0, scale.x(end) - scale.x(start)), height: size.height)
        }
        for removed in [span(0, project.edits.trimStart), span(project.edits.trimEnd, scale.duration)] {
            context.fill(Path(removed), with: .color(.black.opacity(0.6)))
        }
        for cut in project.edits.cuts {
            let rect = span(cut.start, cut.end)
            context.fill(Path(rect), with: .color(.black.opacity(0.55)))
            var hatch = Path()
            var x = rect.minX - size.height
            while x < rect.maxX {
                hatch.move(to: CGPoint(x: x, y: size.height)); hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            var clipped = context
            clipped.clip(to: Path(rect))
            clipped.stroke(hatch, with: .color(.white.opacity(0.16)), lineWidth: 1)
        }
    }

    private var bracket: some View {
        let start = scale.x(project.edits.trimStart), end = scale.x(project.edits.trimEnd)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.glint, lineWidth: 2.5)
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
            handle(edge: \.trimStart).frame(maxWidth: .infinity, alignment: .leading)
            handle(edge: \.trimEnd).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: end - start + 20, height: Lane.strip)
        .offset(x: start - 10)
    }

    private func handle(edge: WritableKeyPath<VideoEdits, Double>) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == \.trimStart ? .init(topLeading: 7, bottomLeading: 7) : .init(bottomTrailing: 7, topTrailing: 7), style: .continuous)
            .fill(Color.glint)
            .overlay(Capsule().fill(Color.onGlint.opacity(0.7)).frame(width: 2, height: 16))
            .frame(width: 11)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Lane.space))
                .onChanged { value in
                    let origin = dragOrigin ?? scale.x(project.edits[keyPath: edge])
                    dragOrigin = origin
                    model.set(edge, scale.time(origin + value.translation.width))
                }
                .onEnded { _ in
                    dragOrigin = nil
                    model.seek(to: edge == \.trimStart ? 0 : model.duration)
                })
    }
}

private struct ZoomLane: View {
    let model: VideoEditorModel
    let project: VideoProject
    let scale: VideoTimelineScale
    @State private var hover: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneTrack(scale: scale)
                .onContinuousHover(coordinateSpace: .named(Lane.space)) { phase in
                    if case .active(let point) = phase { hover = scale.time(point.x) } else { hover = nil }
                }
                .onTapGesture(coordinateSpace: .named(Lane.space)) { point in
                    model.addZoom(at: scale.time(point.x))
                    model.panel = .zoom
                }
            if let hover, !project.edits.zooms.contains(where: { hover >= $0.start && hover <= $0.start + $0.duration }) {
                let start = min(max(project.edits.trimStart, hover), max(project.edits.trimStart, project.edits.trimEnd - 0.5))
                let end = min(project.edits.trimEnd, start + 3)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.zoomLane.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .overlay(Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.zoomLane))
                    .frame(width: max(12, scale.x(end) - scale.x(start)), height: Lane.zoom)
                    .offset(x: scale.x(start))
                    .allowsHitTesting(false)
            }
            ForEach(project.edits.zooms) { zoom in
                TimelineSegment(range: zoom.start...(zoom.start + zoom.duration), bounds: 0...project.duration, scale: scale,
                                tint: .zoomLane, selected: model.selectedZoom == zoom.id, height: Lane.zoom,
                                symbol: zoom.followsCursor ? "cursorarrow" : "scope", label: String(format: "%.1f×", zoom.scale),
                                commit: { start, end in model.updateZoom(zoom.id) { $0.start = start; $0.duration = end - start } },
                                select: {
                                    model.selectedZoom = zoom.id; model.panel = .zoom
                                    model.seek(to: project.outputTime(at: zoom.start + min(0.5, zoom.duration / 2)))
                                },
                                remove: { model.removeZoom(zoom.id) })
            }
        }
        .frame(width: scale.width, height: Lane.zoom, alignment: .topLeading)
    }
}

private struct CutLane: View {
    let model: VideoEditorModel
    let project: VideoProject
    let scale: VideoTimelineScale
    @State private var draft: ClosedRange<Double>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneTrack(scale: scale)
                .help("Drag to cut")
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Lane.space))
                    .onChanged { value in
                        let a = scale.time(value.startLocation.x), b = scale.time(value.location.x)
                        draft = min(a, b)...max(a, b)
                    }
                    .onEnded { _ in
                        if let draft { model.removeRange(start: draft.lowerBound, end: draft.upperBound) }
                        draft = nil
                    })
            if let draft {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.cutLane.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.cutLane, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .frame(width: max(2, scale.x(draft.upperBound) - scale.x(draft.lowerBound)), height: Lane.cut)
                    .offset(x: scale.x(draft.lowerBound))
                    .allowsHitTesting(false)
            }
            ForEach(project.edits.cuts) { cut in
                TimelineSegment(range: cut.start...cut.end, bounds: 0...project.duration, scale: scale,
                                tint: .cutLane, selected: false, height: Lane.cut, symbol: "scissors", label: nil,
                                commit: { start, end in model.updateCut(cut.id, start: start, end: end) },
                                remove: { model.edit { $0.cuts.removeAll { $0.id == cut.id } } })
            }
        }
        .frame(width: scale.width, height: Lane.cut, alignment: .topLeading)
    }
}

private struct LaneTrack: View {
    let scale: VideoTimelineScale

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .frame(width: scale.x(scale.duration) - scale.x(0))
            .offset(x: scale.x(0))
            .frame(width: scale.width, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct TimelineSegment: View {
    let range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    let scale: VideoTimelineScale
    let tint: Color
    let selected: Bool
    let height: CGFloat
    let symbol: String
    let label: String?
    let commit: (Double, Double) -> Void
    var select: (() -> Void)?
    let remove: () -> Void
    @State private var draft: ClosedRange<Double>?
    @State private var mode: Mode?
    @State private var hovering = false

    private enum Mode { case move, start, end }

    var body: some View {
        let shown = draft ?? range
        let x = scale.x(shown.lowerBound), width = max(8, scale.x(shown.upperBound) - x)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape
            .fill(tint.opacity(selected ? 0.9 : hovering || draft != nil ? 0.34 : 0.22))
            .overlay(shape.strokeBorder(tint.opacity(selected ? 1 : 0.6), lineWidth: 1))
            .overlay(alignment: .leading) {
                if width > 34 {
                    HStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                        if let label, width > 64 { Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
                    }
                    .foregroundStyle(selected ? Color.white : tint)
                    .padding(.leading, 8)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                HStack(spacing: 0) { edge; Spacer(minLength: 0); edge }
            }
            .overlay(alignment: .trailing) {
                if hovering, draft == nil, width > 52 {
                    Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).background(Circle().fill(.regularMaterial)) }
                        .buttonStyle(.plain).padding(.trailing, 9).help("Remove")
                }
            }
            .frame(width: width, height: height)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { select?() }
            .gesture(drag)
            .contextMenu { Button("Remove", action: remove) }
            .offset(x: x)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var edge: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle()).pointerStyle(.columnResize)
            .overlay(Capsule().fill(selected ? Color.white.opacity(0.8) : tint).frame(width: 2, height: height * 0.45).opacity(hovering || selected ? 1 : 0))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Lane.space))
            .onChanged { value in
                let x0 = scale.x(range.lowerBound), x1 = scale.x(range.upperBound)
                let mode = mode ?? (value.startLocation.x - x0 < 9 ? .start : x1 - value.startLocation.x < 9 ? .end : .move)
                self.mode = mode
                let delta = scale.pointsPerSecond > 0 ? value.translation.width / scale.pointsPerSecond : 0
                let minimum = min(0.1, range.upperBound - range.lowerBound)
                switch mode {
                case .move:
                    let length = range.upperBound - range.lowerBound
                    let start = min(bounds.upperBound - length, max(bounds.lowerBound, range.lowerBound + delta))
                    draft = start...(start + length)
                case .start:
                    draft = min(range.upperBound - minimum, max(bounds.lowerBound, range.lowerBound + delta))...range.upperBound
                case .end:
                    draft = range.lowerBound...max(range.lowerBound + minimum, min(bounds.upperBound, range.upperBound + delta))
                }
            }
            .onEnded { _ in
                if let draft, draft != range { commit(draft.lowerBound, draft.upperBound) }
                draft = nil; mode = nil
            }
    }
}

private struct TimelinePlayhead: View {
    let model: VideoEditorModel
    let project: VideoProject
    let scale: VideoTimelineScale
    let offset: Double
    let viewport: Double
    @Binding var position: ScrollPosition

    var body: some View {
        let x = scale.x(model.sourceTime)
        VStack(spacing: 0) {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 3, bottomLeading: 5, bottomTrailing: 5, topTrailing: 3), style: .continuous)
                .fill(Color.primary)
                .frame(width: 11, height: 15)
            Rectangle().fill(Color.primary).frame(width: 1.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 1.5)
        .frame(height: Lane.height - 12)
        .offset(x: x - 5.5)
        .allowsHitTesting(false)
        .onChange(of: model.currentTime) {
            guard model.isPlaying, viewport > 0, x > offset + viewport - 24 || x < offset else { return }
            position.scrollTo(x: min(max(0, scale.width - viewport), max(0, x - 24)))
        }
    }
}

extension Color {
    static let zoomLane = Color(nsColor: .systemIndigo)
    static let cutLane = Color(nsColor: .systemRed)
}
