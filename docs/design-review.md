# Cross-page designer review — 2026-09-09

A separate product-design agent reviewed the page implementations and the recording-detail preview before implementation. Its feedback was to retain the current palette and restrained corner radii, and correct task hierarchy rather than add decorative components.

## Accepted changes

- Recording list: independently scrolling history, fixed bottom capture controls, timestamp metadata, honest empty/loading/error states.
- Practice: root-level navigation; separate prompt, reference and attempt; fixed controls that change from speaking/reveal to retry/self-assessment.
- Settings: preserve explicit Save, keep language choices available, replace the mode segmented control with plain options, expand one provider form at a time, reveal Action Button instructions on demand, and show progress at the active group.
- Library: compact clearable search, a simple due-review row, flat expression entries, and separate empty-library/search-no-match/read-error states.
- Speak: lighter source editing, one emphasized translation area, fixed microphone, and readable status under large text.
- Detail: retain the new player/transcript layout; keep selection reachable on narrow screens and give playable passages explicit button semantics.

The final review uses rendered example-data pages, including narrow/large-text layouts. No provider credentials or real audio are used for design previews.

## Second designer review

The designer inspected all nine rendered Chinese dark-mode previews and approved the overall direction. One remaining finding was inconsistent spacing between English and Chinese in expression rows. This was corrected by using a single vertical layout with an explicit 8-point gap, rather than ListTile title/subtitle baselines.

## Validation and previews

Fourteen focused page tests passed, including 320-point width with 200% text for practice, recording controls and settings. Static analysis reported no issues. Previews below use synthetic example data and actual Flutter widgets; they are not physical-device captures. No iOS rebuild or installation was performed for these layout changes.

- [Speak, empty](screenshots/design-review/speak-empty.png) · [Speak, translated](screenshots/design-review/speak-result.png)
- [Expression library](screenshots/design-review/library.png)
- [Practice, prompt](screenshots/design-review/practice-prompt.png) · [Practice, reference](screenshots/design-review/practice-reference.png)
- [Recordings](screenshots/design-review/recordings.png) · [Active recording](screenshots/design-review/recordings-active.png)
- [Settings](screenshots/design-review/settings.png) · [Expanded connection](screenshots/design-review/settings-connection.png)
