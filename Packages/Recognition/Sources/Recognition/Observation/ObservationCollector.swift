/// Runs a locator (and, once a box exists, a classifier) over one frame and
/// packages the result as an ``ObservationOutcome``. This is the seam that
/// makes a thrown inference impossible to confuse with an empty scene: any
/// `throws` from either stage becomes `.failed`, never a `.success` with a
/// shorter-than-expected (or empty) observation list.
public struct ObservationCollector: Sendable {
    public var locator: TileLocating
    public var classifier: TileClassifying?
    public var cropper: RecognizerFrameCropper

    public init(locator: TileLocating, classifier: TileClassifying? = nil,
                cropper: RecognizerFrameCropper = .init()) {
        self.locator = locator
        self.classifier = classifier
        self.cropper = cropper
    }

    /// - Parameters:
    ///   - frameID: identity shared by every piece of evidence this call produces.
    ///   - input: the frame (and optional ROI) to localize tiles in.
    ///   - coverage: the polygon(s) this frame's evidence is valid within.
    ///   - quality: the frame-quality contract already computed for this
    ///     frame; a not-`accepted` quality is a skip, never an attempt.
    public func observe(frameID: FrameID,
                        input: LocatorInput,
                        coverage: CoverageMask,
                        quality: FrameQuality) async -> ObservationOutcome {
        guard quality.trackingIsNormal else { return .skipped(.trackingNotNormal) }
        guard quality.accepted else { return .skipped(.qualityRejected(quality.rejectionReasons)) }

        let localizations: [TileLocalization]
        do {
            localizations = try await locator.locate(in: input)
        } catch {
            return .failed(.locatorThrew(String(describing: error)))
        }

        let crops = localizations.map { cropper.crop(input.frame, box: $0.box, frameID: frameID) }
        var hypotheses = [TileFaceHypothesis?](repeating: nil, count: localizations.count)
        if let classifier {
            let indexed = crops.enumerated().compactMap { index, crop in crop.map { (index, $0) } }
            do {
                if let batch = classifier as? any BatchTileClassifying {
                    let values = try await batch.classify(indexed.map(\.1))
                    guard values.count == indexed.count else {
                        return .failed(.classifierThrew("batch result count mismatch"))
                    }
                    for (pair, value) in zip(indexed, values) { hypotheses[pair.0] = value }
                } else {
                    for (index, crop) in indexed {
                        hypotheses[index] = try await classifier.classify(crop)
                    }
                }
            } catch {
                return .failed(.classifierThrew(String(describing: error)))
            }
        }

        var observations: [TileObservation] = []
        observations.reserveCapacity(localizations.count)
        for (index, localization) in localizations.enumerated() {
            observations.append(TileObservation(frameID: frameID,
                                                  box: localization.box,
                                                  confidence: localization.confidence,
                                                  poseHint: localization.poseHint,
                                                  faceHypothesis: hypotheses[index]))
        }

        let batch = ObservationBatch(frameID: frameID, observations: observations,
                                      coverage: coverage, quality: quality)
        return .success(batch)
    }
}
