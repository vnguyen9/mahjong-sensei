import Foundation
import HarnessKit
import MahjongCore
import Recognition

/// Offline tracker replay: feeds a `video-dump`-produced `.frames.jsonl`
/// stream through `TableTracker` in file order (timestamps come straight
/// from the stream — no wall clock anywhere) via `HarnessKit.TrackReplay`,
/// prints a human timeline plus a final summary, and writes
/// `<input>.events.jsonl` beside each input: a `mj-events/1` header line
/// then one compact, sorted-keys line per emitted `GameEvent` — deterministic
/// (same input → byte-identical output; see `EventRecord`'s doc for the one
/// wrinkle that takes real care).
///
/// Usage (from the repo root):
///   swift run --package-path Tools/detect-dump track-replay \
///       [--seat E|S|W|N] [--round E|S|W|N] [--config-fps 10] \
///       <frames.jsonl> [<frames.jsonl> ...]
@main
struct TrackReplayCLI {
    static func main() {
        do {
            try run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var mySeatWind = Wind.east
        var roundWind = Wind.east
        var configFps = 10.0
        var inputs: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--seat":
                let raw = args.isEmpty ? "" : args.removeFirst()
                guard let wind = parseWind(raw) else {
                    throw CLIError("--seat expects one of E S W N, got \"\(raw)\"")
                }
                mySeatWind = wind
            case "--round":
                let raw = args.isEmpty ? "" : args.removeFirst()
                guard let wind = parseWind(raw) else {
                    throw CLIError("--round expects one of E S W N, got \"\(raw)\"")
                }
                roundWind = wind
            case "--config-fps":
                let raw = args.isEmpty ? "" : args.removeFirst()
                guard let fps = Double(raw), fps > 0 else {
                    throw CLIError("--config-fps expects a positive number, got \"\(raw)\"")
                }
                configFps = fps
            default:
                inputs.append(arg)
            }
        }
        guard !inputs.isEmpty else {
            fputs("""
            usage: track-replay [--seat E|S|W|N] [--round E|S|W|N] [--config-fps 10] \
            <frames.jsonl>...\n
            """, stderr)
            exit(2)
        }

