import CoreGraphics
import RedScreenCore
import SwiftUI

/// Shows the imported screenshot upright and aspect-fit, or a drop zone when nothing is open.
struct DocumentView: View {
    let model: AppModel

    @State private var displayImage: CGImage?
    @State private var isDropTargeted = false
    @State private var canvasSize: CGSize = .zero
    @State private var showsTextRegions = false

    private var controller: ScreenshotImportController { model.importController }

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.lastError {
                errorBanner(error)
            }
            if case .failed(let error) = controller.recognitionStatus {
                recognitionBanner(error)
            }

            ZStack {
                if let displayImage, let document = controller.document {
                    fittedImage(displayImage, dimensions: document.pixelDimensions)
                } else {
                    dropZone
                }

                if controller.isImporting {
                    ProgressView("Importing…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("import-progress")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { proxy in
                    Color(nsColor: .underPageBackgroundColor)
                        .onAppear { canvasSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in canvasSize = size }
                }
            }
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

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        .task(id: controller.document?.sessionID) {
            displayImage = controller.activePixels?.makeCGImage()
        }
    }

    /// Sizes the image with the core aspect-fit mapping, so its on-screen frame is exactly the
    /// geometry later review overlays will use to map image pixels to view points.
    private func fittedImage(_ image: CGImage, dimensions: PixelDimensions) -> some View {
        let inset = 16.0
        let fittedSize: CGSize = {
            guard let size = try? PresentationSize(
                width: max(1, canvasSize.width - inset * 2),
                height: max(1, canvasSize.height - inset * 2)
            ) else { return .zero }
            let fit = AspectFitGeometry(imageDimensions: dimensions, presentationSize: size)
            return CGSize(
                width: Double(dimensions.width) * fit.scale,
                height: Double(dimensions.height) * fit.scale
            )
        }()
        return Image(image, scale: 1, label: Text("Imported screenshot"))
            .resizable()
            .interpolation(.high)
            .frame(width: fittedSize.width, height: fittedSize.height)
            .accessibilityIdentifier("document-image")
            .overlay(alignment: .topLeading) {
                if showsTextRegions {
                    textRegionOverlay(dimensions: dimensions, fittedSize: fittedSize)
                }
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
            Spacer()
            if controller.document != nil {
                Toggle("Show Text Regions", isOn: $showsTextRegions)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("show-text-regions-toggle")
            }
            Button("Import…", action: model.chooseScreenshot)
                .keyboardShortcut("o")
                .accessibilityIdentifier("document-import-button")
            Button("Close") { NSApplication.shared.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
                .accessibilityIdentifier("document-close-button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    /// Outlines recognized text so the user can see what OCR found. Shows geometry only.
    private func textRegionOverlay(dimensions: PixelDimensions, fittedSize: CGSize) -> some View {
        let scale = fittedSize.width / Double(dimensions.width)
        let rects = (controller.activeDocument?.observations ?? []).compactMap {
            try? $0.imageRect(in: dimensions)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .offset(x: rect.x * scale, y: rect.y * scale)
            }
        }
        .frame(width: fittedSize.width, height: fittedSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
