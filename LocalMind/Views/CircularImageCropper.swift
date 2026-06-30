//
//  CircularImageCropper.swift
//  LocalMind
//
//  A small modal for reframing a picked image inside a circular mask before
//  it becomes the profile picture. The user drags to reposition and pinches
//  (or uses the slider) to zoom; "Use Photo" renders exactly what's inside
//  the circle to a compact JPEG. Nothing is saved until they confirm.
//

import SwiftUI
import AppKit

struct CircularImageCropper: View {
    let image: NSImage
    let onComplete: (Data) -> Void
    let onCancel: () -> Void

    // Live transform. `last*` hold the committed value so each gesture is
    // applied relative to where the previous one ended.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// On-screen diameter of the crop circle. The render step reuses the exact
    /// same view so what the user frames is what gets saved (WYSIWYG).
    private let cropDiameter: CGFloat = 300
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            VStack(spacing: 4) {
                Text("Reframe your photo")
                    .font(.headline)
                Text("Drag to reposition · pinch or use the slider to zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            cropArea

            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $scale, in: minScale...maxScale)
                    .onChange(of: scale) { _, _ in
                        offset = clampedOffset(offset, scale: scale)
                        lastOffset = offset
                    }
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .frame(width: cropDiameter)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Photo") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: cropDiameter)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: cropDiameter + 80)
    }

    // MARK: - Crop area

    private var cropArea: some View {
        framedImage
            .frame(width: cropDiameter, height: cropDiameter)
            .background(Color.black.opacity(0.3))
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            )
            .contentShape(Circle())
            .gesture(dragGesture.simultaneously(with: magnifyGesture))
    }

    /// The image content with the live transform applied. Shared between the
    /// preview and the final render so they can't drift apart.
    private var framedImage: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: cropDiameter, height: cropDiameter)
            .scaleEffect(scale)
            .offset(offset)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampedOffset(proposed, scale: scale)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, minScale), maxScale)
                offset = clampedOffset(offset, scale: scale)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    // MARK: - Offset clamping

    /// Keeps the image covering the whole circle — prevents the user from
    /// panning so far that a blank wedge appears at the edge. Bounds depend on
    /// the image's aspect ratio after `scaledToFill` into the square frame.
    private func clampedOffset(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspect = size.width / size.height

        // scaledToFill into a square: the shorter side maps to cropDiameter.
        let baseWidth  = aspect >= 1 ? cropDiameter * aspect : cropDiameter
        let baseHeight = aspect >= 1 ? cropDiameter : cropDiameter / aspect

        let displayedWidth  = baseWidth * scale
        let displayedHeight = baseHeight * scale

        let maxX = max(0, (displayedWidth - cropDiameter) / 2)
        let maxY = max(0, (displayedHeight - cropDiameter) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    // MARK: - Render

    @MainActor
    private func confirm() {
        let content = framedImage
            .frame(width: cropDiameter, height: cropDiameter)
            .clipShape(Circle())

        let renderer = ImageRenderer(content: content)
        // Render at 2× the on-screen size for crispness, then downscale to a
        // 256px square JPEG so the inlined avatar stays small in profile JSON.
        renderer.scale = 2

        guard let rendered = renderer.nsImage,
              let data = Self.encodeJPEG(rendered, target: 256) else {
            onCancel()
            return
        }
        onComplete(data)
    }

    /// Draws `image` into a `target`×`target` square and returns JPEG data.
    /// The input is already square (the circular render sits on a square
    /// canvas), so this is a straight resize — no cropping.
    @MainActor
    private static func encodeJPEG(_ image: NSImage, target: CGFloat) -> Data? {
        let bitmap = NSImage(size: NSSize(width: target, height: target))
        bitmap.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: NSSize(width: target, height: target)),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        bitmap.unlockFocus()

        guard let tiff = bitmap.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
