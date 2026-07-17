# Mahjong Sensei — Design Spec (SwiftUI Implementation Contract)

> Extracted verbatim from the Claude Design walkthrough artifacts:
> - `Ref/design/Walkthrough.html` (canvas doc, "User Walkthrough & Experience", jade + gold direction)
> - `Ref/design/MahjongTile.html` (parametric tile component)
> - `Ref/design/IOSTabBar.html` (bottom tab bar)
>
> This file is the implementation contract. Values are transcribed from the source; do not summarize away numbers. Treat all in-app copy (including Chinese) as design content.

---

## 0. Units, scale, and reading this document

**Two coordinate systems appear in the source; keep them separate.**

1. **App/device UI** lives inside `.screen` elements. Each mockup phone is drawn at a reduced scale: the `.phone` is `244×528px` with `8px` padding, so the interior **screen canvas is 228×512 px**. The header states the real target is **iPhone 16 · 393pt** (iPhone 15/16 = 393×852 pt). So **mockup px × ~1.724 ≈ device points** (393 / 228 = 1.724). Screen-chrome numbers below are given as the raw mockup px from the source; **treat the proportions as the contract** and rebuild against the real 393×852 pt canvas.
2. **Doc chrome** (lanes, badges, chips, captions, arrows, persona card) is the handoff board's presentation — **not app UI**. It is documented in §1/§4 because the caption text carries design intent, but it must not be built into the app. It is explicitly flagged as "doc-only" where listed.

**Tile geometry is scale-independent** — the `MahjongTile` component expresses every dimension as a ratio of tile width `w`. That ratio spec (§3.2) is the real contract and needs no conversion.

**Frames:** every screen uses a Dynamic Island phone, `9:41` status time, and a home indicator. The design is **dark-mode only** ("Appearance: Jade · Dark" is the shipped setting).

---

## 1. Overview & User Flow

**Product framing (verbatim header):**
- Eyebrow: `MAHJONG SENSEI · 麻雀先生 — DEVELOPER HANDOFF`
- Title: `User Walkthrough & Experience`
- Intro: *"End-to-end flow in the Traditional-Modern **jade + gold** direction — Onboarding, the Scan→Score hero path with edge states, **Coach mode**, Live AR, Learn, and settings. Follow one player through a real evening of play."*

**Persona (doc-only card):** avatar glyph `梅`. `Mei · 27 — "New at the family table"`. *"Sunday mahjong with family, Hong Kong house rules. Can't read every tile or the winds yet. **Goal:** point the phone, find out if she won and by how much — without slowing the game."*

**Annotation legend (doc-only):** `● Rationale` · `⌖ Interaction` · `▢ State` · `◷ PRD metric`. Note: *"Gold arrows show the primary path. Tan-numbered screens are alternate / error branches. Frames are iPhone 16 · 393pt."*

The board is laid out as **5 numbered lanes** (read left→right within a lane, top→bottom between lanes). Numbered steps run **1–22**; edge states use `!` badges; the AR preview uses `A`/`B` badges. **Total distinct phone mockups = 28** (22 numbered + 4 edge + 2 AR). Footer: *"End of walkthrough — 22 steps across 5 flows."*

### Ordered narrative

**LANE 1 — First run · Onboarding** *(lane note: "Four skippable screens · no account · sets style + house rules before the camera ever opens.")*
1. **Welcome** — brand + promise, "Get started".
2. **Pick your style** — Hong Kong / Riichi / Taiwanese 16 (HK pre-selected).
3. **Set your table** — house-rules preset (Family default / Common club / Custom…).
4. **Camera primer** — privacy pre-permission priming, "Enable camera" / "Maybe later".

**LANE 2 — The hero path · Scan → Score** *(lane note: "Point → detect → correct → context → result → why. Target: scan to confirmed hand under 8 seconds.")*
5. **Aim at your hand** — live camera, alignment reticle, Score/Coach toggle, scanning card.
6. **Tiles detected** — bounding boxes + confidence, low-confidence tile flagged amber.
7. **Check & correct** — tap-to-correct grid + bottom-sheet tile picker.
8. **A few quick taps** — seat + round wind, self-draw/discard, dealer toggle (context).
9. **Result** — big faan number → points, meld strip, itemized breakdown, actions.
10. **Why this score** — per-faan teaching cards.

*Edge & error states (branch off the scan path):*
- **Low light** (branches from 5) — "Too dark to read tiles", torch CTA.
- **Chicken hand** (branches from 9) — 0 faan below minimum, nudge to Coach.
- **Incomplete** (branches from 9) — "Not a winning shape yet", Edit/Coach.
- **Two readings** (branches from 9) — shows both decompositions, scores the max.

**LANE 3 — Coach · the Discard Trainer** *(lane note: "Same scan, a different destination. Ranked discards with shanten + ukeire, a value overlay so speed never makes a chicken hand, calling advice — then the same engine goes live on the open camera.")*
11. **Flip to Coach** — scan screen, toggle on Coach, "Coach this hand →".
12. **Ranked discards** — hand + shanten pill + 3 ranked discard rows (BEST/AVOID).
13. **Why — wait quality** — bottom sheet naming the wait ("Two-sided wait 兩面").
14. **Value overlay** — fast-vs-value: flags speed making a chicken hand.
15. **Calling advice** — "Call Pung?" open-hand reasoning.

*Live at the table (sub-flow, lane note: "the same engine, on the open camera during play · reads every face-up tile to call the most probable move"):*
16. **Real-time overlay** — LIVE badge, discards + hand read off a blurred table photo. *(Caption asserts "ARKit anchors the labels to the felt" — see §6 conflict.)*
17. **Tap for insight** — Coach popover with live out-counting.

*AR lens preview (sub-flow, lane note: "the finding moment, borrowed from iOS 26 Find My"):*
- **A — Finding (privacy blur)** — searching ritual, particle ring, "9 tiles".
- **B — Locked (lens focuses)** — bracket claims rack, re-rendered tiles, Coach card.

**LANE 4 — Learn · between the games** *(lane note: "The retention loop: an interactive wind explainer that kills the #1 confusion, a full tile dictionary, and tap-through detail.")*
18. **Wind Explainer** — interactive seat/round compass, double-wind highlight.
19. **Tile Dictionary** — searchable 42-tile grid, suit filters.
20. **Tile detail** — bottom sheet, EN + 繁中 + Jyutping + lore.

**LANE 5 — House Rules & Settings** *(lane note: "Where the configurability lives — every faan value editable, because HK tables never agree.")*
21. **House Rules** — preset tabs + editable faan-value rows.
22. **Settings** — language, appearance, house rules, camera, about/feedback.

Footer next-candidates (not designed yet): *"the drill-mode grading loop, a session score-sheet across a night of play, and the manual-entry fallback when camera is denied."*

---

## 2. Design Tokens

### 2.1 Colors

Base cream is `rgb(243,230,196)` = **`#F3E6C4`**; most secondary text is that cream at reduced alpha (`rgba(243,230,196, α)`). The signature accent is **gold `#E7C877`** with light-gold `#F0D89A`; the ground is **dark jade green**.

