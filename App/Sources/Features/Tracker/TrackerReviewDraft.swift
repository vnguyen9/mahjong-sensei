import Foundation
import Observation
import MahjongCore
import Recognition

struct TrackerDraftTile: Identifiable, Hashable {
    var id: UUID
    var box: TileBoundingBox
    var face: TileFace?
    var detectionConfidence: Double
    var status: TrackerEvidenceStatus
    var decisionReason: TrackerFusionDecisionReason

    var isExcluded: Bool { status == .excluded }
    var isResolved: Bool { isExcluded || (status != .needsReview && face != nil) }
}

struct TrackerReviewApplicationProjection: Equatable {
    var histogram: [Int]
    var suggestedEvidenceIDs: Set<UUID>
    var skippedEvidenceIDs: Set<UUID>
    var conservationFailureIDs: Set<UUID>

    var canApply: Bool { conservationFailureIDs.isEmpty }
}

@Observable
final class TrackerReviewDraft: Identifiable {
    let id: UUID
    let canonicalFrameID: FrameID
    var tiles: [TrackerDraftTile]
    private(set) var hasUserEdits = false

    init(evidence: TrackerScanEvidence, hand: [Tile] = []) {
        id = evidence.scanID
        canonicalFrameID = evidence.canonicalFrameID
        tiles = evidence.tiles.map {
            TrackerDraftTile(id: $0.id, box: $0.box,
                             face: $0.faceSuggestion,
                             detectionConfidence: $0.detectionConfidence,
                             status: $0.status,
                             decisionReason: $0.decisionReason)
        }
        downgradeConservationViolations(hand: hand)
    }

    var unresolvedCount: Int { tiles.filter { !$0.isResolved }.count }
    var includedCount: Int { tiles.filter { !$0.isExcluded }.count }
    var confirmedCount: Int { tiles.filter { $0.status == .confirmed }.count }
    var nonPoolEvidenceCount: Int {
        tiles.filter { item in
            guard !item.isExcluded else { return false }
            switch item.face {
            case .back: return true
            case .tile(let tile): return tile.isBonus
            case nil: return false
            }
        }.count
    }
    func canApply(hand: [Tile]) -> Bool {
        applicationProjection(hand: hand).canApply
    }

    func resolve(_ id: UUID, as face: TileFace) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].face = face
        tiles[index].detectionConfidence = 1
        tiles[index].status = .userCorrected
        tiles[index].decisionReason = .userSelected
        hasUserEdits = true
    }

    func exclude(_ id: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        tiles[index].status = .excluded
        hasUserEdits = true
    }

    func add(face: TileFace, centeredAt point: CGPoint) -> UUID {
        let sizes = tiles.filter { !$0.isExcluded }.map { ($0.box.width, $0.box.height) }
        let sortedW = sizes.map(\.0).sorted()
        let sortedH = sizes.map(\.1).sorted()
        let width = sortedW.isEmpty ? 0.08 : sortedW[sortedW.count / 2]
        let height = sortedH.isEmpty ? 0.12 : sortedH[sortedH.count / 2]
        let box = TileBoundingBox(
            x: min(max(0, point.x - width / 2), 1 - width),
            y: min(max(0, point.y - height / 2), 1 - height),
            width: width,
            height: height
        )
        let id = UUID()
        tiles.append(TrackerDraftTile(id: id, box: box, face: face,
                                      detectionConfidence: 1,
                                      status: .manuallyAdded,
                                      decisionReason: .manuallyAdded))
        hasUserEdits = true
        return id
    }

    /// Fusion can validate the photographed table by itself. The review draft
    /// performs the final table-plus-hand check and downgrades only the weakest
    /// automatically confirmed excess reads, so Apply cannot hide which tile
    /// needs attention.
    private func downgradeConservationViolations(hand: [Tile]) {
        let confirmed = tiles.indices.filter { tiles[$0].status == .confirmed }
        let groups = Dictionary(grouping: confirmed) { index -> Tile? in
            guard case let .tile(tile)? = tiles[index].face else { return nil }
            return tile
        }
        for (tile, indices) in groups {
            guard let tile else { continue }
            let held = hand.filter { $0 == tile }.count
            let available = max(0, (tile.isBonus ? 1 : 4) - held)
            guard indices.count > available else { continue }
            let excess = indices.sorted {
                if tiles[$0].detectionConfidence != tiles[$1].detectionConfidence {
                    return tiles[$0].detectionConfidence < tiles[$1].detectionConfidence
                }
                return tiles[$0].id.uuidString < tiles[$1].id.uuidString
            }.prefix(indices.count - available)
            for index in excess {
                tiles[index].status = .needsReview
                tiles[index].decisionReason = .conservationViolation
            }
        }
    }

    func proposedHistogram() -> [Int] {
        var histogram = [Int](repeating: 0, count: Tile.baseClassCount)
        for item in tiles where !item.isExcluded {
            guard case let .tile(tile)? = item.face, !tile.isBonus else { continue }
            histogram[tile.classIndex] += 1
        }
        return histogram
    }

    func applicationProjection(hand: [Tile]) -> TrackerReviewApplicationProjection {
        TrackerReviewApplicationProjection(
            histogram: proposedHistogram(),
            suggestedEvidenceIDs: Set(tiles.compactMap { item in
                item.status == .needsReview && item.face != nil ? item.id : nil
            }),
            skippedEvidenceIDs: Set(tiles.compactMap { item in
                item.status == .needsReview && item.face == nil ? item.id : nil
            }),
            conservationFailureIDs: violatingIDs(hand: hand)
        )
    }

    func violatingIDs(hand: [Tile]) -> Set<UUID> {
        var IDs: Set<UUID> = []
        let included = tiles.filter { !$0.isExcluded }
        let grouped = Dictionary(grouping: included) { $0.face }
        for (face, group) in grouped {
            guard case let .tile(tile)? = face else { continue }
            let held = hand.filter { $0 == tile }.count
            let cap = tile.isBonus ? 1 : 4
            if group.count + held > cap {
                IDs.formUnion(group.map(\.id))
            }
        }
        return IDs
    }
}

enum TrackerApplyError: Error, LocalizedError {
    case unresolved(Int)
    case conservation

    var errorDescription: String? {
        switch self {
        case .unresolved(let count): return "Review \(count) more tile\(count == 1 ? "" : "s") before applying."
        case .conservation: return "A tile appears more times than exist in a mahjong set."
        }
    }
}
