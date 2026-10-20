import AppKit
import CoreImage
import CoreText

enum ImageRenderer {
    static func render(_ contents: ImageProjectContents, maximumDimension: CGFloat? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let document = try contents.document.validated()
        let scale = maximumDimension.map { min(document.outputScale, $0 / max(document.canvasSize.width, document.canvasSize.height)) } ?? document.outputScale
        let crop = document.cropRect
        let work = try bitmap(size: crop.size, scale: scale)
        work.scaleBy(x: scale, y: scale)
        work.translateBy(x: -crop.minX, y: -crop.minY)
        try Task.checkCancellation()
        drawImage(contents.source, in: CGRect(origin: .zero, size: document.sourceSize), context: work)
        for annotation in document.renderingAnnotations {
            try Task.checkCancellation()
            if annotation.tool == .blur || annotation.tool == .pixelate {
                try drawObscured(annotation, context: work, crop: crop, scale: scale)
            } else {
                drawAnnotation(annotation, context: work, imageBounds: crop, insertedImages: contents.insertedImages)
            }
        }
        guard let content = work.makeImage() else { throw GlintError.message("The image couldn’t be rendered.") }
        try Task.checkCancellation()
        if !document.background.enabled && document.quarterTurns == 0 && !document.flipHorizontal && !document.flipVertical { return content }
        let inset = document.backgroundInset
        let styledSize = CGSize(width: document.contentSize.width + 2 * inset, height: document.contentSize.height + 2 * inset)
        let styled = try bitmap(size: styledSize, scale: scale)
        styled.scaleBy(x: scale, y: scale)
        if document.background.enabled {
            let radius = min(document.background.cornerRadius, min(document.contentSize.width, document.contentSize.height) / 2)
            if inset > 0 {
                styled.setFillColor((document.background.insetColor ?? .white).cgColor)
                styled.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: styledSize),
                                      cornerWidth: radius + inset, cornerHeight: radius + inset, transform: nil))
                styled.fillPath()
            }
            styled.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: document.contentSize.width, height: document.contentSize.height),
                                  cornerWidth: radius, cornerHeight: radius, transform: nil))
            styled.clip()
        }
        styled.concatenate(document.originalToCanvas.concatenating(CGAffineTransform(
            translationX: inset - document.contentOrigin.x, y: inset - document.contentOrigin.y)))
        drawImage(content, in: crop, context: styled)
        guard let styledImage = styled.makeImage() else { throw GlintError.message("The image couldn’t be styled.") }
        if !document.background.enabled { return styledImage }
        let final = try bitmap(size: document.canvasSize, scale: scale)
        final.scaleBy(x: scale, y: scale)
        let canvasBounds = CGRect(origin: .zero, size: document.canvasSize)
        if document.background.enabled {
            let background = document.background
            if let imageID = background.imageID {
                guard let image = contents.insertedImages[imageID] else { throw GlintError.message("The background image is missing.") }
                let ratio = max(canvasBounds.width / CGFloat(image.width), canvasBounds.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
                drawImage(image, in: CGRect(x: canvasBounds.midX - size.width / 2, y: canvasBounds.midY - size.height / 2,
                                          width: size.width, height: size.height), context: final)
            } else if background.gradient,
               let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                         colors: [background.color.cgColor, background.secondColor.cgColor] as CFArray,
                                         locations: [0, 1]) {
                final.drawLinearGradient(gradient, start: .zero,
                                         end: CGPoint(x: canvasBounds.maxX, y: canvasBounds.maxY), options: [])
            } else {
                final.setFillColor(background.color.cgColor)
                final.fill(canvasBounds)
            }
            if background.shadow > 0 {
                final.setShadow(offset: CGSize(width: 0, height: background.shadow / 3),
                                blur: background.shadow, color: CGColor(gray: 0, alpha: 0.4))
            }
        }
        drawImage(styledImage, in: CGRect(x: document.contentOrigin.x - inset, y: document.contentOrigin.y - inset,
                                         width: styledSize.width, height: styledSize.height), context: final)
        guard let result = final.makeImage() else { throw GlintError.message("The image couldn’t be rendered.") }
        return result
    }

    static func bitmap(size: CGSize, scale: CGFloat) throws -> CGContext {
        try Task.checkCancellation()
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard width <= 100_000, height <= 100_000, width * height <= 80_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw GlintError.message("This image is too large to render. Try a smaller export size.")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        return context
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func drawAnnotation(_ item: ImageAnnotation, context: CGContext, imageBounds: CGRect,
                               insertedImages: [UUID: CGImage] = [:]) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(item.color.cgColor)
        context.setFillColor(item.color.cgColor)
        context.setLineWidth(item.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let rect = item.rect.standardized
        switch item.tool {
        case .line, .arrow, .curvedArrow, .pen:
            guard let start = item.points.first, let end = item.points.last else { return }
            context.beginPath()
            context.move(to: start)
            var arrowFrom = start
            if item.tool == .curvedArrow {
                let control = item.points.count > 2 ? item.points[1] : CGPoint(x: end.x, y: start.y)
                context.addQuadCurve(to: end, control: control)
                arrowFrom = control
            } else if item.tool == .pen, item.points.count > 2 {
                for index in 1..<item.points.count - 1 {
                    let current = item.points[index], next = item.points[index + 1]
                    context.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2), control: current)
                }
                context.addLine(to: end)
            } else { item.points.dropFirst().forEach { context.addLine(to: $0) } }
            context.strokePath()
            if item.tool == .arrow || item.tool == .curvedArrow {
                let angle = atan2(end.y - arrowFrom.y, end.x - arrowFrom.x)
                let length = max(12, item.lineWidth * 3.5)
                context.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                context.addLine(to: end)
                context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        case .rectangle:
            if item.filled { context.fill(rect) } else { context.stroke(rect) }
        case .ellipse:
            if item.filled { context.fillEllipse(in: rect) } else { context.strokeEllipse(in: rect) }
        case .highlight:
            context.setBlendMode(.multiply)
            context.setAlpha(0.30)
            context.fill(rect)
        case .redact:
            // solid redaction must replace all source pixels regardless of selected color opacity
            context.setBlendMode(.copy)
            context.setFillColor(CGColor(srgbRed: item.color.red, green: item.color.green, blue: item.color.blue, alpha: 1))
            context.setShouldAntialias(false)
            context.fill(rect.integral)
        case .spotlight:
            context.setFillColor(CGColor(gray: 0, alpha: 0.58))
            context.addRect(imageBounds)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath(using: .evenOdd)
        case .counter:
            context.fillEllipse(in: rect)
            let text = String(item.number)
            drawText(text, in: rect, fontSize: min(rect.height * 0.62, item.fontSize),
                     color: .white, bold: true, italic: false, centered: true, context: context)
        case .text:
            drawText(item.text, in: rect, fontSize: item.fontSize, color: item.color,
                     bold: item.bold, italic: item.italic, context: context)
        case .image:
            if let id = item.imageID, let image = insertedImages[id] { drawImage(image, in: rect, context: context) }
        case .pixelate, .blur, .select, .crop: break
        }
    }

    private static func drawText(_ text: String, in rect: CGRect, fontSize: CGFloat, color: AnnotationColor,
                                 bold: Bool, italic: Bool, centered: Bool = false, context: CGContext) {
        var font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }
        if italic { traits.insert(.italicTrait) }
        if let styled = CTFontCreateCopyWithSymbolicTraits(font, fontSize, nil, traits, traits) { font = styled }
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ])
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        if centered {
            let line = CTLineCreateWithAttributedString(string)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: (rect.width - width) / 2,
                                           y: (rect.height - CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 + CTFontGetDescent(font))
            CTLineDraw(line, context)
        } else {
            let setter = CTFramesetterCreateWithAttributedString(string)
            let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        }
        context.restoreGState()
    }

    private static func drawObscured(_ item: ImageAnnotation, context: CGContext, crop: CGRect, scale: CGFloat) throws {
        let rect = item.rect.standardized.intersection(crop)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }
        let pixelRect = CGRect(x: (rect.minX - crop.minX) * scale, y: (rect.minY - crop.minY) * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        guard let snapshot = context.makeImage(), let region = snapshot.cropping(to: pixelRect) else {
            throw GlintError.message("The selected area couldn’t be obscured.")
        }
        let input = CIImage(cgImage: region)
        let result: CIImage
        if item.tool == .pixelate {
            result = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(3, item.lineWidth * 3 * scale),
                kCIInputCenterKey: CIVector(x: 0, y: 0)
            ]).cropped(to: input.extent)
        } else {
            result = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(2, item.lineWidth * 2 * scale)
            ]).cropped(to: input.extent)
        }
        let renderer = CIContext(options: [.cacheIntermediates: false])
        guard let image = renderer.createCGImage(result, from: input.extent) else {
            throw GlintError.message("The selected area couldn’t be obscured.")
        }
        drawImage(image, in: rect, context: context)
    }
}