#### App palette — greens (ground & structure)
| Hex | Semantic name | Where used |
|---|---|---|
| `#15493C` → `#08211B` | Screen bg · welcome/primer | `radial-gradient(125% 95% at 50% 6%, …)` on Welcome, Camera primer |
| `#134438` → `#0A241D` | Screen bg · content (default) | `radial-gradient(125% 95% at 50% 4%, …)` on most non-camera screens |
| `#33463a` → `#1a2b20` → `#0c1611` | Screen bg · camera | `radial-gradient(130% 90% at 50% 30%, …)` on Aim, Detect, Coach entry |
| `#1a241f` → `#0a120e` | Screen bg · low-light | `radial-gradient(130% 90% at 50% 40%, …)` on Low-light state |
| `#0a120d` | Screen bg · live/AR | Solid under blurred table photo (16, 17, A, B) |
| `#1C6553` | Jade (primary green / brand) | Card gradients, links, selected fills, hero card |
| `#0E3A31` | Deep jade | Gradient dark stop (cards, laneNo, hero) |
| `#175247` | Jade card top | Selected list-row gradient start (Pick style, Context) |
| `#0C3128` | Jade hero deep | Result hero card gradient end |
| `#1F6F5C` | Jade accent | Tab-bar accent, toggle "on" fill |
| `#0C2C24` | Ink-on-gold (dark green) | Text/glyphs on gold buttons, badges, pills |

#### App palette — gold / cream (accent & ink)
| Hex / value | Semantic name | Where used |
|---|---|---|
| `#E7C877` | **Gold accent** | Badges, active toggle segment, faan values, borders, CTA gradient end, pills |
| `#F0D89A` | Light gold | Big faan number, primary highlights, CTA gradient start, "on device" emphasis |
| `#F5ECD4` | Cream · primary heading | Screen titles, primary labels |
| `#F3E6C4` | Cream · body (base) | Body text, tab ink, live-overlay text |
| `#F1E9D6` | Cream · status bar | Status-bar time/battery |
| `#EBD9A8` | Jade-tile numeral cream | Numerals inside jade-theme tiles |
| `rgba(243,230,196, .40–.75)` | Cream secondary ladder | Subtitles, notes, captions (α steps: .4/.45/.5/.55/.6/.62/.65/.68/.7/.72/.75) |

#### App palette — semantic states (warn / avoid)
| Hex / value | Semantic name | Where used |
|---|---|---|
| `#FF9F0A` | Amber · low-confidence | Flag border + "?" badge on mis-detected tiles |
| `#FFB84D` | Amber · warning heading | "1 to fix" pill, chicken 雞 glyph, value-overlay "!" |
| `#FFD08A` | Amber · low-light heading | "Too dark to read tiles" |
| `rgba(255,220,170,.8/.85)` | Amber · low-light body | Low-light body text |
| `#B4542A` | Rust · AVOID tag | Coach "AVOID" discard tag background |
| `rgba(120,70,20,.28/.5)` | Amber wash · warning bg | Low-light card, value-overlay "fast line" card |
| `rgba(255,159,10, .14–.5)` | Amber fills/borders | Warning card borders/fills, chicken circle |

#### App palette — overlays, glass surfaces, gold-alpha ladder
| Value | Semantic name | Where used |
|---|---|---|
| `rgba(255,255,255,.04)` | Card surface (default) | Standard list/card background |
| `rgba(255,255,255,.05)` / `.06` | Card surface (raised) | Unselected chips/cells, search field |
| `rgba(255,255,255,.14)` | Glass button | AR circular close/flip buttons |
| `rgba(0,0,0,.22)` | Meld group bg | Result meld chips |
| `rgba(12,44,36,.42)` | Toggle track glass | Score/Coach toggle background |
| `rgba(10,36,29,.5/.55/.7)` | Hint/pill glass | Scan hint pill, LIVE pill, discard labels |
| `rgba(15,52,43,.6/.66)` | Scan card glass | Bottom scan status card |
| `rgba(13,45,37,.85/.86/.92/.94)` | Bottom-sheet glass | Correction/why/detail sheets, popover |
| `rgba(231,200,119, .10–.45)` | **Gold-alpha ladder** | Borders, glows, fills (steps: .1/.12/.13/.14/.16/.18/.2/.22/.25/.28/.3/.35/.4/.42/.45) |
| Photo filter | Live/AR camera treatment | `blur(14px) brightness(.48) saturate(.85)`, `transform:scale(1.12)` |

#### Tab bar palette (`IOSTabBar.html`)
| Value | Role | Notes |
|---|---|---|
| `rgba(30,30,32,.68)` / `rgba(255,255,255,.7)` | Bar bg (dark / light) | App uses dark |
| `rgba(255,255,255,.16)` / `rgba(255,255,255,.85)` | Bar border (dark / light) | 1px |
| `rgba(255,255,255,.55)` / `rgba(0,0,0,.42)` | Idle tab color (dark / light) | |
| `#0A84FF` | Default accent (prop) | **Overridden to `#1F6F5C`** in app |
| `#F3E6C4` | Ink (active tab fg) | Passed via `ink="#F3E6C4"` |

#### Doc-chrome palette (NOT app UI — reference only)
`#ECE6D8` board bg · `#173A31`/`#153931`/`#123029` board text · `#1C6553`→`#0E3A31` links & laneNo · `#F5ECD4` laneNo text · `rgba(23,58,49,.1)` lane divider · `#E7C877`/`#0C2C24` numbered badge · `#B8916E`/`#231a10` alt badge · chips: `#7A5B12` on `rgba(231,200,119,.28)`, `#155a4b` on `rgba(31,111,92,.15)`, `#94451f` on `rgba(190,90,40,.14)`, `#3d3d3d` on `rgba(0,0,0,.07)` · `#C0A050` arrows · `#FBF8F0` legend card.

#### 5 Tile theme palettes (`MahjongTile.html renderVals()`)
Each theme defines: `a`/`b` (face gradient stops), `bd` (border), `sh` (drop shadow), `inner` (inset shadow), `font`, and mark colors `dot`/`dotRing`/`bam`/`num`/`sub`/`E`/`dR`/`dG`/`dW`.

**flat** *(clinical / system font)*
| key | value |
|---|---|
| a / b | `#FFFFFF` / `#FFFFFF` |
| bd | `#E5E5EA` |
| sh | `0 1px 2px rgba(0,0,0,.10)` |
| inner | `inset 0 0 0 0 rgba(0,0,0,0)` |
| font | `-apple-system,BlinkMacSystemFont,system-ui,sans-serif` |
| dot / dotRing | `#1C1C1E` / `#1C1C1E` |
| bam | `#1C1C1E` |
| num / sub | `#1C1C1E` / `#D33A2C` |
| E (wind) | `#1C1C1E` |
| dR / dG / dW | `#D33A2C` / `#1C1C1E` / `#2E6BD6` |

**classic** *(default — cream paper, serif)*
| key | value |
|---|---|
| a / b | `#FDFAF3` / `#F1E9D6` |
| bd | `#E7DDC6` |
| sh | `0 3px 6px rgba(60,42,15,.16)` |
| inner | `inset 0 1.5px 0 rgba(255,255,255,.85)` |
| font | `"Noto Serif TC",serif` |
| dot / dotRing | `#2E5AAC` / `#C9302C` |
| bam | `#1E7A44` |
| num / sub | `#1E7A44` / `#B23A2E` |
| E (wind) | `#26364F` |
| dR / dG / dW | `#B23A2E` / `#1E7A44` / `#2E5AAC` |

**ivory** *(warm aged bone — used for camera-detected tiles)*
| key | value |
|---|---|
| a / b | `#F8EFDB` / `#E7D2AC` |
| bd | `#D8C299` |
| sh | `0 5px 12px rgba(70,45,10,.24)` |
| inner | `inset 0 2px 3px rgba(255,255,255,.9), inset 0 -4px 7px rgba(120,80,20,.20)` |
| font | `"Noto Serif TC",serif` |
| dot / dotRing | `#2B57A6` / `#A8342A` |
| bam | `#1C7040` |
| num / sub | `#1C7040` / `#A8342A` |
| E (wind) | `#2A2016` |
| dR / dG / dW | `#A8342A` / `#1C7040` / `#2B57A6` |

