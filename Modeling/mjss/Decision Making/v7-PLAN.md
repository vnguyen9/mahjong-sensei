# Production HK Mahjong Simulator and Policy Certification Plan

## 1. Objective, current status, and release standard

Build a rules-certified simulator and a Coach policy that is demonstrably reliable for the versioned three-faan Hong Kong Mahjong style used by Mahjong Sensei.

Current policy v6 and its 20,000-round result remain immutable historical artifacts. They prove that v6 learned effectively inside simulator v1, but they do not qualify it for production because simulator defects affect tile accounting, claims, flowers, payments, replacement draws and scoring context.

Production release requires all of the following:

- A signed, versioned rules contract backed by HKMA references and expert-reviewed examples.
- Zero unexplained differences against the golden corpus and independent implementations.
- Exact tile conservation and deterministic replay through at least 10 million fuzzed legal actions.
- A newly trained policy under the certified simulator and corrected observation schema.
- Statistically significant performance against independent baseline agents and opponent populations.
- Blinded expert review and a guarded real-table Coach pilot.
- Python/Core ML parity, schema compatibility enforcement and safe abstention on incomplete tracker state.

Preserve these existing identifiers and artifacts:

- `hk_3faan_v1`, `obs_v2` and policy-v6 checkpoints remain frozen for provenance.
- `actions_v1_127` remains the action contract unless certification discovers a genuinely unrepresentable legal action.
- Create `hk_3faan_v2` and `obs_v3` for production; never silently change v1/v2 semantics.
- Label policy v6 as `simulation-v1 benchmark`, not `production champion`.

Target product is a ranked-action Coach, not an autonomous bot. Initial release is one fixed three-faan preset with a guarded beta.

## 2. Research and rules-certification foundation

### Research artifacts

Create a maintained research package containing:

- `RESEARCH_BASELINE_MATRIX.md`: source, Mahjong variant, license, rules coverage, reusable concepts and limitations.
- `RULES_PROVENANCE_HK_3FAAN_V2.md`: every rule linked to HKMA, another source, or an explicit product decision.
- `SIMULATOR_CERTIFICATION_V2.md`: test results, differential findings, fuzz totals, known deviations and sign-offs.
- `MODEL_CARD_POLICY_V7.md`: training lineage, metrics, limitations, intended use and rollback information.

Use this reference hierarchy:

1. [Hong Kong Mahjong Association](https://www.hkmahjong.org/rules?lang=en) as the primary written rules authority.
2. Three independent HK Mahjong experts for ambiguity resolution and golden-case approval.
3. Python [`hk-mahjong` 0.1.0](https://pypi.org/project/hk-mahjong/) as a pinned secondary differential implementation, never the sole oracle.
4. [OpenSpiel](https://arxiv.org/abs/1908.09453) for game/state/chance/observation architecture.
5. [MJX](https://ieee-cog.org/2022/assets/papers/paper_162.pdf) for event protocol, reproducibility and simulator benchmarking.
6. [Let’s Play Mahjong!](https://arxiv.org/abs/1903.03294) for deficiency and \(k\)-change baselines.
7. [Suphx](https://arxiv.org/abs/2003.13590) and Mortal as training and evaluation references only; their Riichi strategy is not HK evidence.
8. Duplicate-wall and seat-rotation evaluation from the [Official International Mahjong benchmark](https://www.mdpi.com/1999-4893/16/5/235).

Pin every external executable reference by version, commit and SHA-256. Run it through an adapter outside the production engine so it does not become a runtime dependency.

### Rules contract

Create `hk_3faan_v2` as a complete, immutable contract covering:

- 144 physical tiles: 136 regular plus eight bonus tiles.
- Three-faan minimum and thirteen-faan cap.
- Exact scoring patterns, exclusions, stacking and limit-hand behavior.
- One discard winner, resolved by nearest seat after the discarder.
- Claim priority: win first; Pong and Kong share one priority class and resolve by seat order; Chow follows.
- Self-draw, discard-win and Kong payment vectors.
- Dealer, seat wind and prevailing wind indexing.
- Flower exposure and recursive rear-wall replacement.
- Seven-flower and eight-flower wins, including during the initial deal.
- Concealed, exposed and added Kong behavior.
- Robbing an added Kong.
- Last-tile, Kong-replacement and double-Kong conditions.
- Wall exhaustion, replacement exhaustion and malformed/false-win handling.
- Whether any rule varies in real tables; variations remain out of v2 rather than becoming runtime toggles.

The three experts independently review the contract. A case passes with at least two matching approvals and no unresolved objection. Any unresolved rules question blocks ruleset freeze.

### Golden corpus

Produce 300 manually inspectable fixtures:

- 80 structural-win and scoring-pattern cases.
- 40 below-minimum, invalid and near-winning cases.
- 50 claim-priority, simultaneous-reaction and rob-Kong cases.
- 40 flower, initial-replacement, seven/eight-flower and Kong-replacement cases.
- 30 dealer, seat, payment and zero-sum settlement cases.
- 30 last-tile, wall exhaustion and replacement exhaustion cases.
- 30 observation privacy, replay and tracker-to-state cases.

Each fixture contains the complete pre-state, offered/winning tile, legal actions, selected resolution, pattern breakdown, faan, winner, discarder, payment vector and source citation or expert decision. Fixtures must not depend on the simulator to generate their expected results.

## 3. Simulator, observation, and integration implementation

### Authoritative state model

Refactor the core around explicit physical tile instances while retaining type-based tensors:

- `TileInstance`: immutable ID `0...143`, tile type and bonus identity.
- `GameState`: complete authoritative state, including wall order and concealed opponents.
- `PublicObservationV3`: only information legally visible to one seat.
- `GameEventV2`: deal, draw, flower, replacement, discard, Chow, Pong, Kong, pass, win and exhaustive draw.
- `ChanceOutcome`: explicit sampled or externally supplied wall outcomes.
- `TerminalResult`: cause, winner, discarder, pattern breakdown and four-seat payment vector.
- `ReplayV2`: rules hash, seed/wall, initial dealer, ordered events and terminal result.

Each physical tile must occupy exactly one location: live wall, replacement end, concealed hand, exposed meld, river, flower area or terminal winning context. A claimed discard moves from the river into a meld; its historical discard event remains in the replay but is not counted as another physical tile.

Expose a stable engine interface:

```text
new_game(ruleset, seed | supplied_wall) -> GameState
current_actor(state) -> seat | chance | terminal
legal_actions(state, actor) -> ActionMask127
apply_action(state, action) -> GameState
observation(state, seat) -> PublicObservationV3
terminal_result(state) -> TerminalResult | null
serialize_replay(state) -> ReplayV2
replay(events) -> GameState
check_invariants(state) -> InvariantReport
```

The environment core must not import PyTorch, Core ML, PettingZoo, camera or UI code.

### Mandatory simulator fixes

Implement and regression-test these corrections:

- Remove claimed tiles from physical river counts while retaining discard history.
- Compute remaining-tile belief from unique physical visibility, without double-counting claimed discards.
- Resolve Pong and Kong in one priority class by seat distance; do not grant Kong unconditional priority over Pong.
- Perform recursive flower replacements from the rear/replacement end of the wall.
- Check seven/eight-flower wins during the initial deal and every replacement chain.
- Use absolute seat IDs consistently for dealer, winner, discarder and payments.
- Pass the actual winning tile into structural decomposition and scoring for both self-draw and claim wins.
- Make wait-sensitive scoring evaluate the winning tile’s role in each valid decomposition.
- Distinguish ordinary draw, flower replacement and Kong replacement in state and replay.
- Preserve reaction observations before any opponent response so later actors cannot infer earlier passes or claims.
- Prevent hand overflow, double draws, double settlement and action application after terminal state.
- Replace the current count-based invariant with exact instance-level conservation.
- Require every terminal payment vector to sum to zero.
- Validate supplied walls: 144 unique valid tile instances with correct multiplicities.

### Observation schema and model compatibility

Create `obs_v3` even if tensor dimensions remain `65 × 34 + 72`. Its semantic changes require a new schema hash:

- Visible counts represent unique physical public tiles.
- Remaining belief equals four minus own concealed copies and unique public copies.
- Claimed river events remain available to history features but not physical-count features.
- Offer tile/source, phase, winds, flowers, meld kind and known/missing flags retain explicit encoding.
- No wall order, future draws or opponent concealed tiles may enter observations or lookahead calculations.
- Lookahead must use public remaining belief rather than authoritative hidden wall contents.

Every checkpoint and Core ML package must carry:

- Rules profile ID and SHA-256.
- Observation schema ID and SHA-256.
- Action schema ID and SHA-256.
- Simulator version/commit.
- Training configuration and seeds.
- Parent checkpoint and initialization method.
- Checkpoint SHA-256.

Loaders and the app reject unknown or mismatched metadata instead of guessing.

### Coach integration contract

Add `CoachStateV1` as the boundary between tracker and Mahjong engine:

- Own concealed tiles and known/missing mask.
- Ordered per-seat rivers.
- Per-seat typed melds and exposed flowers.
- Dealer, seat wind and prevailing wind.
- Current actor/phase.
- Offered tile and source seat when known.
- Estimated wall position and confidence.
- Tracker confidence and manually corrected fields.

Return `CoachRecommendationV1`:

- Top three legal actions.
- Normalized probabilities.
- State-value estimate.
- Rules, observation and model hashes.
- Data-quality status: `valid`, `degraded` or `abstain`.
- Machine-readable abstention reason.

Abstain when own-hand count is inconsistent, actor/phase is unknown, a physical tile count exceeds four, required offer information is missing, or schema hashes mismatch. Degraded state may show recommendations only when all legal actions can still be determined.

## 4. Verification, baselines, retraining, and certification

### Simulator verification gates

Run gates in this order:

1. Existing 236-test suite remains green, with outdated expectations explicitly migrated rather than silently removed.
2. All 300 signed golden fixtures pass.
3. Differential comparison with pinned `hk-mahjong` passes on the common rules subset with zero unexplained mismatches.
4. Replay round-trip produces an identical state and terminal result for 100,000 seeded rounds.
5. Property/fuzz testing executes at least 10 million legal actions with invariants checked after every action.
6. Forced malformed actions are rejected without mutating state.
7. Sampled-wall and supplied-wall modes produce identical trajectories when given the same wall.
8. Python scalar and any optimized/vectorized engine produce identical legal masks, events, observations and returns.
9. Information-leak tests perturb hidden opponent hands and future wall order while holding public information constant; observations and logits must remain unchanged.
10. Eight-worker throughput reaches at least 500 decisions/second on the current Mac, or no more than a 20% regression from the certified pre-optimization benchmark.

No neural retraining begins before gates 1–9 pass. Performance optimization may not alter the scalar reference engine; optimized paths must be differential-tested against it.

### Independent baseline ladder

Implement and freeze these agents:

- Uniform random legal agent.
- Deficiency/shanten-minimizing agent.
- Ukeire-maximizing agent.
- Two-change completion-probability agent based on “Let’s Play Mahjong!”
- Faan-aware offensive agent.
- Safety-aware agent using public discards, exposed melds and opponent pressure.
- Shallow rollout/search agent using public-state determinizations.
- Historical v5b and v6 compatibility agents where their schemas permit evaluation.

Test monotonicity over duplicate schedules. Each intended stronger heuristic must have a positive paired payment estimate over the preceding simpler baseline; failures trigger agent review before using the ladder for policy certification.

### Policy v7 training

Do not directly promote v6 or distill its flawed-simulator decisions as ground truth.

Run two 1-million-decision initialization pilots:

- Candidate A: policy-v6 representation weights, with policy/value output layers reset, followed by behavior cloning from certified heuristic teachers.
- Candidate B: fresh network initialization followed by the same behavior cloning data.

Evaluate both on the same 10,000 duplicate development schedules. Select the initialization with the higher paired-payment lower confidence bound; if intervals overlap, select fresh initialization to minimize inherited simulator bias.

Train three independent seeds of the selected initialization:

- Certified simulator and `obs_v3`.
- Payment-only terminal reward divided by the fixed maximum payment.
- No win bonus or simulator-specific reward shaping.
- Parameter-shared league with current policy, frozen recent snapshots, v6 compatibility agent and all certified heuristics.
- Teacher-prefix curriculum may be used only during the first two million decisions and must decay to zero.
- Checkpoints at 1M, 2M, 4M, 8M and 12M decisions.
- Continue beyond 12M only if development payment improves by at least 0.25 per round between the final two checkpoints and training diagnostics remain stable.
- Select seed/checkpoint only from frozen development schedules.

Monitor payment, win rate, deal-in rate, average winning faan, action distribution, legal entropy, value explained variance, KL, per-seat performance and per-opponent-suite performance.

### Statistical certification

Open the untouched final schedule only after selecting one checkpoint.

Run 100,000 paired focal rounds:

- Ordinary legal walls, not stable-draw-wall variants.
- Four-seat rotations.
- Fixed common walls for candidate and comparator.
- At least five suites: Ukeire, FaanAware, safety-aware, strongest search agent and mixed frozen neural snapshots.
- 20,000 schedules per suite, balanced across seats.
- 20,000 bootstrap resamples for paired-payment intervals.

Promotion requires:

- Overall paired-payment 95% lower confidence bound greater than zero versus the strongest certified baseline.
- Positive overall lower bound versus historical v6 where compatibility evaluation is valid.
- No opponent-suite lower bound below `-0.5` payment per round.
- No seat lower bound below `-0.5`.
- Deal-in rate no more than one percentage point worse than the strongest safety-aware comparator unless payment improvement remains positive within each game stage.
- Zero illegal actions or failed settlements.
- No metric recomputation or threshold change after opening the final schedule.

Win rate is reported with a Wilson interval but is not a standalone promotion gate.

### Expert and real-table validation

Build a blinded 500-position review set:

- 250 discard decisions.
- 100 Chow/Pong/Kong/pass decisions.
- 50 win/pass and minimum-faan decisions.
- 50 defensive late-hand positions.
- 50 incomplete/noisy tracker positions.

Three experts review candidate recommendations without knowing whether they came from v7, v6 or a heuristic. Production acceptance requires:

- Majority rates the top recommendation acceptable in at least 85% of valid positions.
- Top three include a majority-accepted action in at least 95%.
- Severe/blunder rating below 3%.
- Illegal recommendation rate exactly zero.
- Correct abstention in at least 95% of positions missing information required for legality.

Then run a guarded pilot of at least 50 complete table sessions and 5,000 valid recommendation opportunities:

- Advice is visible only to internal testers or consenting beta users.
- Log tracker input, corrections, model output, latency, selected human action and eventual outcome.
- Never log unredacted camera frames by default.
- Experts review every reported bad recommendation and a random 10% sample.
- Pilot passes with zero illegal recommendations, severe-blunder rate below 1%, and at least 90% recommendation availability on tracker states classified as valid.

## 5. Core ML, rollout, acceptance, and schedule

### Core ML and device gates

Export only the certified checkpoint. On 10,000 frozen observations compare PyTorch CPU, PyTorch MPS and Core ML:

- Legal mask agreement: 100%.
- Top-one agreement: at least 99.9%.
- Top-three set agreement: at least 99%.
- Maximum action-probability difference: at most 0.01.
- Value mean absolute error: at most 0.01.
- NaN/Inf outputs: zero.

On the oldest supported iPhone:

- Model inference p95 at or below 50 ms.
- Complete recommendation p95 at or below 100 ms after tracker state stabilization.
- No memory growth over a 60-minute session.
- Model/rules/schema mismatch produces abstention and a recoverable user-facing message.

### Rollout stages

1. **Research/internal:** simulator certification and offline training only.
2. **Shadow mode:** recommendations logged but not shown; compare tracker-derived state with manually corrected state.
3. **Expert beta:** show advice to internal experts with one-tap correction/reporting.
4. **Guarded public beta:** fixed rules preset, explicit beta label, telemetry opt-in and immediate rollback capability.
5. **Production:** only after simulator, statistical, expert, pilot and Core ML gates all pass.

Ship model and rules as an atomic signed bundle. Retain the prior bundle for one-step rollback. Promotion records must include hashes, evaluation report and sign-off identities.

### Estimated sequence

For one primary engineer plus three part-time experts:

- Research matrix and rules contract: 1–2 weeks.
- Simulator repair and event/state refactor: 2–3 weeks.
- Golden corpus, differential and fuzz certification: 2–3 weeks.
- Observation/Coach integration and Core ML metadata: 1–2 weeks.
- Baselines, pilots and three-seed training: 2–4 weeks.
- Final statistical and expert evaluation: 1–2 weeks.
- Real-table guarded pilot: 2–4 calendar weeks.

Expected total: approximately 11–16 weeks, primarily dependent on expert review and pilot-table availability.

### Fixed assumptions

- One immutable three-faan HK preset is in scope; configurable house rules are deferred.
- Three experts are available; two-person agreement is sufficient unless an objection remains unresolved.
- The first production surface is Coach recommendation, not autonomous play.
- Current policy v6 is retained as a benchmark and possible representation initializer, never accepted unchanged.
- Correctness and external validity take precedence over simulator throughput.
- No claim of “good enough for real Mahjong” is made until every mandatory gate above passes.
