# Building an iOS Mahjong-Assistant App for Toronto: Variant Strategy, Scoring, Competitors, and On-Device Tile Recognition Feasibility

## TL;DR
- **Build the MVP around Hong Kong (Cantonese) style mahjong.** It is the default variant of Toronto's large Cantonese/Hong Kong-origin diaspora and the dominant style at the city's biggest social clubs (Four Winds Toronto, Toronto Mahjong Social Club at Hong Shing, 17 Tiles cafe). Support Japanese Riichi as a fast-follow second variant because Toronto has an unusually organized, app-hungry Riichi community (Toronto Riichi Club).
- **The single most valuable, defensible MVP feature is a Hong Kong faan scoring calculator** with manual tile entry — scoring confuses beginners, no strong English-language HK scorer dominates, and it avoids the reliability trap of camera recognition. Camera tile recognition is technically feasible on-device (Core ML/Vision + a YOLO model) but should be a phase-2 "assist" feature, not the MVP's core promise, because real-world accuracy degrades badly with lighting, angle, and reflective tiles.
- **The efficiency/discard-trainer category is mature only for Riichi; it is essentially empty for Hong Kong style.** The underlying math (shanten + ukeire) transfers directly and an open-source library already supports a Hong Kong ruleset, so an HK discard trainer is a real, buildable market gap.

## Key Findings

1. **Hong Kong style dominates Toronto casual/club play.** Toronto's Chinese community is the second-largest in North America — 679,730 in the CMA, 11.1% of the metro population of 6,202,225 (2021 Census), "second only to New York City for largest Chinese community in North America." It is historically Cantonese/Hong Kong-rooted, and the largest social clubs explicitly play Hong Kong Old Style.
2. **Riichi is the strongest secondary variant in Toronto by organization,** with a dedicated club (Toronto Riichi Club / TORI) running online and in-person meetups and an annual tournament. American (NMJL) has only a small, lesson-based presence, and MCR (Chinese Official) is competition-focused (the World Championship was held in Mississauga in October 2024).
3. **Hong Kong scoring uses "faan" (番)** with a typical 3-faan minimum to win, an exponential faan→points conversion, and a hard limit (commonly 10 or 13 faan). Wind mechanics (seat wind vs prevailing/round wind) are a well-defined but beginner-confusing scoring element.
4. **The competitor field is crowded with scoring calculators and camera scorers, but they are Riichi- or generic-first, often poorly localized, and camera recognition is consistently the weak point.** No app convincingly owns "the Hong Kong mahjong assistant for English-speaking local players."
5. **On-device tile recognition is feasible but hard.** Published mahjong recognition projects report 90–99%+ accuracy in controlled conditions, but accuracy collapses on real-world varied images. Modern YOLO models run in real time on the iPhone Neural Engine (single-digit-MB models, tens of milliseconds per frame), so accuracy/robustness — not speed — is the risk.

## Details

### 1. Mahjong variant popularity in Toronto / the GTA

