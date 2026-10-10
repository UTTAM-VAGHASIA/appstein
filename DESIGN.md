---
name: Appstein
description: A calm, Apple-style product page for a Flutter knowledge and verification layer, with one blue accent and plenty of white space.
colors:
  accent: "#1f6feb"
  accent-soft: "rgba(31,111,235,.09)"
  on-fill: "#ffffff"
  bg: "#fbfbfd"
  bg-alt: "#f3f4f7"
  surface: "#ffffff"
  surface-2: "#f6f7f9"
  ink: "#1b1c1f"
  ink-2: "#5f636b"
  ink-3: "#666b74"
  line: "rgba(20,24,34,.09)"
  line-2: "rgba(20,24,34,.16)"
  glass: "rgba(251,251,253,.72)"
  device: "#1b1c1f"
  ok: "#176f43"
  ok-soft: "rgba(31,143,85,.10)"
  warn: "#9a5b00"
  warn-soft: "rgba(178,106,0,.10)"
  err: "#b23329"
  err-soft: "rgba(201,58,46,.09)"
  accent-dark: "#5b9bff"
  accent-soft-dark: "rgba(91,155,255,.13)"
  on-fill-dark: "#0c0d0f"
  bg-dark: "#0c0d0f"
  bg-alt-dark: "#121316"
  surface-dark: "#17181b"
  surface-2-dark: "#1d1f23"
  ink-dark: "#f2f3f5"
  ink-2-dark: "#a3a8b0"
  ink-3-dark: "#80858e"
  line-dark: "rgba(255,255,255,.08)"
  line-2-dark: "rgba(255,255,255,.15)"
  glass-dark: "rgba(12,13,15,.7)"
  device-dark: "#2a2c31"
  ok-dark: "#4cc486"
  ok-soft-dark: "rgba(76,196,134,.13)"
  warn-dark: "#e3a33c"
  warn-soft-dark: "rgba(227,163,60,.13)"
  err-dark: "#ff7b6e"
  err-soft-dark: "rgba(255,123,110,.12)"
typography:
  display:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "clamp(2.6rem, 6vw, 4.4rem)"
    fontWeight: 600
    lineHeight: 1.02
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "clamp(1.8rem, 3.6vw, 2.7rem)"
    fontWeight: 600
    lineHeight: 1.08
    letterSpacing: "-0.028em"
  figure:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "clamp(1.9rem, 3vw, 2.5rem)"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.035em"
    fontFeature: "tnum"
  title:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "1.06rem"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  lead:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "clamp(1.05rem, 1.6vw, 1.22rem)"
    fontWeight: 400
    lineHeight: 1.5
  body:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.55
  small:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.84rem"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Geist, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.7rem"
    fontWeight: 500
    lineHeight: 1.5
  mono:
    fontFamily: "Geist Mono, ui-monospace, SFMono-Regular, Cascadia Code, Consolas, monospace"
    fontSize: "0.86em"
    fontWeight: 400
  mono-figure:
    fontFamily: "Geist Mono, ui-monospace, SFMono-Regular, Cascadia Code, Consolas, monospace"
    fontSize: "1.5rem"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "-0.02em"
rounded:
  badge: "7px"
  tile: "10px"
  sm: "12px"
  md: "18px"
  device: "44px"
  pill: "999px"
spacing:
  xs: "8px"
  sm: "12px"
  md: "20px"
  lg: "28px"
  xl: "40px"
  2xl: "56px"
  section: "112px"
  section-mobile: "72px"
  gutter: "24px"
  gutter-mobile: "16px"
