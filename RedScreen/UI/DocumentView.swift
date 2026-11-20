import CoreGraphics
import RedScreenCore
import SwiftUI

/// Shows the imported screenshot upright and aspect-fit, or a drop zone when nothing is open.
struct DocumentView: View {
    let model: AppModel

    @State private var displayImage: (sessionID: UUID, image: CGImage)?
    @State private var isDropTargeted = false
    @State private var showsTextRegions = false
    @State private var highlightsFindings = true

    @State private var selection: UUID?
    @State private var mode: ReviewMode = .select
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var drag: ReviewDrag?
    @State private var draft: ImageRect?
    @State private var preview: CGImage?
    /// The exact flattened raster shown as `preview`; the only thing Save and Copy may output.
    @State private var previewOutput: FlattenedRedactedImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewFailed = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportFeedback: ExportFeedback?

    private struct ExportFeedback: Equatable {
        let message: String
        let isError: Bool
    }

    private enum ReviewMode: String, CaseIterable {
        case select = "Select", draw = "Draw", pan = "Pan"
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var left: Bool { self == .topLeft || self == .bottomLeft }
        var top: Bool { self == .topLeft || self == .topRight }
        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
        }
    }

    private enum ReviewDrag {
        case drawing(CGPoint)
        case moving(UUID, ImageRect)
        case resizing(UUID, ImageRect, Corner)
        case panning(CGSize)
        case ignored
    }

    private var candidates: [RedactionCandidate] { controller.activeDocument?.candidates ?? [] }
    private var selectedCandidate: RedactionCandidate? { candidates.first { $0.id == selection } }

    private var controller: ScreenshotImportController { model.importController }

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.lastError {
                errorBanner(error)
            }
            if let error = controller.lastCaptureError {
                captureErrorBanner(error)
            }
            if case .failed(let error) = controller.recognitionStatus {
                recognitionBanner(error)
            }

            if case .failed = controller.detectionStatus {
                HStack {
                    Text("Could not check this screenshot for secrets.")
                    Spacer()
                    Button("Retry") { controller.retryRecognition() }
                }
                .padding(12)
                .background(.orange.opacity(0.12))
            }

            if controller.workflowState == .canceled, controller.document != nil {
                HStack {
                    Text("Processing canceled. No findings were checked.")
                        .accessibilityIdentifier("processing-canceled")
                    Spacer()
                    Button("Retry") { controller.retryRecognition() }
                        .accessibilityIdentifier("processing-retry")
                }
                .padding(12)
                .background(.yellow.opacity(0.12))
            }

            if controller.document != nil { reviewToolbar }
            HStack(spacing: 0) {
                canvas
                if controller.canReview {
                    Divider()
                    inspector.frame(width: 220)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 420)
        .task(id: controller.document?.sessionID) {
            if let id = controller.document?.sessionID, let image = controller.activePixels?.makeCGImage() {
                displayImage = (id, image)
            } else {
                displayImage = nil
            }
            selection = nil
            mode = .select
            resetViewport()
            cancelInteraction()
        }
        .onChange(of: controller.reviewRevision) { _, _ in
            cancelInteraction()
        }
        .onChange(of: controller.isImporting) { _, importing in
            if importing { cancelInteraction() }
        }
    }

    private var canvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let displayImage, let document = controller.document, displayImage.sessionID == document.sessionID {
                GeometryReader { proxy in
                    if let size = try? PresentationSize(width: max(1, proxy.size.width - 24),
                                                        height: max(1, proxy.size.height - 24)) {
                        let fit = AspectFitGeometry(imageDimensions: document.pixelDimensions, presentationSize: size)
                        let geometry = ReviewCanvasGeometry(fit: fit, zoom: zoom, pan: pan)
                        imageCanvas(preview ?? displayImage.image, geometry: geometry, dimensions: document.pixelDimensions, viewport: size)
                            .frame(width: size.width, height: size.height)
                            .id(document.sessionID)
                            .padding(12)
                    }
                }
            } else {
                dropZone
            }
            if controller.isImporting {
                VStack(spacing: 10) {
                    ProgressView("Importing…")
                    Button("Cancel", action: controller.cancelProcessing)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("import-cancel")
                }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("import-progress")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importDroppedItems(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-drop-target")
    }

    private func imageCanvas(_ image: CGImage, geometry: ReviewCanvasGeometry,
                             dimensions: PixelDimensions, viewport: PresentationSize) -> some View {
        let frame = geometry.imageFrame
        return Color.clear.overlay(alignment: .topLeading) {
            Image(image, scale: 1, label: Text(preview == nil ? "Imported screenshot" : "Redacted preview"))
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .accessibilityIdentifier("document-image")
        }
        .overlay {
            if preview == nil {
                Canvas { context, _ in
                    drawOverlays(context, geometry: geometry, dimensions: dimensions)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "review-canvas")
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("review-canvas"))
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                if drag == nil { beginDrag(value.startLocation, geometry: geometry, viewport: viewport) }
                updateDrag(value, geometry: geometry, dimensions: dimensions, viewport: viewport)
            }
            .onEnded { value in
                if hypot(value.translation.width, value.translation.height) >= 3 {
                    if drag == nil { beginDrag(value.startLocation, geometry: geometry, viewport: viewport) }
                    updateDrag(value, geometry: geometry, dimensions: dimensions, viewport: viewport)
                } else if drag == nil, controller.canReview, preview == nil, mode == .select {
                    selection = hitCandidate(at: value.location, geometry: geometry)?.id
                }
                finishDrag()
            })
        .clipped()
    }

    private var reviewToolbar: some View {
        HStack {
            Picker("Canvas tool", selection: $mode) {
                ForEach(ReviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
            .disabled(!controller.canReview || preview != nil)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { changeZoom(by: 1 / 1.5) }
                .labelStyle(.iconOnly)
                .disabled(zoom <= 1)
            Button("Zoom in", systemImage: "plus.magnifyingglass") { changeZoom(by: 1.5) }
                .labelStyle(.iconOnly)
                .disabled(zoom >= 8)
            Button("Fit", action: resetViewport)
            Text("\(Int((zoom * 100).rounded()))%")
                .monospacedDigit()
                .accessibilityLabel("Zoom \(Int((zoom * 100).rounded())) percent")
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward", action: controller.undoReview)
                .keyboardShortcut("z")
                .disabled(!controller.canUndoReview)
                .accessibilityIdentifier("review-undo")
            Button("Redo", systemImage: "arrow.uturn.forward", action: controller.redoReview)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!controller.canRedoReview)
                .accessibilityIdentifier("review-redo")
        }
        .padding(8)
        .background(.bar)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Redactions").font(.headline)
                Spacer()
                Button("Previous redaction", systemImage: "chevron.up") { stepSelection(by: -1) }
                    .labelStyle(.iconOnly)
                    .help("Previous redaction (Option-Up Arrow)")
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Next redaction", systemImage: "chevron.down") { stepSelection(by: 1) }
                    .labelStyle(.iconOnly)
                    .help("Next redaction (Option-Down Arrow)")
                    .keyboardShortcut(.downArrow, modifiers: .option)
            }
            .disabled(candidates.isEmpty)
            if candidates.isEmpty {
                Text("No findings. Add a rectangle to redact an area.").font(.caption)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            let title = candidate.isManual ? "Manual rectangle" : "Finding \(index + 1)"
                            Button {
                                selectCandidate(candidate.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title).fontWeight(selection == candidate.id ? .semibold : .regular)
                                    Text(candidateDetails(candidate)).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == candidate.id ? Color.accentColor.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == candidate.id ? .isSelected : [])
                            .accessibilityIdentifier("review-candidate-\(index)")
                        }
                    }
                }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    scroll.scrollTo(id)
                }
            }

            if let candidate = selectedCandidate {
                if candidate.isManual, let rect = candidate.regions.first?.rect,
                   let dimensions = controller.activeDocument?.pixelDimensions {
                    manualControls(candidate.id, rect: rect, dimensions: dimensions)
                } else {
                    HStack {
                        Button("Include") { controller.setReviewDisposition(.included, for: candidate.id) }
                            .disabled(candidate.disposition == .included)
                            .accessibilityIdentifier("review-include")
                        Button("Exclude") { controller.setReviewDisposition(.excluded, for: candidate.id) }
                            .disabled(candidate.disposition == .excluded)
                            .accessibilityIdentifier("review-exclude")
                    }
                }
            }

            Button("Add Rectangle", action: addCenteredRectangle)
                .accessibilityIdentifier("review-add")
            Divider()
            if controller.pendingReviewCount > 0 {
                Text("Resolve \(controller.pendingReviewCount) pending before previewing output.")
                    .font(.caption)
                    .accessibilityIdentifier("review-pending")
            }
            if previewFailed {
                Text("Could not render the preview. Try again.").font(.caption)
            }
            Button(preview == nil ? "Preview Redacted Image" : "Back to Review", action: togglePreview)
                .disabled(!controller.canRenderReviewedImage || previewTask != nil)
                .accessibilityIdentifier("review-preview")
            if previewTask != nil {
                ProgressView("Rendering preview…").controlSize(.small)
            }
            if let output = previewOutput {
                exportControls(output)
            }
        }
        .padding(10)
    }

    /// Final review gate: output actions exist only while the flattened result is on screen, and
    /// they write that exact raster. There is no action that outputs the source.
    @ViewBuilder
    private func exportControls(_ output: FlattenedRedactedImage) -> some View {
        Divider()
        Text("Review the redacted image above. It is exactly what will be saved or copied.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("export-review-note")
        Button("Save As…") { save(output) }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(exportTask != nil)
            .accessibilityIdentifier("export-save")
        Button("Copy Redacted Image") { copy(output) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(exportTask != nil)
            .accessibilityIdentifier("export-copy")
        if let exportFeedback {
            Text(exportFeedback.message)
                .font(.caption)
                .foregroundStyle(exportFeedback.isError ? Color.red : Color.secondary)
                .accessibilityIdentifier("export-status")
        }
    }

    private func save(_ output: FlattenedRedactedImage) {
        exportFeedback = nil
        exportTask = Task {
            do {
                if try await model.saveRedactedImage(output) {
                    exportFeedback = ExportFeedback(message: "Saved the redacted image.", isError: false)
                }
            } catch is CancellationError {
            } catch {
                exportFeedback = ExportFeedback(message: Self.message(for: error, saving: true), isError: true)
            }
            exportTask = nil
        }
    }

    private func copy(_ output: FlattenedRedactedImage) {
        do {
            try controller.copyReviewedImage(output)
            exportFeedback = ExportFeedback(message: "Copied the redacted image.", isError: false)
        } catch {
            exportFeedback = ExportFeedback(message: Self.message(for: error, saving: false), isError: true)
        }
    }

    /// Fixed, non-sensitive feedback: never a path, filename, or system error description.
    private static func message(for error: any Error, saving: Bool) -> String {
        switch error as? ImageExportError {
        case .reviewChanged: "The review changed. Preview the redacted image again."
        case .destinationExists: "A file with that name already exists. Choose another name."
        case .invalidDestination: "Choose a file location to save to."
        case .encodingFailed: "Could not create the image. Try again."
        case .writeFailed: "Could not save to that location. Choose another location."
        case .clipboardFailed: "Could not copy to the clipboard. Try again."
        case .unavailable, nil: saving ? "Could not save the image." : "Could not copy the image."
        }
    }

    private func selectCandidate(_ id: UUID) {
        selection = id
        mode = .select
        clearPreview()
    }

    private func stepSelection(by direction: Int) {
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == selection }
        let next = current.map { ($0 + direction + candidates.count) % candidates.count }
            ?? (direction > 0 ? 0 : candidates.count - 1)
        selectCandidate(candidates[next].id)
    }

    private func candidateDetails(_ candidate: RedactionCandidate) -> String {
        let status: String
        switch candidate.disposition {
        case .included, .manual: status = "Will redact"
        case .excluded: status = "Excluded"
        case .pending: status = "Pending review"
        }
        guard let evidence = candidate.evidence.first else { return status }
        let confidence = Int((evidence.confidence.value * 100).rounded())
        let rule = evidence.ruleID.rawValue
        var details = "\(status) · \(confidence)%\n\(rule)"
        if candidate.needsGeometryReview {
            details += " · Check bounds"
        }
        if candidate.isConfirmedByEditorHint {
            details += "\nConfirmed by VS Code hint"
        }
        if rule.hasPrefix("custom.") {
            details += "\nCustom rule"
        }
        return details
    }

    private func manualControls(_ id: UUID, rect: ImageRect, dimensions: PixelDimensions) -> some View {
        let width = Double(dimensions.width)
        let height = Double(dimensions.height)
        return VStack(alignment: .leading, spacing: 4) {
            geometryStepper("Horizontal position", value: rect.x, range: 0...max(0, width - rect.width)) {
                updateManualRect(id, x: $0, y: rect.y, width: rect.width, height: rect.height)
            }
            geometryStepper("Vertical position", value: rect.y, range: 0...max(0, height - rect.height)) {
                updateManualRect(id, x: rect.x, y: $0, width: rect.width, height: rect.height)
            }
            geometryStepper("Width", value: rect.width, range: 1...max(1, width - rect.x)) {
                updateManualRect(id, x: rect.x, y: rect.y, width: $0, height: rect.height)
            }
            geometryStepper("Height", value: rect.height, range: 1...max(1, height - rect.y)) {
                updateManualRect(id, x: rect.x, y: rect.y, width: rect.width, height: $0)
            }
            Button("Delete Rectangle", role: .destructive) { controller.deleteManualRedaction(id) }
                .accessibilityIdentifier("review-delete")
        }
    }

    private func geometryStepper(_ label: String, value: Double, range: ClosedRange<Double>,
                                 apply: @escaping (Double) -> Void) -> some View {
        HStack {
            Text("\(label): \(value, format: .number.precision(.fractionLength(0...1))) px")
                .font(.caption)
                .accessibilityIdentifier("review-geometry-\(label)")
            Spacer(minLength: 0)
            Stepper(label, value: Binding(get: { value }, set: apply), in: range, step: 1)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(Text("\(value, format: .number.precision(.fractionLength(0...1))) pixels"))
        }
    }

    private func updateManualRect(_ id: UUID, x: Double, y: Double, width: Double, height: Double) {
        guard let rect = try? ImageRect(x: x, y: y, width: width, height: height) else { return }
        controller.updateManualRedaction(id, rect: rect)
    }

    private func addCenteredRectangle() {
        guard let dimensions = controller.activeDocument?.pixelDimensions else { return }
        let width = Double(dimensions.width), height = Double(dimensions.height)
        let w = max(1, width / 4), h = max(1, height / 4)
        guard let rect = try? ImageRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h),
              let id = controller.addManualRedaction(rect) else { return }
        selection = id
        mode = .select
    }

    private func hitCandidate(at point: CGPoint, geometry: ReviewCanvasGeometry) -> RedactionCandidate? {
        candidates.reversed().first { candidate in
            candidate.regions.contains { geometry.presentationRect(for: $0.rect).contains(point) }
        }
    }

    private func beginDrag(_ point: CGPoint, geometry: ReviewCanvasGeometry, viewport: PresentationSize) {
        guard controller.canReview else { drag = .ignored; return }
        if mode == .pan {
            drag = .panning(CGSize(width: geometry.imageFrame.midX - viewport.width / 2,
                                   height: geometry.imageFrame.midY - viewport.height / 2))
            return
        }
        guard preview == nil else { drag = .ignored; return }
        if mode == .draw {
            drag = geometry.imageFrame.contains(point) ? .drawing(geometry.imagePoint(for: point)) : .ignored
            return
        }
        if let candidate = selectedCandidate, candidate.isManual, let rect = candidate.regions.first?.rect {
            let frame = geometry.presentationRect(for: rect)
            if let corner = Corner.allCases.first(where: {
                let handle = $0.point(in: frame)
                return hypot(handle.x - point.x, handle.y - point.y) <= 9
            }) {
                drag = .resizing(candidate.id, rect, corner)
                return
            }
            if frame.contains(point) {
                drag = .moving(candidate.id, rect)
                return
            }
        }
        let hit = hitCandidate(at: point, geometry: geometry)
        selection = hit?.id
        if let hit, hit.isManual, let rect = hit.regions.first?.rect { drag = .moving(hit.id, rect) }
        else { drag = .ignored }
    }

    private func updateDrag(_ value: DragGesture.Value, geometry: ReviewCanvasGeometry,
                            dimensions: PixelDimensions, viewport: PresentationSize) {
        let width = Double(dimensions.width), height = Double(dimensions.height)
        let dx = value.translation.width / geometry.scale, dy = value.translation.height / geometry.scale
        switch drag {
        case .drawing(let start):
            let end = geometry.imagePoint(for: value.location)
            let x = min(width, max(0, end.x)), y = min(height, max(0, end.y))
            let w = abs(x - start.x), h = abs(y - start.y)
            draft = w >= 1 && h >= 1 ? try? ImageRect(x: min(x, start.x), y: min(y, start.y), width: w, height: h) : nil
        case .moving(_, let rect):
            draft = try? ImageRect(x: min(width - rect.width, max(0, rect.x + dx)),
                                  y: min(height - rect.height, max(0, rect.y + dy)),
                                  width: rect.width, height: rect.height)
        case .resizing(_, let rect, let corner):
            let left = corner.left ? max(0, min(rect.maxX - 1, rect.x + dx)) : rect.x
            let right = corner.left ? rect.maxX : min(width, max(rect.x + 1, rect.maxX + dx))
            let top = corner.top ? max(0, min(rect.maxY - 1, rect.y + dy)) : rect.y
            let bottom = corner.top ? rect.maxY : min(height, max(rect.y + 1, rect.maxY + dy))
            draft = try? ImageRect(x: left, y: top, width: right - left, height: bottom - top)
        case .panning(let start):
            let dx = max(0, (geometry.imageFrame.width - viewport.width) / 2)
            let dy = max(0, (geometry.imageFrame.height - viewport.height) / 2)
            pan = CGSize(width: min(dx, max(-dx, start.width + value.translation.width)),
                         height: min(dy, max(-dy, start.height + value.translation.height)))
        case .ignored, nil: break
        }
    }

    private func finishDrag() {
        defer { drag = nil; draft = nil }
        guard let draft else { return }
        switch drag {
        case .drawing:
            selection = controller.addManualRedaction(draft)
            mode = .select
        case .moving(let id, _), .resizing(let id, _, _):
            controller.updateManualRedaction(id, rect: draft)
        default: break
        }
    }

    private func resetViewport() { zoom = 1; pan = .zero }

    private func changeZoom(by factor: Double) {
        zoom = min(8, max(1, zoom * factor))
        pan = .zero
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        previewOutput = nil
        previewFailed = false
        exportFeedback = nil
    }

    private func cancelInteraction() {
        drag = nil
        draft = nil
        clearPreview()
    }

    private func togglePreview() {
        if preview != nil {
            clearPreview()
            mode = .select
            return
        }
        previewFailed = false
        previewTask = Task {
            do {
                let output = try await controller.renderReviewedImage()
                guard !Task.isCancelled else { return }
                preview = output.pixels.makeCGImage()
                previewOutput = preview == nil ? nil : output
                previewFailed = preview == nil
                mode = .pan
            } catch is CancellationError {
                if Task.isCancelled { return }
            } catch {
                if Task.isCancelled { return }
                previewFailed = true
            }
            previewTask = nil
        }
    }

    private func drawOverlays(_ context: GraphicsContext, geometry: ReviewCanvasGeometry,
                              dimensions: PixelDimensions) {
        if showsTextRegions {
            for observation in controller.activeDocument?.observations ?? [] {
                guard let rect = try? observation.imageRect(in: dimensions) else { continue }
                context.stroke(Path(geometry.presentationRect(for: rect)), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        for candidate in candidates where highlightsFindings || candidate.id == selection || candidate.isManual {
            let selected = candidate.id == selection
            let included = candidate.isManual || candidate.disposition == .included
            let color: Color = selected ? .accentColor : included ? .red : candidate.disposition == .excluded ? .gray : .orange
            for region in candidate.regions {
                let rect: ImageRect
                switch drag {
                case .moving(let id, _), .resizing(let id, _, _):
                    rect = id == candidate.id ? draft ?? region.rect : region.rect
                default:
                    rect = region.rect
                }
                let frame = geometry.presentationRect(for: rect)
                context.fill(Path(frame), with: .color(color.opacity(included ? 0.32 : 0.09)))
                context.stroke(Path(frame), with: .color(color),
                               style: StrokeStyle(lineWidth: selected ? 3 : 2,
                                                  dash: candidate.needsGeometryReview ? [5, 3] : []))
                if selected && candidate.isManual && mode == .select {
                    for corner in Corner.allCases {
                        let point = corner.point(in: frame)
                        let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                        context.fill(Path(handle), with: .color(color))
                        context.stroke(Path(handle), with: .color(.white), lineWidth: 1)
                    }
                }
            }
        }
        if case .drawing = drag, let draft {
            context.stroke(Path(geometry.presentationRect(for: draft)), with: .color(.accentColor), lineWidth: 2)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop a PNG, JPEG, or HEIC screenshot here")
                .font(.title3)
            Text("Images are processed in memory and never leave this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Screenshot…", action: model.chooseScreenshot)
                .accessibilityIdentifier("choose-screenshot-button")
        }
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-drop-zone")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let document = controller.document {
                    Text(
                        "\(document.pixelDimensions.width) × \(document.pixelDimensions.height) px"
                            + (document.colorSpace == .displayP3 ? " · Display P3" : "")
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("document-dimensions")
                } else {
                    Text("No screenshot open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                recognitionStatusLabel
                detectionStatusLabel
                profileLabel
            }
            HStack(spacing: 12) {
                if controller.document != nil {
                    Toggle("Highlight Findings", isOn: $highlightsFindings)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("highlight-findings-toggle")
                    Toggle("Show Text Regions", isOn: $showsTextRegions)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("show-text-regions-toggle")
                }
                Spacer()
                Menu("Capture") {
                    Button("Region…") { model.capture(.region) }
                        .accessibilityIdentifier("document-capture-region")
                    Button("Window…") { model.capture(.window) }
                        .accessibilityIdentifier("document-capture-window")
                    Button("Display") { model.capture(.display) }
                        .accessibilityIdentifier("document-capture-display")
                }
                .help("Capture a region (⌥⌘1), window (⌥⌘2), or display (⌥⌘3).")
                .fixedSize()
                .accessibilityIdentifier("document-capture-menu")
                Button("Import…", action: model.chooseScreenshot)
                    .keyboardShortcut("o")
                    .accessibilityIdentifier("document-import-button")
                Button("Close") { NSApplication.shared.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
                    .accessibilityIdentifier("document-close-button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var processingCancelButton: some View {
        Button("Cancel", action: controller.cancelProcessing)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("processing-cancel")
    }

    /// Which profile produced the findings, and how many it hid, so exclusions are never invisible.
    @ViewBuilder
    private var profileLabel: some View {
        if controller.document != nil, let report = controller.profileReport {
            Text(profileSummary(report))
                .font(.callout)
                .foregroundStyle(report.hiddenTotal > 0 ? Color.orange : .secondary)
                .help(profileHelp(report))
                .accessibilityIdentifier("document-profile")
        }
    }

    // Built step by step: long `+` chains with `? :` exceed the type checker's time limit on
    // the Xcode version CI uses.
    private func profileSummary(_ report: DetectionProfileReport) -> String {
        var summary = "Profile: \(report.profileName)"
        if report.hiddenTotal > 0 {
            summary += " · \(report.hiddenTotal) hidden"
        }
        return summary
    }

    private func profileHelp(_ report: DetectionProfileReport) -> String {
        guard report.hiddenTotal > 0 else {
            return "Detection profile in use. Change it in Settings › Detection Profile."
        }
        let rules = report.hiddenByDisabledRules
        let placeholders = report.hiddenByPlaceholders
        let threshold = report.hiddenByThreshold
        return "Hidden by this profile: \(rules) by turned-off rules, \(placeholders) by placeholders, "
            + "\(threshold) below its review threshold. Switch to Balanced in Settings to show them."
    }

    @ViewBuilder
    private var recognitionStatusLabel: some View {
        switch controller.recognitionStatus {
        case .idle:
            EmptyView()
        case .recognizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recognizing text…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recognition-status")
            processingCancelButton
        case .recognized(let count):
            Text(count == 1 ? "1 text region" : "\(count) text regions")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recognition-status")
        case .failed:
            Text("Text recognition failed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recognition-status")
        }
    }

    @ViewBuilder
    private var detectionStatusLabel: some View {
        switch controller.detectionStatus {
        case .idle:
            EmptyView()
        case .detecting:
            Text("Checking for secrets…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detection-status")
            processingCancelButton
        case .detected(let likely, _):
            Text("\(likely) likely \(likely == 1 ? "secret" : "secrets") · \(controller.pendingReviewCount) to review")
                .font(.callout.monospacedDigit())
                .foregroundStyle(likely > 0 ? Color.red : .secondary)
                .accessibilityIdentifier("detection-status")
        case .failed:
            Text("Secret detection failed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detection-status")
        }
    }

    private func recognitionBanner(_ error: TextRecognitionError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(error.userMessage)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recognition-error-message")
            Spacer()
            Button("Retry") { controller.retryRecognition() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("recognition-retry-button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private func captureErrorBanner(_ error: CaptureError) -> some View {
        if error == .permissionDenied || error == .permissionRestricted {
            HStack(alignment: .top, spacing: 10) {
                PermissionGuidanceView(model: model, style: .banner)
                Spacer()
                Button("Dismiss", action: controller.dismissError)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("capture-error-dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.15))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text(error.userMessage)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-error-message")
                Spacer()
                Button("Dismiss", action: controller.dismissError)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("capture-error-dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private func errorBanner(_ error: ImageImportError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(error.userMessage)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import-error-message")
            Spacer()
            Button("Dismiss", action: controller.dismissError)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("import-error-dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.15))
    }
}
