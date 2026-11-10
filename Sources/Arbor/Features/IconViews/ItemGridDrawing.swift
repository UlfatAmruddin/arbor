import AppKit
import ArborCore

/// Geometry and drawing for the icon, Tiles and Content layouts, in Windows 11 style.
extension ItemGridView {
    // MARK: Text measurement (cached; visible items only)

    private func attributes(_ font: NSFont, color: NSColor, alignment: NSTextAlignment = .left,
                            lineBreak: NSLineBreakMode = .byWordWrapping, underline: Bool = false) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }   // Folder Options › Underline icon titles
        return attributes
    }

    /// Height of `text` wrapped to `width` with the label font.
    func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
        let key = "\(Int(width))|\(text)" as NSString
        if let hit = heightCache.object(forKey: key) { return CGFloat(hit.doubleValue) }
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 10_000),
                                                   options: [.usesLineFragmentOrigin],
                                                   attributes: attributes(metrics.nameFont, color: .labelColor, alignment: .center))
        let height = ceil(rect.height)
        heightCache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }

    /// Name under an icon: whole if it fits, else shortened in the middle to keep the extension (DEC-013).
    func fittedLabel(_ text: String, width: CGFloat, lines: Int) -> String {
        let limit = CGFloat(lines) * metrics.lineHeight + 1
        if wrappedHeight(text, width: width) <= limit { return text }
        let key = "\(Int(width))|\(lines)|\(text)" as NSString
        if let hit = textCache.object(forKey: key) { return hit as String }
        let fitted = MiddleTruncation.fit(text) { self.wrappedHeight($0, width: width) <= limit }
        textCache.setObject(fitted as NSString, forKey: key)
        return fitted
    }

    // MARK: Geometry

    private var labelInset: CGFloat { 4 }

    func geometry(_ i: Int, expanded: Bool = false) -> ItemGeometry {
        let cell = layout.frame(at: i)
        let m = metrics
        let s = m.iconSize
        let box = IconLayoutMetrics.checkboxSize
        switch m.style {
        case .iconAbove:
            let icon = CGRect(x: cell.midX - s / 2, y: cell.minY + m.padding, width: s, height: s)
            let width = cell.width - 2 * labelInset
            let text = i < items.count ? displayName(items[i]) : ""
            let full = wrappedHeight(text, width: width)
            let maxLines: CGFloat = expanded ? 12 : CGFloat(m.labelLines)
            let textHeight = max(m.lineHeight, min(full, maxLines * m.lineHeight))
            let name = CGRect(x: cell.minX + labelInset, y: icon.maxY + m.iconLabelGap, width: width, height: textHeight)
            let highlight = CGRect(x: cell.minX + 1, y: cell.minY, width: cell.width - 2,
                                   height: name.maxY + m.padding - cell.minY)
            let checkbox = CGRect(x: highlight.minX + 4, y: highlight.minY + 4, width: box, height: box)
            return ItemGeometry(cell: cell, highlight: highlight, icon: icon, name: name, checkbox: checkbox)
        case .iconLeft:
            let lead = cell.minX + 4 + (checkBoxes ? IconLayoutMetrics.checkboxColumn : 0)
            let icon = CGRect(x: lead, y: cell.midY - s / 2, width: s, height: s)
            let textX = icon.maxX + m.iconLabelGap
            let maxWidth = max(10, cell.maxX - 6 - textX)
            let width = i < items.count ? min(maxWidth, TextWidthCache.width(displayName(items[i]), font: m.nameFont) + 2) : maxWidth
            let name = CGRect(x: textX, y: cell.midY - m.lineHeight / 2, width: width, height: m.lineHeight)
            let highlight = CGRect(x: cell.minX, y: cell.minY + (m.compact ? 0 : 1), width: min(cell.width, name.maxX + 6 - cell.minX),
                                   height: cell.height - (m.compact ? 0 : 2))
            let checkbox = CGRect(x: cell.minX + 4, y: cell.midY - box / 2, width: box, height: box)
            return ItemGeometry(cell: cell, highlight: highlight, icon: icon, name: name, checkbox: checkbox)
        case .tile, .content:
            let lead = cell.minX + m.padding + (checkBoxes ? IconLayoutMetrics.checkboxColumn : 0)
            let icon = CGRect(x: lead, y: cell.midY - s / 2, width: s, height: s)
            let textX = icon.maxX + m.iconLabelGap
            let textWidth = m.style == .tile ? cell.maxX - 8 - textX : (cell.maxX - 8 - textX) * 0.44
            let lines = m.style == .tile ? tileLines(i).count : 2
            let blockHeight = m.lineHeight + CGFloat(max(0, lines - 1)) * (m.detailLineHeight + 1)
            let name = CGRect(x: textX, y: cell.midY - blockHeight / 2, width: max(20, textWidth), height: m.lineHeight)
            let highlight = m.style == .tile ? cell.insetBy(dx: 1, dy: 0) : cell.insetBy(dx: 0, dy: 1)
            let checkbox = CGRect(x: cell.minX + m.padding, y: cell.midY - box / 2, width: box, height: box)
            return ItemGeometry(cell: cell, highlight: highlight, icon: icon, name: name, checkbox: checkbox)
        }
    }

    /// Tiles show name, type and (for files) size (windows11-reference §7).
    private func tileLines(_ i: Int) -> [String] {
        guard i < items.count else { return [] }
        let item = items[i]
        var lines = [displayName(item), item.typeDescription]
        if !item.isFolder, let size = item.size { lines.append(StatusText.bytes(size)) }
        return lines
    }

    /// Where the inline rename box goes (FE-049 in this layout).
    func editorFrame(for i: Int, text: String) -> CGRect {
        let g = geometry(i)
        switch metrics.style {
        case .iconAbove:
            let width = g.cell.width - 2
            let height = max(metrics.lineHeight, wrappedHeight(text, width: width - 8)) + 6
            return CGRect(x: g.cell.minX + 1, y: g.name.minY - 3, width: width, height: height)
        case .iconLeft:
            let width = max(140, g.cell.maxX - g.name.minX + 4)
            return CGRect(x: g.name.minX - 3, y: g.cell.midY - (metrics.lineHeight + 6) / 2, width: width, height: metrics.lineHeight + 6)
        case .tile, .content:
            let width = max(160, (metrics.style == .tile ? g.cell.maxX - 6 : g.cell.minX + g.cell.width * 0.6) - g.name.minX)
            return CGRect(x: g.name.minX - 3, y: g.name.minY - 3, width: width, height: metrics.lineHeight + 6)
        }
    }

    // MARK: Drawing

    func drawContent(in rect: CGRect) {
        guard !items.isEmpty else { marqueeRect.map(MarqueeBand.draw); return }
        let expanded = expandedIndex
        let active = isActive
        let visible = layout.indexes(in: rect.insetBy(dx: -2, dy: -2))
        for i in visible where i != expanded { drawItem(i, expanded: false, active: active) }
        if let expanded {
            let g = geometry(expanded, expanded: true)
            if g.highlight.intersects(rect) { drawItem(expanded, expanded: true, active: active) }
        }
        marqueeRect.map(MarqueeBand.draw)
    }

    private func drawItem(_ i: Int, expanded: Bool, active: Bool) {
        let item = items[i]
        let g = geometry(i, expanded: expanded)
        let isSelected = selection.selected.contains(i)
        let isHovered = hovered == i
        let isDrop = dropTargetIndex == i
        let radius = Theme.cornerRadius

        // Background: rounded Win11 selection / hover, a hairline between Content rows.
        if isSelected || isDrop {
            let color = isDrop ? Theme.selection : (active ? (isHovered ? Theme.selectionHover : Theme.selection) : Theme.selectionInactive)
            fillRounded(g.highlight, radius: radius, color)
            Theme.strokeSelectionIfContrast(g.highlight, radius: radius)   // Increase contrast (FE-201)
        } else if isHovered {
            fillRounded(g.highlight, radius: radius, Theme.hover)
        } else if metrics.style == .content, i + 1 < items.count, !selection.selected.contains(i + 1), hovered != i + 1 {
            Theme.separator.setFill()
            NSRect(x: g.cell.minX + 8, y: g.cell.maxY - 1, width: g.cell.width - 16, height: 1).fill(using: .sourceOver)
        }
        if expanded, isSelected {
            // The expanded label overlaps the next row: give it a solid base.
            fillRounded(g.highlight, radius: radius, Theme.contentBackground)
            fillRounded(g.highlight, radius: radius, active ? Theme.selection : Theme.selectionInactive)
        }
        if showsFocus, active, selection.focus == i {
            Theme.accent.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(roundedRect: g.highlight.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            path.lineWidth = 1
            path.stroke()
        }

        // Cut and hidden items are drawn semi-transparent (windows11-reference §8.2).
        let dimmed = item.isHidden || FileClipboard.shared.isCut(item.url)
        let context = NSGraphicsContext.current?.cgContext
        if dimmed {
            context?.saveGState()
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawIcon(item, in: g.icon)
        if editingIndex != i { drawText(i, item: item, geometry: g, expanded: expanded) }
        if dimmed {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }
        if checkBoxes, isSelected || isHovered { drawCheckbox(in: g.checkbox, checked: isSelected) }
    }

    private func drawIcon(_ item: FileItem, in rect: CGRect) {
        if let key = thumbnailKey(for: item), let hit = ThumbnailService.shared.image(for: key) {
            drawThumbnail(hit.image, in: rect)
            return
        }
        let icon = IconProvider.shared.icon(for: item, size: metrics.iconSize)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Aspect-fit; under large icons the picture sits on the label (bottom-aligned), like Explorer.
    private func drawThumbnail(_ image: CGImage, in rect: CGRect) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return }
        let scale = min(rect.width / w, rect.height / h)
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let y = metrics.style == .iconAbove ? rect.maxY - size.height : rect.midY - size.height / 2
        let target = CGRect(x: (rect.midX - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
        NSImage(cgImage: image, size: size).draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                                                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        Theme.separator.setStroke()
        let border = NSBezierPath(rect: target.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawText(_ i: Int, item: FileItem, geometry g: ItemGeometry, expanded: Bool) {
        let m = metrics
        let primary = Theme.primaryText
        let secondary = Theme.secondaryText
        let underline = ItemViewHooks.underlinesName.first((self, i)) ?? false
        switch m.style {
        case .iconAbove:
            let name = displayName(item)
            let text = expanded ? name : fittedLabel(name, width: g.name.width, lines: m.labelLines)
            (text as NSString).draw(with: g.name.insetBy(dx: 0, dy: -0.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes(m.nameFont, color: primary, alignment: .center, underline: underline))
        case .iconLeft:
            drawLine(displayName(item), in: g.name, font: m.nameFont, color: primary, lineBreak: .byTruncatingMiddle, underline: underline)
        case .tile:
            let lines = tileLines(i)
            var y = g.name.minY
            for (n, line) in lines.enumerated() {
                let font = n == 0 ? m.nameFont : m.detailFont
                let height = n == 0 ? m.lineHeight : m.detailLineHeight
                drawLine(line, in: CGRect(x: g.name.minX, y: y, width: g.name.width, height: height), font: font,
                         color: n == 0 ? primary : secondary, lineBreak: n == 0 ? .byTruncatingMiddle : .byTruncatingTail,
                         underline: n == 0 && underline)
                y += height + 1
            }
        case .content:
            drawContentRow(item, geometry: g, underline: underline)
        }
    }

    /// Content: name and type on the left; dimensions (pictures) in the middle; date and size on the right.
    private func drawContentRow(_ item: FileItem, geometry g: ItemGeometry, underline: Bool = false) {
        let m = metrics
        let left = g.name.minX
        let available = g.cell.maxX - 10 - left
        let line1 = g.name
        let line2 = CGRect(x: left, y: line1.maxY + 1, width: line1.width, height: m.detailLineHeight)
        drawLine(displayName(item), in: line1, font: m.nameFont, color: Theme.primaryText, lineBreak: .byTruncatingMiddle,
                 underline: underline)
        drawPair(L10n.tr("Type:"), item.typeDescription, in: line2)

        let middleX = left + available * 0.47
        let middleWidth = available * 0.24
        if let detail = InteractionHooks.itemDetail.first((item, location)) {
            drawPair(detail.label, detail.value, in: CGRect(x: middleX, y: line2.minY, width: middleWidth, height: line2.height))
        } else if ThumbnailPolicy.hasDimensions(item), let dims = ImageInfoService.shared.dimensions(for: item), !dims.isEmpty {
            drawPair(L10n.tr("Dimensions:"), dims, in: CGRect(x: middleX, y: line2.minY, width: middleWidth, height: line2.height))
        }
        let rightX = left + available * 0.73
        let rightWidth = available * 0.27
        if let date = item.modified {
            drawPair(L10n.tr("Date modified:"), ItemGridView.dateFormatter.string(from: date),
                     in: CGRect(x: rightX, y: line1.minY + (m.lineHeight - m.detailLineHeight), width: rightWidth, height: m.detailLineHeight))
        }
        if !item.isFolder, let size = item.size {
            drawPair(L10n.tr("Size:"), StatusText.bytes(size), in: CGRect(x: rightX, y: line2.minY, width: rightWidth, height: line2.height))
        }
    }

    private func drawPair(_ label: String, _ value: String, in rect: CGRect) {
        let text = NSMutableAttributedString(string: label + " ", attributes: attributes(metrics.detailFont, color: Theme.secondaryText,
                                                                                         lineBreak: .byTruncatingTail))
        text.append(NSAttributedString(string: value, attributes: attributes(metrics.detailFont, color: Theme.primaryText,
                                                                            lineBreak: .byTruncatingTail)))
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawLine(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, lineBreak: NSLineBreakMode,
                          underline: Bool = false) {
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes(font, color: color, lineBreak: lineBreak, underline: underline))
    }

    /// Win11-style check box: rounded square, accent fill with a white check when checked.
    private func drawCheckbox(in rect: CGRect, checked: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        if checked {
            Theme.accent.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 4, y: rect.midY + 0.5))
            check.line(to: NSPoint(x: rect.minX + 7, y: rect.maxY - 4.5))
            check.line(to: NSPoint(x: rect.maxX - 3.5, y: rect.minY + 4.5))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            Theme.contentBackground.setFill()
            box.fill()
            Theme.secondaryText.withAlphaComponent(0.8).setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }
}