components:
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.md}"
    padding: "28px"
  card-compact:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.sm}"
    padding: "18px 20px"
  tag-ok:
    backgroundColor: "{colors.ok-soft}"
    textColor: "{colors.ok}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  tag-warn:
    backgroundColor: "{colors.warn-soft}"
    textColor: "{colors.warn}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  tag-err:
    backgroundColor: "{colors.err-soft}"
    textColor: "{colors.err}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  tag-info:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  tag-neutral:
    backgroundColor: "{colors.line}"
    textColor: "{colors.ink-2}"
    typography: "{typography.label}"
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  pill:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-2}"
    rounded: "{rounded.pill}"
    padding: "5px 11px"
  nav-link:
    textColor: "{colors.ink-2}"
    rounded: "{rounded.pill}"
    padding: "6px 10px"
  nav-link-active:
    backgroundColor: "{colors.line}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "6px 10px"
  theme-toggle:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    size: "34px"
  segmented:
    backgroundColor: "{colors.line}"
    rounded: "{rounded.pill}"
    padding: "3px"
  segmented-option:
    textColor: "{colors.ink-2}"
    rounded: "{rounded.pill}"
    padding: "9px 18px"
  segmented-option-selected:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "9px 18px"
  selectable-card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.md}"
    padding: "18px 22px"
  selectable-card-number-selected:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-fill}"
    rounded: "{rounded.tile}"
    size: "34px"
  code-chip:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink-2}"
    typography: "{typography.mono}"
    rounded: "{rounded.badge}"
    padding: "4px 8px"
  disclosure-summary:
    textColor: "{colors.accent}"
    padding: "16px 0 0"
---

# Design System: Appstein

## Overview

**Creative North Star: "The Quiet Product Page"**

Appstein presents a technical developer tool the way a premium hardware maker presents a device: one idea per section, a large, tightly tracked headline, one sentence of lead copy, and a single diagram or interactive figure that carries the explanation. Density is deliberately low. Each section gets 112px of vertical air, surfaces are white or near-white cards on a faintly cool page, and the only color with identity is one blue. Any detail beyond the headline claim moves into a "Details" disclosure, so the page reads in a skim and the depth is still there for anyone who opens it.

Material is soft and physical without being skeuomorphic. Cards have a hairline border and a two-layer ambient shadow, the sticky nav is frosted glass, and the hero is a rendered phone mockup with floating proof cards (an MCP answer and a passing verifier run). Neither of those is a stock illustration. The mockup shows the product doing its job. Light and dark are both first-class. The page follows the system theme until the reader flips the sun/moon switch, then remembers that choice.

The owner explicitly rejected the earlier directions: a periodic-table grid of elements, a "build instructions" assembly-manual metaphor, a terminal/wayfinding-signage look, and a dense text-first docs page. All four were judged too complex, too themed, too bold, or not clean enough (drafts kept in `docs/project/specs/drafts/`). The system stays clean because it adds no concept on top of the product itself.

**Key Characteristics:**
- One blue accent, tinted cool neutrals, and green/amber/red only as pass/warning/error.
- Geist for everything readable, Geist Mono only for commands, file paths, tool names and code-like figures.
- Large semibold headlines with negative tracking; calm grey lead text capped at 42ch.
- White cards with 18px corners, hairline borders and soft two-layer shadows.
- One diagram or interactive figure per section; extra detail goes behind "Details".
- Light and dark themes with equal standing, system default, choice persisted.

## Colors

A near-monochrome, cool-neutral palette where one clear blue carries every interactive and "selected" meaning, and three status hues appear only as verdicts. Every text color clears 4.5:1 against the surfaces it sits on, in both themes.