**jade** *(dark green + gold — used for in-app rendered tiles)*
| key | value |
|---|---|
| a / b | `#1A5B4E` / `#0E3A31` |
| bd | `#08251F` |
| sh | `0 5px 14px rgba(0,0,0,.42)` |
| inner | `inset 0 1px 0 rgba(231,200,119,.4), inset 0 0 0 1.5px rgba(231,200,119,.30)` |
| font | `"Noto Serif TC",serif` |
| dot / dotRing | `#E7C877` / `#F0D89A` |
| bam | `#E7C877` |
| num / sub | `#EBD9A8` / `#E9C56F` |
| E (wind) | `#EBD9A8` |
| dR / dG / dW | `#E9B44C` / `#EBD9A8` / `#EBD9A8` |

**glass** *(frosted translucent — system font)*
| key | value |
|---|---|
| a / b | `rgba(255,255,255,.16)` / `rgba(255,255,255,.05)` |
| bd | `rgba(255,255,255,.55)` |
| sh | `0 8px 22px rgba(0,0,0,.28)` |
| inner | `inset 0 1px 0 rgba(255,255,255,.7)` |
| font | `-apple-system,BlinkMacSystemFont,system-ui,sans-serif` |
| all marks | `#FFFFFF` |
| special | `glass:true` → solid `a` bg (no gradient) + `backdrop-filter: blur(14px) saturate(1.5)` |

### 2.2 Typography

| Family | Fallback stack | Role |
|---|---|---|
| **Noto Serif TC** | `"Noto Serif TC", serif` | Display headings, all Chinese glyphs, big numerals (番/faan count), tile num & honor glyphs (classic/ivory/jade themes). Weights loaded: **400, 600, 700, 900** (800 used inline). |
| **system-ui** (SF Pro) | `-apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", sans-serif` | Body, UI labels, buttons, captions, status bar, most numerals/counts. Tile marks in flat/glass themes. |
| **Noto Sans TC** | loaded `400,500,700` | **Loaded in `<head>` but never referenced in any `font-family`** — system-ui stands in for Latin sans throughout. See §6. |

Representative sizes/weights (mockup px; ×~1.72 ≈ pt):

| Use | Font / weight / size | Extras |
|---|---|---|
| App name (Welcome) | Noto Serif TC 700 · 22px | color `#F0D89A` |
| App name subtitle `麻雀先生` | system 400 · 11px | `letter-spacing:.34em` |
| Screen titles ("Almost there", "Result", "Why 7 faan?", "House Rules", "Settings", "Dictionary") | Noto Serif TC 700 · 22/20/19/18px | |
| Big faan number | Noto Serif TC 700 · **46px/1** · `#F0D89A` | paired `番` 700·20px |
| Section eyebrow ("Your seat", "Best discards") | system 600 · 10px · UPPERCASE | `letter-spacing:.05em`, color `rgba(231,200,119,.7)` |
| "You win · 自摸" eyebrow | system 600 · 10px · UPPERCASE | `letter-spacing:.12em` |
| Primary body / list labels | system 500–600 · 12–14px | |
| Buttons (CTA) | system 700 · 13–15px | ink `#0C2C24` on gold |
| Captions / notes | system 400 · 10–11.5px / line-height 1.35–1.55 | cream at α |
| Status time `9:41` | system 600 · 12px | `#F1E9D6` |
| AR tile counter "9" | system **200** · 40px/1 | thin numeral |
| Breakdown zh sub-labels | Noto Serif TC 400 · 10.5–11px | `rgba(243,230,196,.5)` |
| Tab labels | system 600 · 10px | |

**Tile-internal type (ratios of `w`):** numeral `round(w*0.5)` 700; `萬` sub `round(w*0.33)` 700; honor glyph `round(w*0.62)` 700; all `line-height:1`.

### 2.3 Spacing, radii, shadows, gradients, blur

**Corner radii (mockup px):** phone `46` · screen `39` · Dynamic Island `12` · home indicator `3` · cards `20/16/14/13/12/11` · buttons `14/13` · bottom sheets `22`/`24` (top corners only) · pills `20/18/15/14/11/9/8` · toggles `12` · reticle corner brackets `8–9` · segmented toggle `18` (track) / `15` (thumb) · tile `round(w*0.19)`.

**Shadows:**
| Shadow | Value | Where |
|---|---|---|
| Phone frame | `0 16px 36px -12px rgba(0,0,0,.5), 0 2px 6px rgba(0,0,0,.25)` | doc-only |
| Gold CTA | `0 8px 22px rgba(231,200,119,.3)` | Welcome primary button |
| Result hero | `0 10px 26px rgba(0,0,0,.4)` | Result hero card |
| Bottom sheet | `0 -10px 30px rgba(0,0,0,.4)` | Why-wait sheet |
| Popover | `0 12px 30px rgba(0,0,0,.5)` | Live insight card |
| Tab bar | `0 12px 30px rgba(0,0,0,.16)` (dark: `.45`) | tab bar |
| Shutter button | `0 4px 12px rgba(231,200,119,.4)` | Detect shutter |
| Tile detect glow | `0 0 7px rgba(231,200,119,.45)` | detected box |
| Tile flag/best glow | `0 0 8–9px rgba(231,200,119,.5–.55)` | correction / coach |
| Sweep line glow | `0 0 12px #E7C877` | scan line |

**Gradients:**
| Name | Value |
|---|---|
| Gold CTA button | `linear-gradient(180deg, #F0D89A, #E7C877)` |
| Jade card / selected row | `linear-gradient(160deg, #1C6553, #0E3A31)` |
| Result hero | `linear-gradient(158deg, #1C6553, #0C3128)` |
| Persona/laneNo (doc) | `linear-gradient(160deg, #1C6553, #0E3A31)` |
| Scan sweep line | `linear-gradient(90deg, transparent, #F0D89A, transparent)` |
| Tile face | `linear-gradient(155deg, a, b)` (per theme) |
| Phone frame (doc) | `linear-gradient(150deg, #2b2b2f, #0d0d0f 42%, #232323)` |
| Screen backgrounds | radial gradients — see §2.1 greens |

**Backdrop blur / saturate:**
| Surface | Value |
|---|---|
| Tab bar | `blur(22px) saturate(1.7)` |
| Scan status cards | `blur(22px) saturate(1.5)` |
| Bottom sheets (correction/detail) | `blur(24px) saturate(1.5)` |
| Why-wait / popover sheets | `blur(20–24px)` |
| Score/Coach toggle | `blur(16px)` |
| Hint pills | `blur(8px)` / `blur(10px)` |
| AR glass buttons | `blur(12px)` |
| Glass tile theme | `blur(14px) saturate(1.5)` |
| Live/AR camera photo | `blur(14px) brightness(.48) saturate(.85)` |

**Animations (keyframes):**
| Name | Definition | Use |
|---|---|---|
| `sweepY` | `translateY(-10%)` → `translateY(520%)`; `2.4s ease-in-out infinite` | scan reticle sweep line |
| `pulseDot` | `opacity .35 → 1 → .35`; `1.2s infinite` (AR particles: `1.4–3.0s` staggered) | live status dot, AR particles |
| `ringSpin` | `rotate(0) → 360deg`; `18s linear infinite` | AR particle ring container |

---

## 3. Components

### 3.1 Phone frame & chrome (doc-only styling, but sets device metrics)
- **Frame:** 244×528px, radius 46, 8px bezel; interior **screen 228×512px, radius 39, clip**.
- **Dynamic Island:** absolute, top 9px, centered, **74×22px**, `#000`, radius 12, z 30.
- **Status bar:** flex space-between, padding `12px 20px 0`, color `#F1E9D6`; time `9:41` (system 600·12px); battery glyph 22×11px, 1.3px border, radius 3, 75%-filled bar, opacity .85.
- **Home indicator:** bottom 6px, centered, **96×5px**, `rgba(243,230,196,.42)`, radius 3.

