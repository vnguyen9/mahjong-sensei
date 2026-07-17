import Foundation
import CoreGraphics

/// Maps a rectangle in preview-layer points (e.g. the scan reticle) to a
/// normalized rectangle in the underlying oriented image, assuming the preview
/// uses `videoGravity == .resizeAspectFill` (scale to fill, centered crop).
///
/// Under aspect-fill the image is scaled by `f = max(Sw/Iw, Sh/Ih)` so it covers
/// the preview, then centered — the overflow is cropped equally on both sides.
public enum AspectFillMapping {
    public static func normalizedImageRect(of rect: CGRect,
                                           previewBounds: CGRect,
                                           orientedImageSize: CGSize) -> TileBoundingBox {
        let s = previewBounds.size
        let i = orientedImageSize
        guard i.width > 0, i.height > 0, s.width > 0, s.height > 0 else {
            return TileBoundingBox(x: 0, y: 0, width: 1, height: 1)
        }
        let fill = max(s.width / i.width, s.height / i.height)
        let displayedW = i.width * fill
        let displayedH = i.height * fill
        let cropX = (displayedW - s.width) / 2
        let cropY = (displayedH - s.height) / 2
        // rect and previewBounds share a coordinate space (both captured in .global).
        let localX = rect.origin.x - previewBounds.origin.x
        let localY = rect.origin.y - previewBounds.origin.y
        return TileBoundingBox(
            x: (localX + cropX) / displayedW,
            y: (localY + cropY) / displayedH,
            width: rect.width / displayedW,
            height: rect.height / displayedH
        )
    }
}