**Demographic backdrop.** The Greater Toronto CMA is home to 679,730 people of Chinese origin (11.1% of the CMA's ~6.2M), the second-largest Chinese community in North America after New York (2021 Census). The community was built largely on two 20th-century waves of Hong Kong immigration (heaviest 1987–1997, bracketing the 1997 handover), which made Metropolitan Cantonese the historically dominant Chinese language locally; per Statistics Canada's 2021 Census, Hong Kong-born Chinese remain concentrated in Toronto (46.2% of Canada's Hong Kong-born Chinese live in Toronto). Mandarin has since become the largest home language among Chinese Torontonians as mainland immigration grew. Markham (47.9% Chinese) and Richmond Hill (31.9% Chinese) are major suburban centres. Taiwanese are a minor source (~10% of foreign-born Chinese nationally). Japanese Torontonians are a much smaller group.

The key inference for variant choice: the *casual/family/club* culture skews Cantonese/Hong Kong, so Hong Kong style is the lingua franca of in-person social play. Mainland players are also generally familiar with Hong Kong style (it is widely played across southern China and the diaspora).

**Club and venue evidence (all Hong Kong-style-first):**
- **Four Winds: Toronto Chapter** launched in 2024 as a sister club to London's Four Winds and describes itself as "Toronto's largest mahjong social club." It "primarily play[s] Hong Kong–style mahjong" (the parent club plays Hong Kong Old Style), while welcoming all regional variations. It has a large young-adult, diaspora-centered following (thousands of Instagram followers).
- **Toronto Mahjong Social Club** runs a weekly casual social at Hong Shing restaurant (195 Dundas St W) with $10 drop-in and on-site coaches — a Cantonese-restaurant, Hong Kong-style context.
- **17 Tiles (十七雀)** is a board-game-and-mahjong cafe (556 Yonge St) where "serious Mahjong players pack the VIP rooms"; it is a Cantonese-named, Hong Kong-diaspora-oriented venue.
- **Mahjong Bar** (Dundas West) is a Hong Kong-themed cocktail bar — a cultural signal of the Hong Kong aesthetic's local resonance, though not a play venue.

**Secondary variant — Riichi (Japanese):** The **Toronto Riichi Club (TORI)** is well-organized: regular online meetups (Tenhou lobby 1416, 2nd/4th Tuesdays), monthly in-person meetups across Toronto/Peel/York (e.g., For The Win Board Game Cafe, Banana Games, 17 Tiles autotables downtown), a Discord, and the annual **Toronto Riichi Open** (4th edition; 2025 held at Toronto Metropolitan University). Riichi players are disproportionately young, online, strategy-focused, and comfortable using apps/tools — a highly monetizable niche despite smaller absolute numbers than Hong Kong casual players. Ottawa has a parallel Capital Riichi Club (200+ members).

**American (NMJL):** Present but niche and demographically distinct (older, often non-Chinese, lesson-driven). Providers like "Snack Crack Bam" offer NMJL lessons in midtown Toronto with the official annual card; there are scattered seniors'/suburban games. NMJL requires the annually-changing paid card and jokers, making it structurally different and a poor MVP target.

**MCR / Chinese Official:** Primarily a competitive/tournament format. The 7th World Mahjong Championship was held at the Mississauga Convention Centre, Oct 11–15, 2024, hosted by the World Mahjong Organization and organized by the Canada MCR Sports Association; per China Daily it drew 160 competitors from 17 countries and regions, with Team Canada's Gao Erfei winning first and Lin Hai finishing third (China withdrew over visa issues). Organized MCR play exists but is not the casual default.

**Broader tailwind:** Mahjong is in a documented youth-driven boom in the West (new social clubs in LA, NYC, Toronto). Yelp's 2026 Trend Forecast found that for Sept 2024–Aug 2025 vs. the prior year, searches for mahjong clubs rose 4,467% and mahjong lessons rose 819%. This favors a modern, English-friendly, learning-oriented app.

**Recommendation:** Build the MVP around **Hong Kong (Cantonese) style**. Rationale: largest addressable local player base, the default of the biggest social clubs, the style most families/newcomers already know, and the least well-served by good English-language tools. Architect the rules/scoring engine to be **variant-pluggable** so **Riichi** can be added quickly as variant #2 (organized, tool-hungry local community), with Taiwanese 16-tile and MCR as later options.

### 2. Hong Kong scoring system detail (for the calculator feature)

**Structure.** A winning hand is 4 melds + 1 pair (or a defined special hand). Scoring happens in two stages: (1) the hand earns **faan** (番) from matching scoring criteria; (2) faan convert to **points** (money/chips) via an exponential table.

**Minimum faan.** Most HK tables require **3 faan minimum** to declare a win; casual/family games may drop to 1–2, competitive circles may use 4–5. A complete hand with 0 faan is a "chicken hand" and cannot win under a 3-faan minimum. Special hands (e.g., Thirteen Orphans, Heavenly Hand) typically bypass the minimum. The absolute faan ceiling is **13 faan**, though tables often cap the payout at a lower "limit" (e.g., 8 or 10).

**Faan→points conversion.** Points scale exponentially. In "full spicy," points = 2^(faan). In "half spicy," it starts the same but from 4 faan onward doubles every *two* faan (an odd faan above 4 is 1.5× the previous). Modifiers: win-by-discard → discarder pays double / pays for all in high-risk cases; self-draw (zimo) → all three losers pay; dealer (East) pays/collects double.

**Common hands and representative faan values** (values vary by house table; a typical table):

| Hand | Cantonese | Faan |
|---|---|---|
| All Chows / Common Hand | 平糊 ping wu | 1 |
| Pung of dragons (each) | — | 1 |
| Pung of seat wind | 門風 | 1 |
| Pung of prevailing/round wind | 圈風 | 1 |
| All Pungs / All Triplets | 對對糊 | 3 |
| Mixed One Suit / Half Flush | 混一色 | 3 |
| Seven Pairs | 七對子 | 4 |
| Small Dragons | 小三元 | 5 |
| Small Winds | 小四喜 | 6 |
| All One Suit / Full Flush | 清一色 | 7 |
| Great Dragons (Three Great Scholars) | 大三元 | 8 |
| All Honor Tiles | 字一色 | 10 |
| Self Triplets (four concealed pungs) | 四暗刻 | 10 |
| Nine Gates | 九子連環 | 10 |
| Great Winds (Big Four Winds) | 大四喜 | 13 (limit) |
| Thirteen Orphans | 十三么 | 13 (limit) |
| All Kongs | 四槓子 | 13 (limit) |
| Heavenly Hand / Earthly Hand | 天糊/地糊 | 13 (limit) |

Winning-condition faan: self-pick (自摸) +1; fully concealed win (門前清) +1; robbing a kong +1; win by last tile/last discard +1; win on kong replacement (槓上開花) +2. Bonus (flower/season) faan: no flowers +1; flower/season matching your seat wind +1 each; a full set of flowers or seasons +2. Faan from most criteria are additive up to the limit; when one criterion is a subset of another, only the higher scores.

**Winds and directions — the confusing part.** There are two wind dimensions:
- **Seat wind (門風):** your position at the table — East, South, West, North. East is always the dealer.
- **Prevailing/round wind (圈風):** the wind of the current round (the game starts in East round; after a full rotation it becomes South round, etc.).

A pung/kong of your **seat wind** = 1 faan; a pung/kong of the **prevailing wind** = 1 faan. If a wind is *both* your seat wind and the prevailing wind (a "double wind"), it counts **2 faan**. Seat winds rotate counter-clockwise as the deal passes (unless the dealer wins or the hand is a draw, in which case the dealer keeps East). This dual-wind system, combined with flower/season tiles that only score for the *matching* seat wind, is a leading source of beginner scoring errors — and a prime place for a calculator to add value by asking only "what's your seat?" and "what round is it?" and computing the wind faan automatically.

**Why scoring confuses beginners:** (a) faan tables differ between house rules (e.g., All Pungs and Half Flush are 2 *or* 3 faan depending on the group — a real bug source noted in existing apps); (b) subset/stacking rules (which yaku can combine); (c) the exponential and "spicy" conversion tables; (d) the two-wind mechanic and matching flowers; (e) limit-hand overrides; (f) payment asymmetries (discard vs self-draw, dealer double). A good calculator lets users configure the house table (minimum faan, spicy mode, limit, All-Pungs/Half-Flush values) — configurability is essentially mandatory for HK.

### 3. Competitor landscape (iOS focus)

**Camera-based scorers / tile recognition:**
- **Mahjong Camera** (Wing Hin Liu) — scans a winning hand to compute Han/Fu/Faan/Tai; supports Riichi, Hong Kong, Taiwanese, and HK-style Taiwanese; includes a waits calculator. The most directly comparable multi-variant camera scorer, and notably it already covers HK.
- **Camera de Pon** (Riichi) — camera scorer; reviews praise the concept but report frequent tile misrecognition ("sees kanji 1,2,3 as 1,1,1"), requiring manual correction — illustrating the reliability trap.
- **Mahjong Camera (Japan, 2018)** — early Riichi camera scorer; reviewers found recognition slow/finicky.
- **MajHint** — "AI Mahjong Assistant": camera tile scanning, shanten calc, discard suggestions, tenpai quiz (Riichi-oriented).
- **Mahjong AI – Mahjong Assistant** — photo tile recognition done **locally on-device**, ready-hand analysis, encyclopedia; rule adapters for Guobiao, Changsha, Riichi, Sichuan (5 free scans/day, Pro subscription).
- **Mahjong AI Analyze Calculator** — camera recognition + discard analysis + scoring for Chinese standard and Riichi.
- **Mahjong Scorer** (Mikael de Verdier) — photo-to-score via a trained model.

**Scoring calculators (manual entry):**
- **Mahjong Helper & Calculator** (Michael Starling) — the standout multi-variant manual scorer: European Classical, Hong Kong, Riichi/EMA, and MCR; 2/3/4-player; score-sheet and payment tracking; a "Scoring" explainer panel. Notably its HK table had faan errors flagged by users (All Pungs should be 3 faan), later addressed with a toggle — evidence that HK's house-rule variability is a persistent pain point.
- Web tools: Mahjong Point Calculator (olafneumann), Mahjong Time reference tables.

**Efficiency / discard trainers (the mature category — all Riichi):**
- **Tenhou's calculator** (tenhou.net/2) — the reference shanten/ukeire tool.
- **Mahjong Efficiency Trainer** (Euophrys, itch.io) + its open-source **Riichi-Trainer** (GitHub) — for every possible discard, computes resulting shanten and ukeire.
- **riichi-tools-rs** (Rust/WASM), **kobalab** nanikiru tools, **gameraccoon's** trainer bot, **mjlab.app** — a rich Riichi tooling ecosystem.
- Critically, **garyleung142857/mahjong-tile-efficiency** (npm) already computes shanten + ukeire for **multiple rulesets including "HK" (Hong Kong Old Style)**, Taiwan, MCR, ZungJung, and Riichi — a ready-made engine for an HK discard trainer, and its web front end (cal-shanten-beta) demonstrates HK support.

**Play-a-game apps (not assistants, but context):** Hong Kong Mahjong Club (authentic HK rules vs AI, Cantonese voice), Hong Kong Style Mahjong (Paul Vella), and mahjonggame.hk (a web/app HK product already advertising AI coaching, a training mode with per-tile keep/discard hints, and ML bots — the closest thing to a direct HK-assistant competitor, though it is a play-against-bots product rather than a real-table assistant).

**Market gaps (where to win):**
1. **A polished, English-first Hong Kong scoring calculator** with configurable house rules and clear teaching of *why* a hand scores what it does. Existing HK support is buried inside multi-variant tools with known HK faan bugs.
2. **A Hong Kong efficiency/discard trainer** — this category is essentially non-existent for HK despite a ready open-source shanten/ukeire engine.
3. **A real-table "assist" mode** (point your phone at your own 13–14 tiles to auto-score or get discard advice) that is honest about its accuracy limits and offers instant manual correction — camera scorers today are Riichi-first and fragile.
4. **Localization + culture fit for Toronto**: bilingual (English/Cantonese) tile and yaku names, HK house-rule presets, and tie-ins to local clubs.

### 4. On-device tile recognition feasibility on iOS

**Frameworks.** The standard, well-trodden path: train a custom object detector (YOLO family, or via **Create ML**'s object-detection template), export to **Core ML** (.mlpackage / .mlmodel), and run it through the **Vision** framework (VNCoreMLRequest) against live `AVCaptureSession` frames or still photos. Vision handles image scaling/orientation; Core ML schedules across CPU/GPU/Neural Engine. ARKit is not needed for MVP (no spatial anchoring required to read tiles). This is a mature, documented pipeline (Apple WWDC "Training Object Detection Models in Create ML"; numerous Core ML + YOLO iOS tutorials).

**How hard is it to recognize ~34–42 tile faces?** Two sub-problems: **detection** (find each tile's bounding box) and **classification** (label it). Reported results:
- A peer-reviewed CNN system (Wu, Han, Liu & Lyu, 2021, ACM CSAE '21) "recognize[d] a total of 27 different mahjong faces in uncontrolled conditions... an accuracy of 99.71% with a running time of 29ms" — the strongest published physical-tile figure.
- A YOLOv5 academic paper (Zhang et al., 2024, *Applied and Computational Engineering* vol. 48) reported **YOLOv5m precision ~98% / recall ~97%** on a 34-class Chinese set (YOLOv5s precision 99.11% / recall 80.16%), but noted **angle and placement direction are the main factors** hurting accuracy, and recall dropped to ~80% under severe occlusion.
- A Cornell ECE5725 student project got **YOLOv9 "nearly 100%"** on their own split from only **~150 hand-labeled images** augmented to ~1,000 — but a **pre-trained Roboflow model only reached ~70%**, and they flagged heavy lighting sensitivity and 6–8s latency on Raspberry Pi.
- A cautionary case: Jessica Lee & Helen Lin's U-Net + classifier project had good segmentation (mean IoU ~0.67) but "very few of the tiles were correctly identified" on the real test set (~0.028 classification accuracy), with a detection discrepancy of "detecting 15 boxes where there were 71 true labels in one case" — the gap between lab and real-world performance.

**Known challenges:** (a) **Visual similarity** — bamboo and circle tiles differ only by *count* of sticks/circles, so adjacent counts (e.g., 6 vs 9, 7 vs 8) are inherently confusable; the 1-Bamboo is a bird, not a stick, breaking count logic; character (wan) numerals are small kanji. (b) **Angle/orientation** — the dominant real-world error factor. (c) **Lighting and reflective tile surfaces** (glossy acrylic/resin tiles cause glare). (d) **Occlusion** — tiles held in a hand or overlapping in melds. (e) **Domain shift** — models trained on one tile-art style degrade on differently-designed sets (a major issue given how varied physical sets are). Note: no published CV paper isolates a per-tile confusion matrix (e.g., exact 6-vs-9 error rates) for mahjong; the confusability is inferred from tile design plus the general "visual similarity" findings.

**Datasets.** Multiple open Roboflow datasets exist: e.g., **Mahjong_YOLO (~4,483 images)**, **YOLO_Mahjong (~1,672 images)**, a **34-class Riichi (m/p/s/z)** set (~6.8k images, mahjong-x5dzz), a peer/vendor model at mAP@50 ~99% (mahjong-vtacs, ~4.4–8k images), and a **42-class Chinese/HK set with dragons, winds, flowers, and seasons** (Jon Chan, mahjong-baq4s). Note the naming split: **Riichi datasets use 34 tiles (m/p/s + z honors), sometimes 37 with red fives**, while **Chinese/HK datasets use ~42 classes including three dragons, four winds, and flowers/seasons** — so for an HK app you want the Chinese/HK-labeled datasets, likely supplemented with your own captures of local tile designs. Expect to collect and label your own images regardless: transfer from public sets to real club tiles is where accuracy is lost.

**On-device performance is not the bottleneck.** Quantized modern YOLO models are small and fast on Apple silicon: YOLO11n disk footprint ~2–6 MB; INT8 quantization ~¼ of FP32 size with negligible accuracy loss. YOLO models exported to Core ML run **60+ fps** on the Neural Engine (one Roboflow case study: 21→85 fps after Core ML export); Ultralytics reports YOLO26n at 3.8 ms single-image and ~16 ms/frame (~60 fps) sustained on an iPhone 17 Pro. So a real-time camera experience is achievable; **accuracy and robustness, not speed, are the risk.**

**Realistic MVP approach for recognition:**
- **Phase 1 (MVP): no camera as the core.** Ship fast, reliable **manual tile entry** (tap tiles from a palette) for the scoring calculator and (later) discard trainer. This sidesteps recognition risk entirely and is what most successful scorers rely on.
- **Phase 2: constrained single-scene capture.** Add "photograph your completed 14-tile hand laid flat" for auto-scoring, trained/fine-tuned on your own captures of common local tile sets, **with mandatory one-tap correction** and a confidence display. Constrain the problem (tiles face-up, flat, good light) rather than attempting full-table scene understanding.
- **Phase 3 (ambitious): live table understanding** (your hand + discards). Much harder (occlusion, angles, multiple orientations) and should only follow strong phase-2 metrics.

### 5. Mahjong efficiency / optimal discard theory

**Shanten (向聴)** = the minimum number of tile swaps to reach **tenpai** (ready — one tile from winning). A hand one tile from tenpai is 1-shanten. A standard formula: shanten = (8 − 2×melds − partial-sets/pairs), with the constraint that only 4 blocks count and a pair gives a further −1. Lower is better.

**Ukeire (受け入れ) / tile acceptance** = the count of distinct tiles (and copies) that, if drawn, would *reduce* shanten (advance the hand). Example: a 13-tile hand that reaches tenpai on 3 tile types with 3+4+4+4 = 15 available copies has ukeire 15. Effective ukeire drops as copies are visible in discards/melds/dora.

**How efficiency calculators work:** for a 14-tile hand (post-draw), the tool enumerates every possible **discard**, computes the resulting hand's shanten, and for each computes ukeire (how many tiles advance it). It ranks discards by ukeire (and often by "improvement" and next-shanten acceptance). Tenhou's calculator is the canonical implementation; Euophrys's trainer gamifies it.

**Known limitations (important for a trustworthy product):** pure ukeire ignores (a) **hand value** (a high-ukeire discard may kill a big hand); (b) **already-discarded tiles** (theoretical vs effective ukeire); (c) **future shape quality** (a ryanmen two-sided wait is better than an equal-ukeire kanchan/penchan); (d) **defense/safety**. Any HK trainer should surface these caveats.

**Does it transfer to Hong Kong style? Yes, the core math does.** Shanten and ukeire are properties of tile shapes and the "4 melds + pair" structure, which HK shares. In fact the open-source **mahjong-tile-efficiency** library already implements shanten + ukeire for a **Hong Kong Old Style** ruleset (plus Taiwan, MCR, ZungJung, Riichi). Two adaptation notes: (1) HK's win condition requires **≥3 faan**, not just a complete shape, so a truly optimal HK trainer should weight efficiency against reaching the faan minimum (e.g., toward flushes, all-pungs, or dragon/wind pungs) — pure speed can produce a valueless chicken hand. (2) HK play culture **opens hands (calls pungs/chows) far more readily** than Riichi (no concealment premium for most hands), so an HK trainer should model calling/melding, not just concealed draws. This value-vs-speed tension is exactly where an HK-specific trainer could differentiate from a naive Riichi-style port.

## Recommendations

**Stage 1 — MVP (build first):** A **Hong Kong faan scoring calculator** with:
- Manual tile entry (tile palette), 4-melds-+-pair and special-hand recognition.
- **Configurable house rules**: minimum faan (1/2/3/4/5), faan values for the ambiguous hands (All Pungs, Half Flush = 2 or 3), spicy/half-spicy conversion, and limit cap (8/10/13).
- **Automatic wind faan**: ask seat + round, compute seat/prevailing/double-wind faan and matching flower/season faan.
- **Payment computation**: discard vs self-draw, dealer double, "pay for all."
- A "why this score" explainer (teaching mode) and bilingual (English/Cantonese) tile + yaku names.
- Benchmark to change course: if user testing shows the calculator alone doesn't retain users, prioritize the trainer over the camera.

**Stage 2 — Differentiator:** A **Hong Kong discard/efficiency trainer** built on the existing open-source shanten/ukeire engine, adapted for the **3-faan minimum** (value-aware suggestions) and **open-hand/calling** culture. This fills a genuine market gap (no real HK trainer exists) and has low technical risk.

**Stage 3 — Camera "assist" (only after Stages 1–2 prove retention):** Constrained single-photo capture of a flat, face-up completed hand → auto-fill the calculator, trained/fine-tuned on your own images of tile sets common in Toronto clubs, with a confidence indicator and one-tap manual correction. Treat recognition as a convenience layer over the reliable manual core, never the sole path.

**Stage 4 — Second variant:** Add **Riichi** (scoring + the mature efficiency concepts) to capture the organized, tool-hungry Toronto Riichi Club audience; then consider Taiwanese 16-tile and MCR.

**Go-to-market:** Partner with **Four Winds Toronto**, the **Toronto Mahjong Social Club (Hong Shing)**, **17 Tiles**, and **TORI** for beta testers and credibility; ride the current youth mahjong boom with an English-first, teaching-oriented positioning.

**Thresholds that change the plan:** If beta data shows most target users actually play Riichi (e.g., you recruit heavily via TORI), flip the build order to Riichi-first, where mature reference tooling both raises the bar and de-risks correctness. If phase-2 camera accuracy on real club tiles can't clear ~95% per-tile with fast correction, keep recognition permanently secondary to manual entry.

## Caveats
- **Faan tables are not standardized.** Values above are representative; real tables differ (this is itself the product opportunity, via configurability). Sources include Wikipedia's HK scoring article, the McGill Mahjong club's HK Old Style table, and several rules sites; where they conflict, treat house configurability as the answer rather than a single "correct" table.
- **Club "size" claims are self-reported.** "Toronto's largest mahjong social club" (Four Winds) and similar are the clubs' own descriptions, not audited figures; directionally they confirm Hong Kong-style dominance in social play.
- **Recognition accuracy figures are mostly in-domain/lab numbers** (student projects and vendor/Roboflow training metrics), not independent real-world benchmarks; the ~0.028 real-test collapse (Lee & Lin) shows how large the lab-to-field gap can be. Budget for substantial custom data collection.
- **iPhone inference-speed numbers come from vendor (Ultralytics/Roboflow) documentation** and are best-case single-image bursts; sustained camera throughput will be lower but still real-time.
- **Demographic figures rely on Statistics Canada 2021 Census and Wikipedia's census summaries**, which are authoritative; a Grokipedia source was used only to corroborate, not as a primary.
- **App-store competitor feature lists are marketing copy**; actual recognition reliability (per user reviews) is consistently weaker than advertised.