### 3.2 MahjongTile (parametric) — `MahjongTile.html`
**Props:** `suit` = `dots|bamboo|chars|wind|dragon|flower` (default `chars`); `rank` = `1–9` | winds `E/S/W/N` | dragons `R`(red 中)/`G`(green 發)/`W`(white); flowers `1–4` → 春夏秋冬; `theme` = `flat|classic|ivory|jade|glass` (default `classic`); `w` = width px (default 64; min 20, max 160).

**Frame geometry (all ratios of `w`):**
- `height = round(w * 1.35)`
- `border-radius = round(w * 0.19)`
- background: glass → solid `a`; else `linear-gradient(155deg, a, b)`
- border: `1px solid bd`; box-shadow: `sh, inner`
- centered flex; `overflow:hidden`; glass adds `backdrop-filter: blur(14px) saturate(1.5)`

**Suit rendering (ratios of `w`):**
| Suit | Rule |
|---|---|
| **Dots (n>1)** | dot size = `round(w*0.22)` if n≤5 else `round(w*0.175)`; circle; fill `radial-gradient(circle at 38% 34%, rgba(255,255,255,.55), rgba(255,255,255,0) 55%), dot`; ring `inset 0 0 0 1.5px dotRing`. Wrap: flex-wrap, gap `round(w*0.07)`, width `round(w*0.7)`, centered. Dots count = n. |
| **Dot (n=1)** | single `round(w*0.5)` circle, `radial-gradient(circle, dot 0 24%, transparent 26% 42%, dotRing 44% 60%, transparent 62%)` (concentric ring). |
| **Bamboo (n≠1)** | bar = `round(w*0.1)` × `round(w*0.4)`, radius `round(w*0.06)`, fill `bam`, insets `-1px rgba(0,0,0,.15)` / `+1px rgba(255,255,255,.25)`. Wrap width = `round(w*0.42)` if n≤2 else `round(w*0.64)`; n bars. |
| **Bamboo 1 (bird)** | body circle `round(w*0.26)` fill `dR`; triangle tail (borderLeft/Right `round(w*0.11)` transparent, borderTop `round(w*0.16)` solid `dR`); stalk `round(w*0.055)`×`round(w*0.26)` fill `bam`. |
| **Chars** | numeral (CN 一…九) `round(w*0.5)` 700 color `num`; sub `萬` `round(w*0.33)` 700 color `sub`. |
| **Wind** | glyph `round(w*0.62)` 700 color `E`: E→`東` S→`南` W→`西` N→`北`. |
| **Dragon R/G** | `中` (rank R or n=1) color `dR`; else `發` color `dG`; size `round(w*0.62)`. |
| **Dragon W (white)** | outer rect `round(w*0.46)`×`round(w*0.6)`, `2px solid dW`, radius 3; inner inset `round(w*0.06)`, `1px solid dW`, radius 2. |
| **Flower 1–4** | `春/夏/秋/冬` color `dG`, size `round(w*0.62)`. |

**Usage convention in walkthrough:** `ivory` = tiles composited over the live camera (physical look); `jade` = tiles rendered inside app cards/sheets. Onboarding uses `jade`. Observed widths: 60 (logo), 52 (detail), 40, 34, 30, 26, 24, 22 (detected), 21, 20, 18 (dense grids).

### 3.3 Bottom tab bar — `IOSTabBar.html`
- **Container:** inline-flex, gap 2px, padding 6px, radius **24**, bg `rgba(30,30,32,.68)` (dark), border `1px rgba(255,255,255,.16)`, `backdrop-filter: blur(22px) saturate(1.7)`, shadow `0 12px 30px rgba(0,0,0,.45)`. App positions it bottom `16px`, centered, z 14, rendered ~200×54px.
- **Tab (each):** flex column, align center, gap 3px, padding `6px 15px`, radius **18**. Active: bg = accent (`#1F6F5C`), fg = ink (`#F3E6C4`). Idle: transparent bg, fg `rgba(255,255,255,.55)`.
- **Icons (15px, `currentColor`):** Scan = rounded square viewfinder (2px border, radius 5, inner inset 3px 1.5px border radius 2). Learn = 3 stacked bars (h2px, widths 100/100/60%, gap 2.5). Settings = 2 slider rows (5px tall, 2px track @ .85 opacity, 5px knob; row1 knob left, row2 knob right; gap 3).
- **Labels:** `Scan` / `Learn` / `Settings`, system 600·10px.

### 3.4 Buttons
| Variant | Spec |
|---|---|
| **Primary (gold CTA)** | height 44–48px, radius 13–14, `linear-gradient(180deg,#F0D89A,#E7C877)`, text `#0C2C24` system 700·13–15px, centered. Welcome variant adds shadow `0 8px 22px rgba(231,200,119,.3)`. |
| **Secondary (gold outline)** | height 44px, radius 13, bg `rgba(231,200,119,.1)`, border `1px rgba(231,200,119,.35)`, text `#E7C877` 600·13px. |
| **Ghost / outline-on-dark** | bg `rgba(255,255,255,.06)`, border `1px rgba(231,200,119,.25)`, text `#F0D89A` 600. |
| **Torch (warning outline)** | bg `rgba(231,200,119,.16)`, border `1px rgba(231,200,119,.5)`, text `#F0D89A` 600·13px. |
| **Text link ("Maybe later")** | system 500·13px, `rgba(243,230,196,.55)`, centered, no chrome. |

### 3.5 Cards & sheets
- **List/info card:** bg `rgba(255,255,255,.04)`, border `1px rgba(231,200,119,.12–.14)`, radius 13–16, padding ~11–14px.
- **Selected card / row:** `linear-gradient(160deg,#1C6553,#0E3A31)`, border `1.5px #E7C877`, radius 14–16.
- **Bottom sheet:** bg `rgba(13,45,37, .85–.94)`, `backdrop-filter: blur(24px) saturate(1.5)`, top border `1px rgba(231,200,119,.2–.25)`, radius `22–24px 22–24px 0 0`; grabber 34×4px, radius 3, `rgba(231,200,119,.3)`, centered with `margin 0 auto`.
- **Result hero card:** `linear-gradient(158deg,#1C6553,#0C3128)`, border `1px rgba(231,200,119,.42)`, radius 20, padding 14, shadow `0 10px 26px rgba(0,0,0,.4)`, centered text.

### 3.6 Chips, pills, badges (in-app)
| Element | Spec |
|---|---|
| **Filter chip (active)** | text `#0C2C24`, bg `#E7C877`, radius 14, padding `5px 12px`, 600·11px. |
| **Filter chip (idle)** | text `rgba(243,230,196,.6)`, bg `rgba(255,255,255,.06)`, radius 14. |
| **Status pill (gold)** | e.g. "1-shanten", "→ 128 points": text `#0C2C24`, bg `#E7C877`, radius 18–20, padding `3–4px 9–12px`, 600–700. |
| **Warning pill** | "1 to fix": text `#FFB84D`, bg `rgba(255,159,10,.16)`, radius 20, padding `3px 8px`, 600·10px. |
| **Info banner pill (gold)** | "Double East … +2 faan": text `#0C2C24`, bg `#E7C877`, radius 9–11, padding `6–8px 10–11px`, 600·10–10.5px. |
| **BEST tag** | text `#0C2C24`, bg `#E7C877`, radius 10, padding `2px 6px`, 700·8.5px. |
| **AVOID tag** | text `#fff`, bg `#B4542A`, radius 10, padding `2px 6px`, 700·8.5px. |
| **LIVE pill** | dot (7px, `#E7C877`, `pulseDot`) + "LIVE" 600·11px `#F3E6C4`, bg `rgba(10,36,29,.55)`, border `1px rgba(231,200,119,.3)`, radius 14. |
| **Detail tag** | "Suit tile"/"Terminal": text `#E7C877`, bg `rgba(231,200,119,.12)`, radius 20, padding `4px 10px`, 600·10px. |

