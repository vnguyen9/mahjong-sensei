/// Runs a locator (and, once a box exists, a classifier) over one frame and
/// packages the result as an ``ObservationOutcome``. This is the seam that
/// makes a thrown inference impossible to confuse with an empty scene: any
/// `throws` from either stage becomes `.failed`, never a `.success` with a
/// shorter-than-expected (or empty) observation list.
public struct ObservationCollector: Sendable {
    public var locator: TileLocating
    public var classifier: TileClassifying?

    public init(locator: TileLocating, classifier: TileClassifying? = nil) {
        self.locator = locator
        self.classifier = classifier
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

        var observations: [TileObservation] = []
        observations.reserveCapacity(localizations.count)
        for localization in localizations {
            var hypothesis: TileFaceHypothesis?
            if let classifier {
                let crop = TileCrop(frame: input.frame, frameID: frameID)
                do {
                    hypothesis = try await classifier.classify(crop)
                } catch {
                    return .failed(.classifierThrew(String(describing: error)))
                }
            }
            observations.append(TileObservation(frameID: frameID,
                                                  box: localization.box,
                                                  confidence: localization.confidence,
                                                  poseHint: localization.poseHint,
                                                  faceHypothesis: hypothesis))
        }

        let batch = ObservationBatch(frameID: frameID, observations: observations,
                                      coverage: coverage, quality: quality)
        return .success(batch)
    }
}
