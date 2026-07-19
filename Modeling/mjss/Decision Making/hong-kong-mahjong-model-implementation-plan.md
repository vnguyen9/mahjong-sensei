# Hong Kong Mahjong Playing Model — Research and Implementation Plan

*Planning document only — updated 2026-07-18*

## Executive recommendation

Build this as three separate systems with a strict interface between them:

1. **Hong Kong Mahjong Learning Environment** — a Hanabi/OpenSpiel-style game core with an immutable
   rules specification, full state, player-filtered observations, stable action IDs, explicit chance
   outcomes, scoring, cloning, replay, and thin RL adapters.
2. **Decision model** — a small PyTorch policy/value network trained first from a strong heuristic
   teacher—including an exact deficiency/k-step lookahead teacher—then with masked PPO and league
   self-play.
3. **Coach adapter** — converts the camera/tracker state into exactly the public information a real
   player can see, runs the policy, and presents ranked legal actions.

The simulator is the critical path. Do **not** start serious reinforcement learning until its rules,
scoring, and claim resolution pass a large test suite. RLCard's built-in Mahjong is intentionally a
simplified 136-tile game in which all complete hands have equal value and rewards are only +1/-1;
that would train the wrong strategy for a 3-faan Hong Kong game. MJX and the newer Mahjax are useful
engineering references, but both target Japanese Riichi rather than Hong Kong rules.

A detailed review of DeepMind's Hanabi Learning Environment changes the internal architecture, not
the rules-first conclusion. Its clean separation of `Game`, omniscient `State`, player-relative
`Observation`, stable `Move` IDs, chance outcomes, and `ObservationEncoder` is the right pattern for
this project. PettingZoo should be a compatibility adapter around that core, not the game engine.
Do not fork the archived Hanabi codebase: implement the same concepts for Hong Kong Mahjong with a
modern Python reference core, then port only measured hotspots to Rust/C++ if required.

The recommended first useful model is a **discard advisor** that matches the table-aware Coach data
already planned. The full-playing model follows after the simulator supports Chow/Pong/Kong/win
reactions and the live tracker can identify per-player events. This gives a usable milestone before
solving every part of the game.

## Findings from the additional reference review