### 3.7 Segmented control — Score / Coach toggle
- Track: inline-flex, bg `rgba(12,44,36,.42)`, `backdrop-filter: blur(16px)`, border `1px rgba(231,200,119,.3)`, radius 18, padding 3px.
- Active segment: text `#0C2C24`, bg `#E7C877`, radius 15, padding `5px 14px`, 600·11px.
- Idle segment: text `#F1E9D6`, padding `5px 14px`, no bg.
- Also appears as a full-width 2-cell selector (Self-draw / By discard; seat/round winds) with the selected cell as a jade-gradient+gold-border card and idle cells `rgba(255,255,255,.05)`.

### 3.8 Toggle (switch)
- Track 38×22px, radius 12; **ON:** bg `#1F6F5C`, knob 18px white circle at `left:18px, top:2px`. (Off state not shown; mirror knob to left.)

### 3.9 Scan overlay / reticle
- **Alignment frame:** ~184×96px region (sized for a 13–14 tile row). Four **corner brackets** 22–24px, `3px solid rgba(231,200,119,.85)`, radius 8 on the outer corner only.
- **Sweep line:** left/right inset 6px, top 0, height 2px, `linear-gradient(90deg,transparent,#F0D89A,transparent)`, glow `0 0 12px #E7C877`, `animation: sweepY 2.4s ease-in-out infinite`.
- **Low-light variant:** dashed frame `2px dashed rgba(231,200,119,.4)`, radius 12 (no sweep).
- **Locked bracket (AR-B):** corner brackets 26px `3px solid #E7C877`, radius 9, with a centered tag "Your hand · 14 tiles ✓".

### 3.10 Detected-tile bounding box
- Base box: `inset:-3px`, border `1.5px rgba(231,200,119,.9)`, radius 6, glow `0 0 7px rgba(231,200,119,.45)`.
- Low-confidence overlay: extra box `inset:-3px`, border `2px #FF9F0A`, radius 6, plus **"?" badge** top `-8px` right `-6px`, 14px circle `#FF9F0A`, text `#1a1a1a` 700·9px.
- Live/table variant: thinner `inset:-2px`, `1.5px rgba(231,200,119,.7–.85)`, radius 5–6.

### 3.11 Score breakdown row
- Container: card `rgba(255,255,255,.04)`, border `rgba(231,200,119,.12)`, radius 16, padding `4px 13px`.
- Row: flex space-between, padding `7px 0`, border-bottom `1px rgba(231,200,119,.12)`. Left = EN name (600·12px `#F5ECD4`) + zh (Noto Serif TC 400·10.5px `rgba(243,230,196,.5)`). Right = `+{faan}` (Noto Serif TC 700·12.5px `#E7C877`).
- Total row: no border, "Total" 700·12.5px + "7 番" 800·14px `#E7C877`.

### 3.12 Coach discard row
- Row: flex, gap 9px, padding `8px 9px`, radius 12, bg `rgba(255,255,255,.04)`, border `1px rgba(231,200,119,.13)`. Left = jade tile w26. Center = `"{sh}-shanten · {uke} tiles"` (600·11.5px) + optional BEST/AVOID tag + note (400·9.5px `rgba(243,230,196,.6)`). BEST row adds a full-border overlay `1.5px #E7C877`, radius 12.

### 3.13 Wind compass (Learn)
- 200×200 container. Center round-tile plate: inset 50px, `linear-gradient(160deg,#1C6553,#0E3A31)`, border `1px rgba(231,200,119,.3)`, radius 18; shows "Round" eyebrow + `東` (Noto Serif TC 700·24px `#F0D89A`) + "East round".
- Four seat chips at N/E/S/W edges: idle chips `rgba(255,255,255,.05)`, border `1px rgba(231,200,119,.14)`, radius 10, padding `5px 8px`, glyph 700·14px + role label 500·8px. Active seat (bottom, "You · Dealer"): jade gradient + `1.5px #E7C877` border, glyph `東` + gold `×2` chip.

---

## 4. Screen-by-Screen

> Every string below is verbatim. Screen bg = the radial/solid from §2.1 unless noted. All screens carry Dynamic Island + status bar (`9:41`) + home indicator.

### Lane 1 · Onboarding

#### 1 — Welcome
**Purpose:** brand + privacy promise; entry.
Bg: welcome radial (`#15493C`/`#08211B`). Centered column: `MahjongTile` dragon R jade w60 → app name **`Mahjong Sensei`** (Noto Serif TC 700·22px `#F0D89A`) → `麻雀先生` (11px, letter-spacing .34em, `rgba(243,230,196,.5)`) → `Point your phone at the tiles.` / `Get the score, and the reason why.` (14px/1.5 `rgba(243,230,196,.7)`). Bottom: primary gold button **`Get started`** (48px), caption **`100% on-device · works offline`** (500·11px). *Caption(doc): "A promise, not a login — friendly, private, English-first. No account."*

#### 2 — Pick your style
**Purpose:** choose ruleset (HK pre-selected).
Title **`Which style do you play?`** (Noto Serif TC 700·22px `#F5ECD4`), sub **`Tunes scoring & coaching to your table.`**. Three selectable rows (jade tile w30 + name + zh meta + radio):
- **`Hong Kong`** / `廣東麻雀 · 13 · faan` — SELECTED (jade gradient, `1.5px #E7C877`, gold ✓ check).
- **`Riichi`** / `日本麻雀 · 13` — idle radio.
- **`Taiwanese 16`** / `台灣麻將 · 16` — idle radio.
Bottom gold button **`Continue`** (46px). *Caption(doc): "Hong Kong is pre-selected … Riichi = Phase 4."*

#### 3 — Set your table (house-rules preset)
**Purpose:** pick scoring preset.
Title **`How does your table score?`**, sub **`Faan tables aren't standardized. Start from a preset — fine-tune anytime.`** Three preset cards:
- **`Family default`** ✓ selected — `3 faan min · half-spicy · limit 10 · flowers on`.
- **`Common club`** — `3 faan · full-spicy · limit 13`.
- **`Custom…`** — chevron `›`.
Bottom **`Continue`**. *Caption(doc): "Presets hide the complexity … Long-press → preview values."*

#### 4 — Camera primer
**Purpose:** pre-permission privacy priming.
Centered: 76×76 rounded-square icon tile (bg `rgba(231,200,119,.12)`, border `rgba(.35)`) containing a 38×38 viewfinder glyph (2.5px `#E7C877`). Title **`Read tiles with the camera`** (Noto Serif TC 700·20px). Body: **`Mahjong Sensei reads tiles on your device. Images are processed live and never leave your phone — nothing is uploaded or stored.`** (13.5px/1.55; "on your device" & "never leave your phone" emphasized `#F0D89A`). Bottom gold button **`Enable camera`** + text link **`Maybe later`**. *Caption(doc): "Earn the permission … Denied → manual-entry fallback."*

### Lane 2 · Scan → Score

#### 5 — Aim at your hand
**Purpose:** live camera capture.
Bg: camera radial. Top center: **Score/Coach toggle** (Score active) + hint pill **`Lay your hand flat, face-up`**. Center: alignment reticle 184×96 with 4 gold corner brackets + animated `sweepY` line. Bottom scan card (glass): **`Looking for tiles…`** (600·13px, with pulsing 7px gold dot) + 48px gold shutter button (`0 3px…` border ring). Tab bar (Scan active). *Caption(doc): "Camera-forward, minimal chrome … Hold steady to auto-lock."*