### Primary
- **Signal Blue** (`accent`; `accent-dark` in dark theme): links, the selected-state ring, the numbered badge of the selected knowledge layer, "Details" disclosure summaries, the focus outline, the diagram's package boxes, and the phone mockup's one primary action. Its soft tint (`accent-soft`) backs info tags and forms the 3px selection halo.
- **On-Fill** (`on-fill`; `on-fill-dark`): text on solid `accent` or `ok` fills (the phone's primary button, the selected layer number, the final pipeline dot). It is white in light theme and near-black in dark theme, because the dark theme's fills are light.

### Neutral
- **Porcelain** (`bg`) / **Graphite Night** (`bg-dark`): the page ground. Faintly cool, never pure white or pure black.
- **Mist** (`bg-alt`): alternating section bands that separate chapters without rules.
- **Card White** (`surface`) and **Soft Well** (`surface-2`): cards, then the recessed wells inside them (code chips, example blocks, inactive chips, number tiles).
- **Ink** (`ink`): headings and primary text. It also appears inverted as a solid fill for the one "always on" object in a figure (the INDEX.md bar, the final timeline node, the brand mark).
- **Slate** (`ink-2`): lead copy, body descriptions, secondary labels.
- **Fog** (`ink-3`): metadata (timestamps, "when" labels, `dt` terms, source notes, footer, diagram strokes). Still readable at small sizes on `bg`, `bg-alt` and `surface`.
- **Hairline** (`line`) and **Hairline Strong** (`line-2`): card borders, list dividers, timeline rails. The strong line marks interactive edges and connector rails. Both are alpha so they sit correctly on any surface. Under `prefers-contrast: more` they rise to 30% and 50%.
- **Frost** (`glass`): the translucent sticky nav background, used with `saturate(180%) blur(20px)`. It falls back to solid `bg` under `prefers-reduced-transparency`.

### Status (semantic only)
- **Pass Green** (`ok`), **Caution Amber** (`warn`), **Fault Red** (`err`), each with a soft tint. The light-theme hues are deepened so tag text on its own tint stays above 4.5:1. They appear only on verdicts: pass/warn/never tags, the verifier's completion ring, the final "ship" node of the create pipeline, and the "Check after" half marker.

### Named Rules
**The One Blue Rule.** Blue is the only identity color. If something is interactive, selected or primary, it is blue. Nothing decorative is blue.

**The Verdict-Only Rule.** Green, amber and red mean pass, warning and error. They never decorate, categorize or brand.

**The Hue-on-Tint Rule.** Status is always shown as the full hue as text on its own ~10% tint, inside a pill. It is never a saturated solid block of text on color.

**The On-Fill Rule.** Text on a solid `accent` or `ok` fill always uses `on-fill`, never a hard-coded white. The value flips per theme.

## Typography

**Display Font:** Geist (with system-ui, -apple-system, Segoe UI, Roboto)
**Body Font:** Geist
**Label/Mono Font:** Geist Mono (with ui-monospace, SF Mono, Cascadia Code, Consolas)

**Character:** A neutral grotesk set tight and semibold at display sizes and relaxed at reading sizes, like a product launch page. Mono is a material for real commands and paths, not a mood.

### Hierarchy
- **Display** (600, clamp 2.6–4.4rem, 1.02, -0.035em): one per page, the hero claim. Balanced wrapping.
- **Headline** (600, clamp 1.8–2.7rem, 1.08, -0.028em): the section claim, written as a full sentence.
- **Figure** (600, clamp 1.9–2.5rem, 1, -0.035em, tabular numerals): stat values in hairline grids. Smaller 1.5rem variants appear in performance grids.
- **Title** (600, 1.06rem, 1.3, -0.01em): card and step titles. Feature cards step up to 1.25–1.5rem with -0.02em tracking.
- **Lead** (400, clamp 1.05–1.22rem, 1.5, `ink-2`, max 42ch): the one sentence under a headline.
- **Body** (400, 1rem, 1.55): running text. Inside cards it is usually 0.86–0.92rem in `ink-2`.
- **Small** (0.84rem, `ink-2`): captions and supporting notes.
- **Label** (500, 0.7rem, 1.5): status tag text only.
- **Mono** (0.86em of context; 0.72–0.78rem inside cards): commands, file paths, MCP tool names, exit codes, milestone ids, list indexes (`01`–`10`).

### Named Rules
**The Tight-Top Rule.** Tracking tightens as size grows (-0.01em at titles, -0.035em at display). Weight stays at 600, never bold 700+ for headings.

**The Real-Mono Rule.** Monospace marks something a user could type, open or read in a terminal. Prose is never set in mono.

## Layout

A single centered column (max 1120px, 24px gutters, 16px under 600px) holds every section. Sections stack with 112px vertical padding (72px on mobile) and alternate between `bg` and `bg-alt` bands. A section head (headline plus lead) sits 48px above its figure (32px on mobile).

Inside sections, the rhythm is 12px between sibling cards in dense grids, 20px between paired feature cards, 40px between a figure and its explanatory column, and 56px before a secondary block within the same section. Grids run 2, 3, 4 or 5 columns and collapse stepwise at roughly 960, 860, 760 and 480px, down to one column. Horizontal timelines and pipelines rotate to vertical rails below 860–900px. The hero is a 1.05fr / 0.95fr split (copy / phone stage) that stacks under 900px. Its floating cards drop into the flow above and below the phone under 560px. Nav links hide under 980px, leaving the brand and the theme toggle.

**The One Figure Rule.** Each section carries one diagram or interactive figure (stat grid, two halves, timeline, layer stack, tabbed verifier, architecture SVG, pipeline, slice picker). Supporting facts go in a "Details" disclosure below it, not in more figures.

## Elevation & Depth

A hybrid: surfaces are defined mostly by hairline borders and tonal steps (`bg` to `surface` to `surface-2`), with one soft ambient shadow on cards and a deeper one on the device. Shadows are always two-layer (a tight contact shadow plus a wide, faint ambient one), and they get darker and denser in dark mode rather than disappearing.

### Shadow Vocabulary
- **Card** (`box-shadow: 0 1px 2px rgba(16,20,30,.04), 0 8px 28px rgba(16,20,30,.07)`; dark: `0 1px 2px rgba(0,0,0,.3), 0 8px 28px rgba(0,0,0,.35)`): every `.card` surface at rest.
- **Lifted** (`box-shadow: 0 2px 4px rgba(16,20,30,.05), 0 24px 60px rgba(16,20,30,.12)`; dark: `0 2px 4px rgba(0,0,0,.3), 0 24px 60px rgba(0,0,0,.5)`): the phone mockup only.
- **Selection halo** (`box-shadow: 0 0 0 3px accent-soft` with an `accent` border): selected layer, slice and highlighted tool cards.
- **Segment thumb** (`box-shadow: 0 1px 3px rgba(0,0,0,.12)`): the selected option of a segmented control.

### Named Rules
**The Ring-Not-Lift Rule.** Selection is shown by an accent border and a 3px soft halo, never by raising the shadow or scaling up the card.

**The Hairline-Grid Rule.** Grouped figures (stats, performance numbers, principles) share one rounded container whose `line` background shows through 1px gaps, drawing the dividers without separate borders.

## Shapes

Generous, continuous rounding on containers (18px cards, 12px compact tiles), full pills for anything tag-like or clickable-and-small (nav links, tags, pills, segmented controls, command chips), and small 7–10px squircles for inner tiles (number badges, code chips, example blocks). Circles are used only for timeline and pipeline nodes, status dots and the theme toggle. The device silhouette uses a 44px outer and 35px screen radius. Borders are always 1px (1.5px for outline check glyphs). The only dashed border is the package-gate funnel, which represents a filter.

## Components

### Buttons
Few conventional buttons exist; interaction lives in controls.
- **Theme toggle:** a 34px circle, `surface` fill, `line-2` border, 16px stroked sun/moon icon. Hover moves to `surface-2`, press scales to 0.92 over 0.1s ease-out.
- **Primary action (in the phone mockup):** a solid `accent` bar, 14px radius, semibold `on-fill` label. It is the only solid-blue button shape in the system.
- **Focus:** every focusable element gets a 2px `accent` outline at 3px offset with 6px radius.

### Segmented control
- A `line`-tinted pill track with 3px padding and pill options (500, 0.86rem). The selected option becomes a `surface` thumb with `ink` text and a faint thumb shadow. It presses to 0.97 and supports arrow keys.

### Chips and tags
- **Status tag:** pill, 2px 8px, 500 0.7rem, hue-on-tint (ok, warn, err, info, neutral). Used right-aligned in list rows and checklists.
- **Meta pill:** `surface` fill, `line-2` border, `ink-2` 0.8rem text, optional 6px accent dot.
- **Soft chip:** `surface-2` fill, no border, 0.74–0.8rem `ink-2` text, for example lists and metric names.
- **Command chip:** `surface` pill with `line` border, `ink-2` label next to an `ink` mono command.

### Cards / Containers
- **Corner Style:** 18px (`md`), or 12px (`sm`) for compact tiles in dense grids.
- **Background:** `surface`, with inner wells in `surface-2`.
- **Shadow Strategy:** the Card shadow (see Elevation). Compact tiles are border-only.
- **Border:** 1px `line`.
- **Internal Padding:** 18–20px compact, 22–28px standard, 32px for the two-halves feature cards (24px on mobile).

### Selectable cards (knowledge layers, roadmap slices)
- Full-width `surface` buttons with a `line` border. Hover strengthens to `line-2`, press scales to 0.98–0.99, and the selected state gets an `accent` border plus a 3px `accent-soft` halo. A 34px number tile on the left turns solid `accent` with `on-fill` text when selected. The detail panel beside or below updates live (`aria-live="polite"`) and stays sticky on desktop.

### Navigation
- A sticky 52px frosted bar with a hairline bottom border. The brand is a 22px ink squircle monogram plus a semibold wordmark. Section links are 0.84rem `ink-2` pills (6px 10px). Hover and the scroll-tracked active link get a `line` fill and `ink` text. Links are hidden under 980px.

### Details disclosure
- A hairline-topped `<details>` whose summary is a 0.88rem medium `accent` label with a 14px chevron that rotates 90° over 0.25s `cubic-bezier(.2,.8,.2,1)`. The body is an auto-fit grid (min 240px) of short paragraphs, each led by an `ink` medium phrase in otherwise `ink-2` text.

### Rails (timeline and pipeline)
- Circular nodes (46px timeline, 30px pipeline) with a `surface` fill and `line-2` border, joined by a 1px `line-2` rail. The terminal node is filled: `ink` for "done" in the session timeline, `ok` with an `on-fill` numeral for the shipped end of the create pipeline. Rails turn vertical on narrow screens.

### Phone stage (signature)
- A 258×530 device in `device` with a 10px bezel, a dynamic-island pill, and a real Flutter-like screen (app bar, filter chips, list rows, primary action). It is flanked by two floating `card`s showing actual Appstein output with mono headers. It is the page's single illustration and only ever depicts product behavior.

## Do's and Don'ts

### Do:
- **Do** use `accent` for every interactive, selected or primary meaning, and nothing else.
- **Do** show status as hue-on-tint pills (`tag-ok`, `tag-warn`, `tag-err`, `tag-info`, `tag-neutral`).
- **Do** give each section one headline sentence, one lead sentence (max 42ch), one figure, and put the rest behind "Details".
- **Do** mark selection with an accent border and a 3px `accent-soft` halo.
- **Do** set text on solid `accent` or `ok` fills in `on-fill`, so it stays legible in both themes.
- **Do** define both light and dark values for every new token and test both themes; follow the system theme until the reader chooses, then persist the choice under `appstein-theme`.
- **Do** set commands, paths, tool names and exit codes in Geist Mono, and everything else in Geist.
- **Do** keep press feedback to a 0.92–0.99 scale over 0.1s ease-out, and drop all transitions under `prefers-reduced-motion`.

### Don't:
- **Don't** reintroduce the rejected worlds: periodic-table grids, assembly-manual "build instructions" framing, terminal or wayfinding-signage theming, or dense text-first documentation layouts.
- **Don't** use green, amber or red for decoration, categories or branding.
- **Don't** add a second accent hue. The gradient squares in the phone mockup are sample app content, not palette.
- **Don't** use Albert Einstein's name, likeness or signature in any visual. The Einstein reference stays a text pun ("Apps = mc²").
- **Don't** hard-code white text on colored fills; use `on-fill`.
- **Don't** lift or scale cards on hover. Hover only strengthens the border.
- **Don't** set headings above weight 600 or with positive tracking.