| Reference | What it contributes | Limitation | Decision |
|---|---|---|---|
| [`lucylow/Deep-Learning-Mahjong---`](https://github.com/lucylow/Deep-Learning-Mahjong---) | HK-oriented tile/pattern checklist and broad product ideas | Current master is a concept README; the named game, model, requirements, package, and test files contain no implementation | Do not use as a code or training base |
| [*Let's Play Mahjong!*](https://arxiv.org/abs/1903.03294) | Formal deficiency, available-tile knowledge base, and exact recursive `k`-change discard value | “Mahjong-0” uses only 108 suited tiles; no honors, bonuses, HK scoring, defense, or full claim play; Kongs are ignored | Implement an extended version as a deterministic teacher and test oracle |
| [Hanabi Learning Environment](https://github.com/google-deepmind/hanabi-learning-environment) | Compiled game core, state/observation separation, move IDs, explicit chance, cloning, encoder, Python RL wrapper | Different cooperative game; repository archived in 2024; older C++/CFFI wrapper | Adopt the architecture, not the codebase |
| [OpenSpiel concepts](https://github.com/google-deepmind/open_spiel/blob/master/docs/concepts.md) | Maintained Game/State/chance-node model and imperfect-information research adapters | General research framework is not the high-throughput learner itself | Keep an optional adapter; do not couple the core to it |

## What “can play Hong Kong Mahjong” means

The end-state policy must be able to:

- discard after a draw or claim;
- pass, Chow, Pong, or Kong when legally offered;
- declare concealed and added Kongs;
- declare self-draw, discard wins, and robbing-a-Kong wins when legal;
- account for flowers/seasons and replacement draws;
- pursue hands that satisfy the configured minimum, initially **3 faan**;
- trade off hand speed, hand value, live tiles, deal-in risk, and wall position;
- use only information visible to the acting player at inference time;
- return a ranked legal-action list for the Coach, not merely one opaque action.

Start with one independently scored hand/round. Add dealer continuations, complete match rotation,
and match-level score strategy only after round play is demonstrably sound.

## First decision: freeze a versioned rules profile

“Hong Kong style” is not one universal scoring table. The supplied Coach note fixes a 3-faan
minimum, but the following still need an explicit decision. Store the result in a versioned file
such as `configs/rules/hk_3faan_v1.yaml`, and put its hash in every replay and model checkpoint.

| Rule question | Recommended v1 choice | Why it must be explicit |
|---|---|---|
| Tile set | 136 regular + 8 flowers/seasons | Matches the physical detector and common HK play |
| Minimum to win | 3 faan | Already assumed by the Coach/model research |
| Faan cap / limit | Confirm before implementation | Common tables use different caps |
| Faan-to-payment table | Configurable, one selected default | Raw faan and actual utility are not the same |
| Dealer and self-draw payments | Confirm exact doubling rules | Changes both attack and defense strategy |
| Multiple winners on one discard | Select one-winner or multi-winner | Changes claim resolution and reward |
| Special hands | Enumerate the accepted list | Seven pairs, thirteen orphans, heavenly hand, etc. vary |
| Pattern stacking/exclusions | Write every exclusion | Prevents double-counted faan |
| Flower scoring | Identity, seat matching, no-flower, complete sets | A count alone is insufficient for some rules |
| Claim priority | Win > Pong/Kong > Chow, then seat order unless profile says otherwise | Must be deterministic |
| Last tile / Kong / flower replacement | Specify wall and replacement behavior | Affects legality and special faan |
| False-win and dead-hand penalties | Omit from RL v1 or define them | Legal masking normally makes these unreachable |

Use the [Hong Kong Mahjong Association rules page](https://www.hkmahjong.org/rules?lang=en) and its
linked English rules as the primary written reference. The 2026 MIT-licensed
[`hk-mahjong` package](https://pypi.org/project/hk-mahjong/) can be audited as a secondary reference
and test oracle, but its v0.1.0 status and small codebase mean it should not be accepted as the source
of truth without cross-checking.

### Rules acceptance artifact

Before coding the simulator, prepare a table of at least 100 human-reviewed examples containing:

- concealed tiles, exposed melds, flowers, seat wind, prevailing wind, win source, and last-event
  flags;
- whether the hand is structurally complete;
- every recognized scoring pattern and its faan;
- whether the 3-faan gate allows the win;
- final payments to all four players.

Include normal hands, every special hand, every pattern interaction, near misses, illegal claims,
four-copy limits, multiple possible hand decompositions, and boundary values at the minimum/cap.
This corpus becomes the scorer's permanent golden test suite.

## System architecture

```text
Physical table / simulator
          |
          v
Canonical public state + legal action mask
          |
          +--> deterministic Coach features (shanten, live outs, faan paths)
          |
          v
Policy/value network --> ranked legal actions --> Coach explanation/UI
```

Keep perception and decision learning separate. The initial policy is trained on perfect simulator
observations, not photographs. Detector/tracker errors are introduced later as controlled state
noise. This makes it possible to tell a bad policy from a bad camera reading.

### Important change to the current Coach contract

The existing **MINE/TABLE** split is sufficient for `4 - visible` live-out calculations, but not for
a model that fully plays the game. Opponent modeling and defense require:

- which seat made each discard and the discard order;
- which seat owns each exposed meld and whether it is Chow/Pong/Kong;
- the last discard/claim and whose reaction window is active;
- each player's flowers/seasons;
- seat wind, prevailing wind, dealer, turn number, and wall remaining.

Define one canonical `PublicObservationV1` now. Fields can carry an `unknown`/missing mask so the
same model can consume a coarse camera scan or a complete simulated history. Never fill unknown
opponent information with hidden simulator truth.

## Proposed repository layout

This is a future implementation layout; no code is created by this planning task.

```text
mahjong_ai/
  pyproject.toml
  configs/
    rules/hk_3faan_v1.yaml
    train/bc_mps.yaml
    train/ppo_mps.yaml
    train/ppo_cuda.yaml
  src/hkmahjong/
    core/           # GameSpec, Action, State, Observation, chance, replay
    rules/          # win decomposition, faan, settlement
    sim/            # wall, transitions, reaction resolution, event log
    encoders/       # canonical observation tensors and missingness masks
    adapters/       # PettingZoo; optional OpenSpiel; vector rollout API
    agents/         # random, heuristic, frozen neural policies
    models/         # shared encoder, policy heads, value head
    training/       # behavior cloning, PPO, league, checkpoints
    evaluation/     # tournaments, confidence intervals, reports
    export/         # Core ML conversion and parity checks
  tests/
    rules/
    simulator/
    properties/
    fixtures/
  artifacts/        # gitignored checkpoints, replays, metrics
```

The environment core should not import PyTorch, PettingZoo, OpenSpiel, the camera code, or UI code.
That keeps rules tests fast, prevents framework semantics from leaking into the game, and allows a
later Rust/C++ performance port without changing the Python-facing contract.

## Simulator design

### Hanabi/OpenSpiel-style internal contract

The internal API should be the primary design artifact:

```text
HKGameSpec
  new_initial_state(seed, chance_mode) -> HKState
  action_from_id(id) -> HKAction
  rules_hash / observation_schema / action_schema

HKState
  current_actor() / active_players()
  legal_actions(player) -> list[HKAction]
  chance_outcomes() -> list[(HKChanceOutcome, probability)]
  apply_action(action) / submit_reaction(player, action)
  clone() -> HKState
  observation(player) -> HKObservation
  is_terminal() / returns() / result()

HKObservation
  player-relative public information only
  legal action IDs and current decision context

HKObservationEncoder
  encode(observation) -> fixed tensors + legal mask
```

`HKGameSpec` is immutable and owns rules/action definitions. `HKState` contains all hidden truth and
is cloneable for search. `HKObservation` is constructed from a specific player's perspective and is
the only state the actor may consume. The encoder is separately versioned so feature experiments do
not alter rules or replays.

PettingZoo wraps this contract for multi-agent tooling. An OpenSpiel adapter can be added for
information-set search, PSRO, or research comparisons, but neither framework owns the rules.

### Canonical types

- `Tile34`: the 34 regular tile types used by the policy.
- `BonusTile8`: four flowers and four seasons; these are metadata, not discard actions.
- `Meld`: Chow, Pong, exposed Kong, concealed Kong, or added Kong; include source seat/tile.
- `PlayerState`: concealed counts, melds, flowers, seat, score.
- `RoundState`: wall, replacement area if the profile uses one, public event log, phase, current
  player, winds, and pending claims.
- `Action`: one of the fixed legal action IDs below.
- `RoundResult`: cause, winning player(s), patterns, faan, and a four-player payment vector.

### State machine

Implement explicit phases rather than scattered conditionals:

1. deal regular tiles and automatically expose/replace bonus tiles;
2. draw from the normal wall or the configured replacement source;
3. self-action window: win, concealed/added Kong, or discard;
4. reaction window after a discard or added Kong;
5. resolve all reactions using the configured win/claim priority;
6. after a claim, enter discard/self-action without an extra normal draw;
7. terminate on legal win or exhausted wall and settle all four rewards.

Every transition writes a compact event. A seed plus the ordered event log must replay to the same
state and result byte-for-byte.

### Reaction windows must not leak information

Unlike Hanabi, one Mahjong discard may invite reactions from up to three players. Represent this as
an explicit `REACTION` phase with `active_players()` and private `pending_reactions`, followed by a
single `RESOLVE` transition.

If an AEC adapter queries players sequentially, every eligible player must receive the same frozen
pre-reaction public observation. Do not reveal earlier passes or claims to later responders. After
all eligible actions are submitted, resolve wins/claims using the configured priority and seat rule.
This preserves the intended simultaneous information set while remaining compatible with a
turn-based API.

### Two chance modes

- **`sampled_wall`** — shuffle once at reset and record the wall seed/order. Use for fast self-play,
  deterministic replay, and most evaluation.
- **`enumerated_chance`** — expose legal next-tile outcomes and probabilities from the true wall in
  the omniscient state. Use for exact simulator tests, expectimax, and search experiments. A deployed
  player-side teacher must instead form its own distribution from `HKObservation`; it may never read
  hidden wall or opponent-hand truth through this API.

Both modes must produce identical distributions. Differential tests should compare their aggregate
outcomes on small controlled states.

### Fixed action space and legality mask

A simple initial 127-action encoding is enough:

| IDs | Meaning |
|---|---|
| 0 | Pass |
| 1 | Win in the current context |
| 2–35 | Discard one of 34 regular tile types |
| 36–56 | Chow using one of the 21 suited sequences |
| 57 | Pong the current offered tile |
| 58 | Kong the current offered tile |
| 59–92 | Concealed Kong of one of 34 tile types |
| 93–126 | Add one of 34 tile types to an exposed Pong |

Draws and bonus-tile replacement are environment events, not learned actions. The legality mask is
computed by the rules engine before every decision. A Win action is legal only when the hand is
complete **and** the scorer says the configured minimum faan is met. Invalid-action masking is a
well-supported policy-gradient technique and is particularly important when most fixed actions are
illegal in a given state.

### Simulator verification gates

Do not start PPO until all of these are green:

- golden scorer corpus passes;
- deterministic replay passes across processes;
- tile conservation holds at every random transition;
- no regular tile count exceeds four and no bonus identity appears twice;
- concealed tile count agrees with melds, draw/discard phase, and Kongs;
- only the player-facing information is present in an observation;
- clone + apply leaves the original state unchanged and produces the same result as direct replay;
- changing reaction-query order cannot change observations or the resolved outcome;
- sampled-wall frequencies agree with enumerated chance probabilities on controlled tests;
- one million random legal actions run without a state invariant failure;
- PettingZoo's API tests pass for the adapter;
- a fixed performance benchmark reports decisions/second and complete rounds/second.

[PettingZoo's AEC API](https://pettingzoo.farama.org/api/aec/) fits turn-based games and supports
action masks. Use it as a compatibility/testing adapter with frozen reaction observations, while
keeping a direct batched simulator API for faster training. Add an OpenSpiel adapter only when a
specific search/game-theoretic experiment needs it.

## Baseline agents before neural training

Build these in order. They prove that the simulator and evaluation harness can distinguish skill.

1. **RandomLegalAgent** — samples only from the legal mask.
2. **DeficiencyAgent** — implements the paper's minimum tile-change distance on closed structural
   hands; first reproduce its 108-suited-tile cases, then extend to honors and exposed melds.
3. **UkeireAgent** — uses shanten/ukeire and the existing table-aware visible histogram.
4. **KStepLookaheadTeacher** — recursively estimates the probability of a legal completion within
   `k` changes using remaining-copy counts. Start with exact `k=1`, memoized `k=2`, and benchmark
   before increasing depth.
5. **ScoreAwareAgent** — adds legal 3-faan paths, live-tile weighting, open/closed hand value,
   flower/wind context, and simple call thresholds.
6. **SafetyAgent** — adds opponent-visible information, exhausted-tile evidence, suit pressure,
   visible honors, and wall-stage attack/defense thresholds. Do not import Riichi-only furiten or
   “genbutsu is absolutely safe” assumptions into Hong Kong play.
7. **RolloutTeacher** — for difficult states, evaluates the top heuristic actions over many seeded
   continuations against fixed baseline opponents.

The existing deterministic EfficiencyEngine is valuable as the UkeireAgent/feature oracle. It
should remain available after learning so the Coach can explain *why* a neural action is plausible.
The deficiency and k-step implementations should be compared against it on the same states. They
are teacher/baseline tools, not the production reward: the source paper omits HK faan, defense,
honors, bonus tiles, and full opponent behavior.

### Extending the paper's k-step value to Hong Kong play

The paper represents believed remaining tiles as a 27-value knowledge base. Extend this to the 34
regular tile types:

```text
remaining[t] = clamp(4 - own_concealed[t] - public_visible[t], 0, 4)
```

Here `public_visible` includes all exposed melds—including the player's own—and all discards, but
not the player's concealed hand. `remaining` is a player belief over wall plus opponent-concealed
copies; it is deliberately different from the omniscient state's exact wall counts.

Honors may complete pairs/Pongs but never Chows. Exposed melds reduce the number of concealed sets
still required. A terminal leaf counts only if the HK scorer says the hand is legal at 3+ faan.
For a score-aware teacher, weight a legal leaf by expected settlement rather than treating every
completion equally.

Use the resulting action values in three places: behavior-cloning labels, an interpretable Coach
baseline, and an auxiliary target for representation learning. Do not recurse through guessed
opponent hands; once calls, defense, and opponent actions dominate, switch to seeded simulator
rollouts.

## Observation representation

Use a player-relative observation. Seat 0 always means “me”; other seats are ordered by turn
distance. The actor never receives the wall order or opponents' concealed tiles.

### Tile planes: `C x 34`

Recommended groups are:

- unary own-hand counts (four planes);
- just-drawn tile and current offered tile;
- own meld composition;
- per-opponent exposed Chow/Pong/Kong counts;
- per-seat discard counts plus the last N discard/event positions;
- total visible/dead counts and inferred remaining copies;
- deficiency, k-step completion values, potential waits, shanten buckets, and legal-faan-path
  features from deterministic analysis;
- missing/uncertain masks for camera-derived fields.

The exact channel count should be versioned, not hard-coded into saved data. A count of 2 is better
encoded consistently (for example, the first two unary planes are on) than as an ambiguous float.

### Scalar/context branch

Include one-hot or normalized fields for seat wind, prevailing wind, dealer, wall remaining, turn,
meld counts, flower identities/counts, current phase, last actor, and rules-profile features.

### Event-history branch

For the full player, encode the most recent fixed-length public event sequence with a small GRU or
event encoder. For the first discard-only model, fixed recency planes are simpler and easier to
export. Add recurrence only after it beats the static model in a controlled ablation.

### Network

Start with a 1–3 million parameter shared actor/critic trunk:

- small residual 1-D tile encoder with **no pooling**;
- explicit boundaries between characters, bamboo, dots, and honors so convolution does not invent
  adjacency across suits;
- small MLP for scalar context;
- optional small event encoder;
- concatenated trunk feeding a 127-logit policy head and scalar value head.

Suphx also represents Mahjong state with multiple 34-column channels and avoids pooling because each
column has fixed semantic meaning. Suphx used separate decision models; for this smaller project,
start with one shared trunk and masked head, then split discard/call heads only if training data shows
interference.

## Objective and reward

Do **not** use raw faan as the final reward. Faan determines win legality and is converted to a
nonlinear, capped payment. Optimizing only faan would teach the agent to ignore win probability,
deal-in loss, self-draw/discarder payments, and the cost borne by each opponent.

Use:

- zero reward on ordinary steps;
- at terminal, the actual four-player net payment vector from the configured rules profile;
- divide by the maximum absolute round payment to keep rewards in a stable range;
- record raw points and faan separately for evaluation.

For early learning, prefer behavior cloning, late-hand starting states, and auxiliary prediction
heads over arbitrary dense rewards. If shanten shaping is tested, make it a clearly flagged
experiment and verify that removing it does not collapse performance. The production champion must
win on settlement reward, not merely optimize a proxy.

## Training algorithm

### Stage A — behavior cloning from the teacher

Generate reachable public states by running the heuristic agents, the KStepLookaheadTeacher, and
seeded rollouts. Store:

- encoded public observation and its schema/rules hashes;
- legal action mask;
- teacher action or action-value distribution;
- terminal result and optional rollout return.

Train cross-entropy on legal actions plus value/teacher-action-value regression. Begin with states
where the exact or memoized k-step teacher is reliable, then mix in score-aware and rollout labels
for calls, defense, and longer horizons. This gives the policy legal, recognizable play before
sparse-reward RL. Human Hong Kong logs would improve this stage if a legal, consented source becomes
available, but they are not required for v1.

### Stage B — masked PPO

Use parameter-shared PPO: the same actor weights play any seat, with player-relative observations.
PPO is a practical first policy-gradient baseline, and Suphx likewise improved supervised Mahjong
policies using distributed, entropy-regularized policy gradients. Recommended initial settings are
starting points, not fixed truths:

| Setting | Initial range |
|---|---|
| Discount | 1.0 for a single round; compare 0.999 |
| GAE lambda | 0.95 |
| PPO clip | 0.2 |
| Update epochs | 3–5 |
| Entropy coefficient | 0.005–0.02 with monitoring |
| Learner batch | 4,096–16,384 decisions |
| Minibatch | 512–2,048, sized for device utilization |
| Gradient clipping | 0.5 |

The actor sees only the player's observation. Begin with the value head using the same information.
If value variance remains high, test a privileged centralized critic that sees the full simulator
state during training; the actor must still remain information-safe.

### Stage C — curriculum without changing the rules

Do not lower the 3-faan requirement as a shortcut. Instead:

1. sample valid late-hand states where a decision has a short outcome horizon;
2. reproduce the simplified closed-hand deficiency/k-step tasks before adding score complexity;
3. expand the starting distribution progressively toward the initial deal;
4. train discard-only decisions against heuristic opponents;
5. enable Chow/Pong/Kong/pass decisions;
6. enable full flowers, replacements, rare wins, and all special cases;
7. switch from mostly teacher opponents to the self-play league.

This improves reward density without teaching wins that are illegal in the target game.

### Stage D — self-play league

Pure “latest policy versus itself” can forget strategies and cycle. Maintain a league containing:

- the current learner;
- the current promoted champion;
- recent frozen snapshots;
- ScoreAwareAgent and SafetyAgent;
- RandomLegalAgent only for smoke tests.

A reasonable initial opponent mixture is 40% champion/recent snapshots, 30% current policy, and 30%
heuristic baselines. Snapshot periodically, but promote only through the fixed evaluation tournament.
Keep checkpoint, optimizer, RNG, observation schema, action schema, rules hash, source revision, and
training counters together.

## Evaluation and promotion

Every candidate plays the same seeded walls as the champion, rotates through all four seats, and
faces multiple opponent mixtures. Use paired bootstrap confidence intervals rather than one win
rate from a few games.

Track at least:

- average net settlement per round and its 95% confidence interval;
- win, self-draw, deal-in, and exhaustive-draw rates;
- average faan and payment conditional on winning;
- frequency of legal 3+ faan readiness versus structural-but-illegal readiness;
- Chow/Pong/Kong rates and value after each call type;
- result by seat, dealer status, wall stage, and major hand family;
- inference latency, simulator throughput, and learner GPU utilization;
- calibration of the value head against realized settlement.

Promotion gate:

1. no rules, legality, replay, or information-leak regression;
2. positive lower confidence bound versus the champion over a large paired tournament;
3. no material collapse against any fixed baseline or seat;
4. acceptable Coach latency and stable Core ML parity if the build is for the app.

Use 10,000 rounds for development comparisons and move toward 50,000–100,000 paired rounds for a
champion promotion once the simulator is fast enough. These are evaluation rounds, not training
steps.

## Training on this Mac (`device=mps`)

### Observed machine

- MacBook Pro with Apple M5 Max, 18 CPU cores, and 36 GB unified memory.
- Approximately 1.7 TiB disk space is currently free.
- The existing project environment is Python 3.13.14 with PyTorch 2.13.0.
- PyTorch reports that MPS support is built, but `torch.backends.mps.is_available()` returned
  `False` inside the current Codex sandbox. The hardware and OS should support MPS, so repeat the
  check in a normal Terminal before diagnosing the Python installation.

Use a separate `.venv-policy` rather than adding RL dependencies to the vision environment. Python
3.12 is the conservative compatibility choice for training libraries.

```bash
cd "/Users/vumonks/Desktop/mjss"
python3.12 -m venv .venv-policy
source .venv-policy/bin/activate
python -m pip install --upgrade pip
python -m pip install torch
python -c "import torch; print(torch.__version__); print(torch.backends.mps.is_built()); print(torch.backends.mps.is_available())"
```

If the final value is still `False` in regular Terminal, confirm that `arch` prints `arm64`, create a
fresh Python 3.12 environment, and install the official native PyTorch wheel there. Do not enable CPU
fallback merely to make the availability check appear successful.

The dependency set to pin during implementation is small: PyTorch, NumPy, Gymnasium, PettingZoo,
PyYAML, pytest, Hypothesis, and TensorBoard. Add libraries only when a measured need appears.

[PyTorch's MPS documentation](https://docs.pytorch.org/docs/stable/notes/mps) uses the standard
`torch.device("mps")` path. The training CLI should select `cuda`, then `mps`, then `cpu`, unless the
user explicitly supplies a device.

Practical MPS rules:

- run CPU simulator workers and batch policy/learner tensors before sending them to MPS;
- benchmark actor inference on CPU versus MPS—tiny one-state GPU calls can lose to transfer overhead;
- start in float32; add mixed precision only after numerical/parity tests;
- do not make `PYTORCH_ENABLE_MPS_FALLBACK=1` the default, because silent CPU fallback can hide a
  severe performance problem;
- avoid `torch.compile` in the first correctness milestone;
- checkpoint frequently and keep the vision training job stopped while running long policy jobs,
  because both compete for unified memory and compute.

Suggested local budgets after the simulator gates pass:

- 100,000 decisions: end-to-end PPO smoke test;
- 1–5 million: confirm learning beats RandomLegalAgent;
- 5–20 million: tune curriculum and beat the heuristic mix;
- move to cloud only when profiling shows that more rollout/training throughput is the next blocker.

The actual wall time depends more on simulator decisions/second and batching than on the small
network. Record both before estimating a full run.

## Cloud training path (`device=cuda`)

Use exactly the same repository, configs, seeds, checkpoint format, and CLI. Only device, worker
count, precision, and batch size should change.

### Recommended first cloud machine

- one NVIDIA L4/A10/A5000-class GPU with 24 GB VRAM;
- at least 12–16 vCPUs and 48–64 GB RAM for simulator workers;
- 100+ GB persistent volume for the environment, replays, and checkpoints.

The CPU allocation matters: self-play often becomes rollout-bound before this small model saturates
an A100. Upgrade the GPU only when measured learner utilization and rollout queues justify it.

For a simple pay-as-you-go option, RunPod currently lists an L4 24 GB Pod with 12 vCPUs at about
$0.39/hour and an A100 80 GB at about $1.39–$1.49/hour, before storage. Prices are dated and should
be rechecked on the [official pricing page](https://www.runpod.io/pricing). AWS G6 and Google G2 are
more operationally structured alternatives using NVIDIA L4 GPUs.

Cloud workflow:

1. build a pinned CUDA container locally or from CI;
2. mount persistent storage; never keep the only checkpoint on the disposable boot disk;
3. run unit/golden tests and a 100,000-decision smoke job first;
4. resume the Mac checkpoint with `--device cuda` and a larger worker/batch config;
5. stream metrics and upload promoted checkpoints/replays;
6. set an automatic cost/time stop and shut down the instance when training ends.

Do not distribute across multiple GPUs in v1. First saturate one learner with CPU actors. Add remote
rollout workers or multiple learners only after profiling and deterministic single-node training.

## Coach and iOS integration

The policy artifact should accept fixed-shape tensors plus a legal mask and return policy logits,
value, and optional auxiliary predictions. Export only the inference actor, not the PPO critic or
optimizer.

[Core ML Tools](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch.html) can
convert PyTorch models directly, without an ONNX intermediate. Export to an ML Program package and
verify on a fixed corpus that:

- PyTorch CPU, PyTorch MPS, and Core ML produce close logits/value;
- the top legal action and top-3 ranking agree within the declared tolerance;
- masked actions are never recommended;
- latency and memory are acceptable on the minimum supported iPhone.

The Coach should display:

- top 3 legal actions;
- policy probability or relative preference, not a fake “win probability” label;
- deterministic live outs, faan routes, and danger evidence beside the learned ranking;
- a low-confidence/insufficient-table-state warning when inputs are missing.

### Robustness to camera/tracker errors

Only after measuring detector and tracker errors, fine-tune/evaluate with a matching noise model:

- tile count deletion/insertion and face-confusion probabilities;
- missing opponent ownership/order;
- stale last-discard context;
- uncertain meld type;
- incomplete flower/wind metadata.

Train with missingness masks and modest noise, then test clean and noisy state separately. The
network must not silently convert a physically impossible scan into a confident action; the state
builder should reject or ask to correct impossible tile counts first.

## Phased implementation plan

| Phase | Work | Deliverable / exit gate | Rough effort for one engineer |
|---|---|---|---|
| 0. Rules contract | Approve profile, payments, special hands, golden cases | `hk_3faan_v1` plus reviewed fixtures | 3–7 days |
| 1. Scorer | Win decomposition, faan, stacking, settlement | Golden and property tests green | 1–2 weeks |
| 2. Learning environment | HLE-style Game/State/Observation/Action contract, reaction windows, two chance modes, replay, masks, adapters | 1M random actions + deterministic replay + no reaction leakage | 2–3 weeks |
| 3. Baselines | Random, deficiency, ukeire, k-step, score-aware, safety, tournament | Paper cases reproduced; skill ordering statistically visible | 1–2 weeks |
| 4. Discard model | Encoder, teacher data, BC, Core ML smoke export | Beats random; usable Coach top-3 | 1–2 weeks |
| 5. Full PPO | Calls/Kongs, curriculum, local MPS self-play | Beats fixed heuristic mix locally | 2–4 weeks |
| 6. League/cloud | Snapshots, promotion tests, CUDA scaling | Stable champion with reproducible report | 2–6 weeks |
| 7. Product hardening | Tracker schema, observation noise, iOS QA | Real-table pilot with corrections/logging | 2–4 weeks |

These ranges overlap and depend heavily on rule review and simulator correctness. A credible first
discard model is much closer than a strong full-game agent; the latter is an 8–16 week project, not
a one-command training run.

## Risks and explicit mitigations

| Risk | Mitigation |
|---|---|
| Wrong or ambiguous HK rules | Versioned profile, HKMA reference, human-reviewed golden corpus |
| Sparse reward | Teacher cloning, late-state curriculum, value/auxiliary heads |
| Self-play cycles or collapse | Frozen league, heuristic anchors, fixed promotion tournament |
| Hidden-information leakage | Player-relative observation tests and actor/critic separation |
| Reaction-order information leakage | Freeze reaction observations; hide pending claims until resolution; permutation tests |
| Simulator too slow | Profile first; optimize batching; port only hot paths to Rust/C++ later |
| Policy learns faan but loses points | Terminal net settlement is the production reward |
| Camera-to-simulator mismatch | Canonical schema, missingness masks, measured-noise fine-tuning |
| Local MPS slower than expected | Batch operations, benchmark CPU inference, switch unchanged job to CUDA |
| Rule/model incompatibility in app | Embed rules, action, and observation schema hashes in artifact |
| Unexplainable Coach output | Always pair policy rank with deterministic live-out/faan/danger analysis |

## What to do first

1. **Approve the rules checklist**, especially the faan cap/payment table, special hands, pattern
   stacking, multiple winners, and flower rules.
2. **Collect/review golden scoring hands**. This is more valuable right now than collecting photos or
   renting a GPU.
3. **Create the isolated policy environment** and run the MPS availability check in regular Terminal.
4. **Implement only Phases 0–2 first** using the Game/State/Observation contract, then publish
   correctness, reaction-leakage, and throughput numbers.
5. **Implement the paper's deficiency and k-step teacher**, reproduce its simplified examples, then
   extend it to 34 tiles, exposed melds, and the 3-faan scorer.
6. **Connect the existing EfficiencyEngine and prove the evaluation ladder** Random < Deficiency /
   Ukeire < K-step / ScoreAware.
7. **Train the discard-only behavior-cloned model on the Mac** and export a Core ML smoke model.
8. **Add masked PPO locally**. Move the identical job to one cloud L4 only after local profiling says
   throughput—not correctness or reward design—is the blocker.

The immediate input needed from the product owner is a confirmed rules profile and 20–30 seed hands
that can be expanded into the full golden corpus. No cloud account or large human-play dataset is
needed to begin.

## Research basis

- [Hong Kong Mahjong Association rules](https://www.hkmahjong.org/rules?lang=en) — primary rules
  reference to turn into the versioned product profile.
- [Suphx: Mastering Mahjong with Deep Reinforcement Learning](https://arxiv.org/abs/2003.13590) —
  34-column features, supervised warm start, policy-gradient self-play, entropy control, oracle
  guidance, and the importance of defense in imperfect-information Mahjong.
- [RLCard Mahjong documentation](https://rlcard.org/games.html#mahjong) — useful API reference but
  explicitly simplified scoring and payoff, so not a valid HK simulator.
- [`lucylow/Deep-Learning-Mahjong---`](https://github.com/lucylow/Deep-Learning-Mahjong---) — useful
  HK concept checklist, but its current repository does not contain a simulator or trainable model.
- [*Let's Play Mahjong!*](https://arxiv.org/abs/1903.03294) — deficiency, remaining-tile knowledge
  base, and recursive finite-horizon discard values; used as a teacher after HK extensions.
- [Hanabi Learning Environment](https://github.com/google-deepmind/hanabi-learning-environment) —
  architectural model for Game/State/Observation/Move/chance/encoder separation; adopt the pattern,
  not the archived Hanabi implementation.
- [OpenSpiel concepts](https://github.com/google-deepmind/open_spiel/blob/master/docs/concepts.md) —
  maintained extensive-form Game/State and explicit chance-node semantics; optional adapter target.
- [PettingZoo AEC and action masks](https://pettingzoo.farama.org/api/aec/) — standard adapter for
  turn-based multi-agent environments.
- [Proximal Policy Optimization](https://arxiv.org/abs/1707.06347) — initial on-policy learner.
- [Invalid action masking](https://arxiv.org/abs/2006.14171) — theoretical and empirical support for
  masking state-dependent illegal actions.
- [PyTorch MPS backend](https://docs.pytorch.org/docs/stable/notes/mps) — local Apple GPU path.
- [MJX](https://pypi.org/project/mjx/) and
  [Mahjax](https://arxiv.org/abs/2605.20577) — high-throughput simulator references, but Riichi-only;
  MJX's published package page also says Apple Silicon is unsupported.
- [Core ML Tools PyTorch conversion](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch.html)
  — iOS/macOS deployment path.