#### 6 — Tiles detected
**Purpose:** show detections + confidence.
Center: row of 7 **ivory** tiles w22, each in a gold bounding box; one flagged tile carries the amber `?` box + badge. Corner brackets 22px. Bottom card: **`14 tiles found`** (700·14px `#F5ECD4`) + **`1 low-confidence · tap to review`** (500·10.5px `#E7C877`) + gold shutter (shadow). Tab bar (Scan). *Caption(doc): "Boxes + confidence, on-device. YOLO→Core ML via Vision… Low-confidence tiles glow amber."*

#### 7 — Check & correct
**Purpose:** reliability layer — one-tap correction.
Header: **`‹ Back`** (`#E7C877`) · **`Check your hand`** (Noto Serif TC 14px) · **`1 to fix`** warning pill. Sub **`Tap any tile to correct it.`** Tile tray card: 14 **jade** tiles w21 wrap-centered; flagged tile has gold box + amber `?`. **Bottom sheet (picker):** grabber; title **`Replace — Characters 萬`** (Noto Serif TC 12.5px); chars 1–9 jade w24, suggested (六/6) ringed gold `2.5px` + soft outer glow; CTA **`Use 六萬 · Looks right →`** (gold, 44px). *Caption(doc): "Nothing is scored until it passes here … Long-press → remove · '+' → add."*

#### 8 — A few quick taps (context)
**Purpose:** capture seat + round + win type.
Title **`Almost there`** (Noto Serif TC 19px), sub **`Winds are computed for you.`** Section **`Your seat`** → 4-cell wind selector `東 南 西 北` (東 selected). Section **`Round wind`** → same, `東` selected. Gold info pill **`Double East · seat + round match → +2 faan`**. Win-type 2-cell: **`Self-draw 自摸`** (selected) / **`By discard`**. Toggle row **`I'm the dealer`** (ON, `#1F6F5C`). *Caption(doc): "Ask seat + round, derive the rest … Special-win toggles below fold."*

#### 9 — Result
**Purpose:** score payoff + breakdown.
Header **`Result`** (Noto Serif TC 14px) + `✕` close (26px circle). Scrollable body:
- **Hero card:** eyebrow **`You win · 自摸`** (letter-spacing .12em); **`7`** (Noto Serif TC 700·46px `#F0D89A`) + **`番`** (20px); pill **`→ 128 points`**.
- **Meld strip:** 5 groups on `rgba(0,0,0,.22)` chips, jade tiles w21. Data: Chow 2·3·4 萬, Chow 6·7·8 萬, Pung 中·中·中, Pung 東·東·東, Pair 白·白.
- **Breakdown rows** (`+{faan}`): `Mixed One Suit 混一色 +3` · `Red Dragon Pung 紅中 +1` · `Round + Seat Wind · East 圈風+門風 +2` · `Self-Draw 自摸 +1` · **`Total 7 番`**.
- **Actions:** secondary **`Why?`** + primary **`Save hand`**.
*Caption(doc): "Big number, then the receipt … Tap a row → jump to 'why'. Scoring < 200 ms."*

#### 10 — Why this score
**Purpose:** teach each faan.
Header **`‹`** + **`Why 7 faan?`**. Cards (each: EN name + zh + `+n`, plain-English reason):
- **`Mixed One Suit 混一色 +3`** — *"One suit (characters) plus honor tiles only — no second number suit."*
- **`Red Dragon Pung 紅中 +1`** — shows 3× dragon R jade w20 — *"A triplet of dragons always scores, whatever your seat."*
- **`Double East 圈風+門風 +2`** — *"Your East pung is both seat wind and round wind — so it counts twice."*
- **`Self-Draw 自摸 +1`** (no description).
*Caption(doc): "Teach, don't just compute … >40% open 'why this score'."*

#### Edge — Low light *(branches from 5)*
Bg: low-light radial. Dashed reticle 184×96. Warning card (amber wash): **`Too dark to read tiles`** (600·13px `#FFD08A`) + **`Move to better light, or tap to turn on the torch.`** Torch button **`Turn on torch`**. *Caption(doc): "Fail softly, guide the fix … never a dead end."*

#### Edge — Chicken hand *(branches from 9)*
Centered: 66px circle (amber) with **`雞`** (Noto Serif TC 30px `#FFB84D`). **`Chicken hand · 0 faan`** (Noto Serif TC 19px). Body: **`A complete shape, but no scoring elements. Under your 3-faan minimum, it can't win.`** Nudge pill (gold wash): **`Want value? A Half Flush here would clear the minimum. Try Coach →`**. *Caption(doc): "Explain the 'no', offer a path."*

#### Edge — Incomplete *(branches from 9)*
Centered: 66px dashed rounded-square with **`?`** (`#E7C877`). **`Not a winning shape yet`** (Noto Serif TC 18px). Body: **`A win needs four sets and a pair. You have 3 sets + a pair, and two loose tiles.`** Buttons **`Edit tiles`** · **`Coach it`**. *Caption(doc): "Say what's missing … names the gap."*

#### Edge — Two readings *(branches from 9)*
Title **`Two ways to read this`** + **`We always score the higher one for you.`** Selected card: **`All Pungs 對對糊`** / **`7 番`** + pill **`Used — highest`**. Alt card: **`Mixed Suit + chows`** / **`5 番`** + **`Alternate decomposition`**. *Caption(doc): "Take the max, show the rest."*

### Lane 3 · Coach

#### 11 — Flip to Coach
Same camera screen as 5, toggle set to **Coach**; hint **`I'll suggest your best discard`**; ivory tiles w22 in reticle; CTA **`Coach this hand →`** (gold). Tab bar (Scan). *Caption(doc): "One scan, two destinations … Toggle before or after scan."*

#### 12 — Ranked discards
Header **`Coach`** + gold pill **`1-shanten`**. Hand tray: 14 jade tiles w18; recommended tile (9萬) glows gold. Section **`Best discards`**. Rows (from data):
- **9萬** — `1-shanten · 12 tiles` · **BEST** — *"Isolated tile — tossing it keeps the bamboo flush (7 faan) and the green-dragon pung alive."*
- **3筒** — `1-shanten · 8 tiles` — *"Also 1-shanten, but commits off-suit and abandons the flush — a cheaper hand."*
- **綠發** — `2-shanten · 4 tiles` · **AVOID** — *"Breaks your dragon pair: drops a full shanten and kills a guaranteed faan."*
*Caption(doc): "Shanten + ukeire, ranked … Tap a row → why."*

#### 13 — Why — wait quality
Bottom sheet. Row: chars 9 jade w34 + **`Discard 9 characters`** (Noto Serif TC 16px) + **`Reaches 1-shanten`** (`#E7C877`). Card: **`Two-sided wait 兩面 · the strongest`** + **`Keeps 3–4 bamboo open on both ends. You then accept:`** Tiles: bamboo 2, bamboo 5, **`+ dragon`**, dragon G (jade w26). Footer: **`12 live tiles advance the hand — versus 4 for an edge wait.`** *Caption(doc): "Name the wait, teach the shape."*

#### 14 — Value overlay
Header: amber `!` circle + **`Fast isn't always a win`** (Noto Serif TC 16px). Amber card: **`Fast line — tenpai now`** + **`Ditch the dragons, keep the dots: you're ready immediately — but it's an all-chows chicken hand. 0 faan, can't win under your 3-faan rule.`** Jade/gold card: **`Value line — keep the flush`** / **`7 番`** + **`One more tile away, but it's a Full Flush + dragon pung. Coach recommends this line.`** Footer: **`HK needs a faan minimum — so Coach weights value, not just speed.`** *Caption(doc): "The HK differentiator … Never worse-shanten without flagging."*