        for path in inputs {
            try replayOne(path: path, mySeatWind: mySeatWind, roundWind: roundWind, configFps: configFps)
        }
    }

    // MARK: - Per-file replay

    static func replayOne(path: String, mySeatWind: Wind, roundWind: Wind, configFps: Double) throws {
        let url = URL(fileURLWithPath: path)
        let (header, frames) = try FrameStream.read(contentsOf: url)
        if abs(header.sampledFPS - configFps) > 0.001 {
            fputs("note: --config-fps \(configFps) differs from \(url.lastPathComponent)'s recorded " +
                  "sampledFPS \(header.sampledFPS); frame timestamps are always read from the stream " +
                  "itself, so this is informational only.\n", stderr)
        }

        let result = TrackReplay.replay(header: header, frames: frames, mySeatWind: mySeatWind, roundWind: roundWind)

        print("== \(url.lastPathComponent)  seat=\(windCode(mySeatWind)) round=\(windCode(roundWind))  " +
              "\(frames.count) frames ==")
        for event in result.events {
            print(describe(event))
        }
        if let pending = result.pendingHandEnd {
            let windsSuffix = pending.predictedWinds.map {
                " → predicted next seat=\(windCode($0.mySeatWind)) round=\(windCode($0.roundWind))"
            } ?? ""
            print("-- pending hand-end proposal: at \(formatT(pending.at))  " +
                  "missing \(String(format: "%.0f%%", pending.missingFraction * 100))\(windsSuffix)")
        }
        printSummary(result)

        try writeEventsFile(for: url, mySeatWind: mySeatWind, roundWind: roundWind, result: result)
    }

    // MARK: - Timeline

    static func describe(_ event: GameEvent) -> String {
        let body: String
        switch event.kind {
        case let .handStarted(mySeatWind, roundWind):
            body = "hand \(event.handIndex) started (seat \(windCode(mySeatWind)), round \(windCode(roundWind)))"
        case let .discard(seat, tile, track):
            body = "\(seat) discarded \(tile.code) (conf \(formatConf(event.confidence)))  [track #\(track.raw)]"
        case let .myDraw(tile):
            body = "I drew \(tile?.code ?? "?")"
        case let .myDiscard(tile, track):
            body = "I discarded \(tile.code)  [track #\(track.raw)]"
        case let .meld(seat, kind, tiles, claimedTile, claimedFrom):
            let tileList = tiles.map(\.code).joined(separator: " ")
            var claim = ""
            if let claimedTile, let claimedFrom {
                claim = " (claimed \(claimedTile.code) from \(claimedFrom))"
            }
            body = "\(seat) called \(kind.rawValue) \(tileList)\(claim)  (conf \(formatConf(event.confidence)))"
        case .myHandComplete:
            body = "MY HAND COMPLETE"
        case let .handEndProposed(missingFraction):
            body = "HAND END PROPOSED (missing \(String(format: "%.0f%%", missingFraction * 100)))"
        case .handEndCancelled:
            body = "hand end cancelled (tiles reappeared)"
        case let .handEnded(winner):
            body = "HAND ENDED (winner: \(winner.map { "\($0)" } ?? "draw"))"
        case let .stateRevised(reason):
            body = "state revised: \(reason.rawValue)"
        }
        let flagsSuffix = event.flags.isEmpty ? ""
            : "  [" + event.flags.map(\.rawValue).sorted().joined(separator: ", ") + "]"
        return "[\(formatT(event.at))] \(body)\(flagsSuffix)"
    }

    static func kindLabel(_ kind: GameEvent.Kind) -> String {
        switch kind {
        case .handStarted: return "handStarted"
        case .discard: return "discard"
        case .myDraw: return "myDraw"
        case .myDiscard: return "myDiscard"
        case .meld: return "meld"
        case .myHandComplete: return "myHandComplete"
        case .handEndProposed: return "handEndProposed"
        case .handEndCancelled: return "handEndCancelled"
        case .handEnded: return "handEnded"
        case .stateRevised: return "stateRevised"
        }
    }

    // MARK: - Summary

    static func printSummary(_ result: ReplayResult) {
        print("")
        print("-- summary --")
        print("frames processed: \(result.frameCount)")
        print("total events: \(result.events.count)")
        var byKind: [String: Int] = [:]
        for event in result.events { byKind[kindLabel(event.kind), default: 0] += 1 }
        for label in byKind.keys.sorted() {
            print("  \(label): \(byKind[label]!)")
        }
        print("hand-end proposals: \(result.handEndProposedCount)")

        let s = result.finalState
        let opponentMeldTiles = s.opponentMelds.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        let seenTotal = s.seenHistogram.reduce(0, +)
        print("final state: phase=\(s.phase.rawValue)  hand=\(s.myHand.count)  pond=\(s.pond.count)  " +
              "opponentMelds=\(opponentMeldTiles)  unresolved=\(s.unresolved.count)  " +
              "seenTotal=\(seenTotal)  unseenCount=\(s.unseenCount)")
        print("diagnostics: live=\(result.diagnostics.live)  tentative=\(result.diagnostics.tentative)  " +
              "missing=\(result.diagnostics.missing)  retired=\(result.diagnostics.retired)")
    }

    // MARK: - events.jsonl output

    static func writeEventsFile(for url: URL, mySeatWind: Wind, roundWind: Wind, result: ReplayResult) throws {
        // Mirrors detect-dump's own `<photo>.boxes.json` naming idiom:
        // strip the input's own extension, append the output one.
        let outURL = url.deletingPathExtension().appendingPathExtension("events.jsonl")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outURL.path) else {
            throw CLIError("could not open output file \(outURL.path)")
        }
        defer { try? handle.close() }

        let eventsHeader = EventStreamHeader(source: url.lastPathComponent,
                                             seat: windCode(mySeatWind), round: windCode(roundWind))
        try handle.write(contentsOf: FrameStream.line(eventsHeader))
        for event in result.events {
            try handle.write(contentsOf: FrameStream.line(EventRecord(event)))
        }
        print("wrote \(result.events.count) events → \(outURL.lastPathComponent)")
    }
}

// MARK: - Wind CLI codes

/// `Wind` itself has no code accessor in `MahjongCore` (only `Tile.code`
/// does) and this tool must not touch `Packages/` — reuse `Tile.wind(_:)`/
/// `Tile.code`/`Tile.init(code:)` instead of duplicating the E/S/W/N
/// mapping.
func parseWind(_ raw: String) -> Wind? {
    guard let tile = Tile(code: raw), case let .wind(wind) = tile else { return nil }
    return wind
}

func windCode(_ wind: Wind) -> String { Tile.wind(wind).code }

// MARK: - Formatting

func formatT(_ t: TimeInterval) -> String { String(format: "%.1fs", t) }
func formatConf(_ c: Double) -> String { String(format: "%.2f", c) }

// MARK: - events.jsonl schema

struct EventStreamHeader: Encodable {
    var schema = "mj-events/1"
    var kind = "header"
    var source: String
    var seat: String
    var round: String
}

/// Deterministic mirror of `GameEvent` for JSONL output. `GameEvent.flags`
/// is a `Set<GameEvent.Flag>`, and Swift's `Set` iteration order is seeded
/// per process launch (confirmed empirically — the same five-flag set
/// encodes in a different order on every run) — encoding it directly would
/// make `<input>.events.jsonl` non-reproducible byte-for-byte across runs
/// even though the event log's *content* never changes. This wrapper sorts
/// flags into a stable array before encoding; every other field is a
/// verbatim passthrough of the already-`Codable` `GameEvent`.
struct EventRecord: Encodable {
    var id: Int
    var at: Double
    var handIndex: Int
    var kind: GameEvent.Kind
    var confidence: Double
    var flags: [GameEvent.Flag]

    init(_ event: GameEvent) {
        id = event.id
        at = event.at
        handIndex = event.handIndex
        kind = event.kind
        confidence = event.confidence
        flags = event.flags.sorted { $0.rawValue < $1.rawValue }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