#### 15 — Calling advice
**`West just discarded`** + dragon G jade w40 + **`Call Pung?`** (Noto Serif TC 17px). Jade/gold card: **`Yes — take it`** + **`Completes your green-dragon pung (+1 faan) and jumps you to tenpai. HK opens freely — no concealed premium here.`** Neutral card: **`Trade-off`** + **`Opening reveals the pung and rules out fully-concealed (+1). Net still positive here.`** Buttons **`Call Pung`** (gold) · **`Pass`** (outline). *Caption(doc): "Model the open-hand culture … Prompted on live discards."*

#### 16 — Real-time overlay (Live)
Bg: **blurred table photo** (`uploads/pasted-1784267515565-0.png`, blur/dim/desaturate; **asset not committed to repo**) + solid `#0a120d`. Top-left **LIVE** pill. **`Discards`** label + 3 jade tiles w21 (1筒, 南, 6索) rotated −3°, each boxed gold. **`Your hand · 1 away`** label + 7 jade tiles w21 boxed. Bottom caption **`Reading your hand + discards → Coach`**. *Caption(doc): "Reads the whole table … **ARKit anchors the labels to the felt.** Real-time < 50ms/frame · Face-up tiles only."* **→ AR conflict, see §6.**

#### 17 — Tap for insight (Live)
Same blurred bg. 7 jade tiles w21. **Popover card** (`0 12px 30px` shadow): **`Your hand · 1-shanten`** + chars 9 tile + **`Coach: discard 9 characters`** + **`Keeps the flush — 7 faan line`** + info block **`Counting the table: 2 of your 8 outs are already in the discards → 6 live.`** Bottom: **`Score`** / **`Coach`** buttons. *Caption(doc): "Most probable move, from what's live … Tap a group → Coach popover."*

#### A — Finding · privacy blur (AR lens preview)
Blurred bg. Eyebrow **`FINDING`** + **`Your hand`**. Center: spinning **particle ring** (54 dots, `ringSpin 18s`, each `pulseDot`). Text **`Looking for tiles`** + **`Move closer to the rack and hold steady.`** Counter **`9`** (system 200·40px) + **`tiles`**. Bottom corners: `✕` close (42px glass circle) + camera-flip glass button. *Caption(doc): "Borrowed trust: Find My's finding ritual … The blur never fully lifts; rendered tiles become the readable layer." **→ borrows iOS 26 Find My; see §6.***

#### B — Locked · lens focuses (AR lens preview)
Blurred bg + top scrim. Eyebrow **`LOCKED`** (`#E7C877`) + **`Your hand`**. Label **`Discards · 12 read`** + 3 jade tiles w18 boxed. Center: **locked bracket** (26px `#E7C877` corners) with tag **`Your hand · 14 tiles ✓`** enclosing 14 jade tiles w18. Coach card: chars 9 tile + **`Coach · discard 9 characters`** + **`Keeps the flush — 6 of 8 outs still live`**. Bottom `✕` + camera buttons. *Caption(doc): "The overlay is the legible layer … Blur = privacy, always · Lock < 3 s · Tap a tile → correct."*

### Lane 4 · Learn

#### 18 — Wind Explainer
Title **`Seats & winds`** + **`Tap a seat to rotate the deal.`** **Compass (200×200):** center plate `Round / 東 / East round`; edges — top `北 Uncle`, right `西 Cousin`, left `南 Mum`, bottom (highlighted) `東 ×2 / You · Dealer`. Bottom gold pill **`Your East is seat + round → Double East · +2 faan`**. *Caption(doc): "The retention hook … Tap seat → animate rotation."* (Seat data: N Uncle / W Cousin / E You·Dealer / S Mum.)

#### 19 — Tile Dictionary
Title **`Dictionary 字典`**. Search field **`Search 42 tiles`** (magnifier glyph). Filter chips: **`Dots`** (active) · **`Bamboo`** · **`Chars`** · **`字`**. 3-column grid of dots 1–9 (jade w34) each labeled **`{n} Dot`**. Tab bar (Learn active). *Caption(doc): "All 42 faces, searchable … EN + 繁中 name, Jyutping, notes; built-in quiz."*

#### 20 — Tile detail
Bottom sheet. Header: bamboo 1 jade w52 (the bird) + **`One Bamboo`** (Noto Serif TC 19px) + **`一索 · jāt sok`** (Jyutping in gold). Body: **`Despite its name, the 1 of Bamboo is drawn as a bird, not a stick — a classic beginner trip-up, and why it breaks the "count the sticks" logic.`** Tags: **`Suit tile`** · **`Terminal`**. *Caption(doc): "Bilingual, with the lore … VoiceOver announces tile names. Dynamic Type + VoiceOver."*

### Lane 5 · House Rules & Settings

#### 21 — House Rules
Header **`‹ House Rules`** (Noto Serif TC 20px). Preset tabs: **`Family`** (active) · **`Club`** · **`Custom`**. Grouped editable rows (name `#F5ECD4` / value `#E7C877`):
- **Winning:** `Minimum faan → 3` · `Limit cap → 10 faan`
- **Ambiguous hands:** `All Pungs 對對糊 → 3 faan` · `Half Flush 混一色 → 3 faan` · `Conversion → Half-spicy`
- **Bonus & payments:** `Flowers → On` · `Self-draw → All pay` · `Dealer double → On`
*Caption(doc): "Configurability is mandatory … Preset → per-row override. Feeds Scoring, Coach, and the catalog."*

#### 22 — Settings
Title **`Settings`** (Noto Serif TC 22px). List rows (`name … value ›`): **`Language → English`** · **`Appearance → Jade · Dark`** · **`House rules → Family default`** · **`Camera → Allowed`**. Second group: **`About ›`** · **`Send feedback ›`**. Footer: **`Everything runs on-device · no account · images never leave your phone.`** Tab bar (Settings active). *Caption(doc): "Quiet, private, done … Local-only data."*

---

## 5. Interaction & Flow Notes

**Global**
- **Dark, editorial identity throughout.** One shipped appearance ("Jade · Dark"). No light mode shown.
- **Two-destination architecture:** a single **Score / Coach segmented toggle** on the scan screen is the only fork; both destinations share the same recognition + correction overlay. Toggle can be flipped before or after scanning.
- **Bottom sheets** are the dominant modal pattern (correction picker, why-wait, tile detail) — grabber-topped, heavy blur, rounded top corners.

**Scan (screens 5–7, 11)**
- Live `AVCaptureSession` preview is the hero; minimal chrome. A single **alignment reticle** sized for a 13–14 tile row, with an animated **sweep line** (auto-lock affordance: "Hold steady to auto-lock"). A manual **shutter** (48px gold circle) is also present.
- On detection: **screen-space bounding boxes** with gold strokes; **per-tile confidence** surfaced subtly — low-confidence tiles glow **amber** with a `?` badge.
- **Correction UI (7):** tap any tile → bottom-sheet **tile palette** (suit-scoped, e.g. Characters 萬 1–9) with a **suggested** tile pre-ringed; confirm via "Use X · Looks right →". Long-press removes; "+" adds. This is the reliability gate — nothing scores until it passes.
- **Low-light** state warns and offers torch; never a dead end.

**Score result (9–10, edges)**
- **Big faan number → points** up top (hero), then meld strip, then itemized **breakdown rows** (EN + zh + `+faan`, Total), then actions ("Why?" / "Save hand"). Payments already resolved.
- Tapping a breakdown row jumps to **"Why this score"** teaching cards.
- Edge outcomes: **Chicken hand** (below min faan, nudges Coach), **Incomplete** (names missing sets/pair), **Two readings** (enumerates decompositions, scores the max, shows the rest).

**Coach / Discard trainer (12–15)**
- Computes **shanten + ukeire**; ranks every discard; **best tile glows** on the hand. Rows carry BEST/AVOID tags and teaching notes.
- **Wait-quality** classification in plain terms ("Two-sided wait 兩面 · the strongest" vs edge).
- **Value overlay** — the HK differentiator: flags when the fastest line makes a valueless (chicken) hand under the faan minimum; weights value, not just speed.
- **Calling advice** — open-hand aware: weighs a meld's faan against losing concealment (HK opens freely, unlike Riichi).

**Live & AR (16, 17, A, B) — beyond MVP**
- Real-time overlay reads **hand + every face-up discard**; live tiles are subtracted from ukeire to count **real outs** ("6 of 8 outs still live").
- **AR lens preview** borrows the **iOS 26 Find My "finding" ritual**: the camera feed **stays blurred** (privacy signal), a particle ring orbits while searching, then a bracket "locks" the rack and **re-rendered tiles become the legible layer**. Caption explicitly claims **ARKit anchors labels to the felt** and **< 50ms/frame** real-time.

**Learn (18–20)**
- Interactive **wind compass** (tap a seat → rotate the deal, double-wind lights up) — the retention hook targeting the #1 confusion.
- **Tile dictionary:** 42 faces, searchable, suit filters, EN + 繁中 + Jyutping + lore; built-in quiz mentioned; VoiceOver announces tile names.

**Settings & House Rules (21–22)**
- **House Rules** is where configurability lives: presets (Family/Club/Custom) with **every faan value editable per row** — feeds Scoring, Coach, and the dictionary.
- **Settings:** Language (EN / 繁), Appearance (Jade · Dark), House rules shortcut, Camera status, About, Send feedback. Privacy promise restated.

---

## 6. iOS Implementation Notes (SwiftUI) & Constraint Flags

### 6.1 Mapping to SwiftUI / iOS
| Design element | SwiftUI / iOS construct |
|---|---|
| Screen radial backgrounds | `RadialGradient` (or layered `ZStack` + `.ignoresSafeArea`), dark scheme forced |
| Glass cards / sheets / tab bar | `.background(.ultraThinMaterial)` / custom material tuned to `rgba(13,45,37,.85)`; **or** `.regularMaterial` + tint overlay. Match `blur(22–24px) saturate(1.5–1.7)`. |
| Bottom sheets | `.sheet` / `.presentationDetents([...])` with grabber; custom corner radius 22–24 |
| Score/Coach toggle | custom segmented control (native `Picker(.segmented)` won't match; build with `Capsule` + matchedGeometry thumb) |
| Toggle switch | `Toggle` with `.tint(Color(#1F6F5C))` (native track differs; may need custom to match 38×22) |
| Tab bar | Custom floating bar (native `TabView` bar is edge-pinned; design floats it 16px up, pill-shaped) — build with `HStack` + material capsule |
| MahjongTile | Custom `View` parameterized by `suit/rank/theme/w`; all geometry as `w * ratio` (see §3.2). Consider `Canvas`/shape layers for dots/bars/bird; text glyphs for chars/honors. |
| Big faan numeral, Chinese | Bundle **Noto Serif TC** (`.otf`) → `Font.custom`. Latin body → SF Pro via `.system`. |
| Detected boxes / reticle / brackets | `overlay` strokes in screen space over `AVCaptureVideoPreviewLayer` (via `UIViewRepresentable`) |
| Camera | `AVCaptureSession` + `AVCaptureVideoPreviewLayer`; recognition via **Vision + Core ML** (YOLO → `.mlpackage`) on the Neural Engine |
| Sweep / pulse / ring animations | `withAnimation(.easeInOut.repeatForever())`; `TimelineView` for the particle ring |
| Dynamic Type / VoiceOver | scalable fonts; `.accessibilityLabel` announcing tile names (EN + 繁中); ≥44pt targets |
| Chips / pills / tags | `Capsule`/`RoundedRectangle` with the token colors in §2.1 / §3.6 |

Tile-color note: the tile component keys marks off a per-theme palette. Model this as a `TileTheme` enum with a struct of colors (`face1, face2, border, dropShadow, innerShadow, dot, dotRing, bam, num, sub, wind, dragonRed, dragonGreen, dragonWhite, font`) — copy the five tables in §2.1 verbatim. Preserve the **ivory-for-camera / jade-for-app** convention.

### 6.2 Constraint flags (fully on-device / offline · **no ARKit for MVP** · iOS 26+ · iPhone 15+)

1. **ARKit / world-anchoring — CONFLICT (confirm decision).** Screen **16** caption states *"ARKit anchors the labels to the felt."* This is world-anchored AR and **violates the no-ARKit-for-MVP constraint**. The project PRD already sequences "Live AR table overlay" as **Phase 2** and says *"ARKit: not required for the flat-hand MVP (Vision alone suffices)."* **Recommendation:** for MVP, implement all overlays as **screen-space** annotations over the `AVCaptureVideoPreviewLayer` (2D bounding boxes that track detections frame-to-frame), **not** world-anchored `ARView` content. Screens 16/17/A/B are **out of MVP scope**; treat them as Phase-2 vision, not a build target.

2. **AR lens preview (A, B) borrows "iOS 26 Find My" finding ritual.** The particle-ring + persistent-blur "finding" moment is aesthetic and can be reproduced **without ARKit** (pure SwiftUI animation over a blurred camera frame). It relies on iOS 26 design language — fine given the iOS 26+ target — but it is **beyond a typical MVP**; the searching/lock states could be simplified to the §3.9 reticle for v1.

3. **Live "reads the whole table" (16, 17) is beyond flat-hand MVP.** Reading hand **plus every face-up discard** at table distance/angle is the hardest recognition case (PRD flags it as most data-hungry, possibly needing LiDAR/depth). Keep MVP to the **single flat-hand scan**; live-table out-counting is Phase 2.

4. **Persistent-blur privacy pattern is load-bearing.** Both AR screens keep the raw feed blurred and show **re-rendered tiles** as the legible layer ("blur = privacy, always"). If any live/AR work is attempted, preserve this: never present the sharp photo as the UI; composite recognized `MahjongTile` views on top. This aligns with the on-device/offline promise repeated across screens ("images never leave your phone").

5. **iOS version mismatch to reconcile.** Task constraint says **iOS 26+**; the PRD (`MahjongMate-PRD.md`) targets **iOS 17+, iPhone 15+**. The blurred-glass materials and Find-My-style ritual read as iOS 26 design language. **Confirm the deployment target** — if iOS 26+, the material/blur fidelity here is fully achievable; if iOS 17+, verify material availability and the Find-My motif's fit.

6. **Fonts:** the mockup loads **Noto Sans TC but never uses it** (system-ui stands in for Latin). Ship **SF Pro** for Latin/UI and **Noto Serif TC** for display + all Chinese. Bundling Noto Sans TC is optional (only needed if a future screen calls for a Chinese *sans* face). Everything must render **offline** — bundle the serif font in-app; do not rely on Google Fonts (the walkthrough's `<link>` to fonts.googleapis.com is a doc artifact only).

7. **On-device engine expectations embedded in captions (targets, not UI):** per-tile detection ≥95%, capture→overlay <3s, scoring <200ms, trainer matches reference oracle, recognition real-time (<~50ms/frame). These are the PRD metrics surfaced as `◷` chips; they are performance contracts for the Vision/Core ML + scoring/shanten engines, not visual specs.

8. **Doc chrome is not app UI.** Lanes, numbered/`!`/`A-B` badges, chips (`● ⌖ ▢ ◷`), gold arrows, persona and legend cards, and the `.phone` bezel are the handoff board — **do not build them**. Only the content inside `.screen` is the app.
