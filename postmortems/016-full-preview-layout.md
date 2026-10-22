# 016 - Delegate full preview layout to Emacs

_Date: 2026-10-22. Status: Implemented in uncommitted work based on `78552b6`._

## Background

The inline preview flattened hypothesis whitespace and clipped the result to a
single line, bounded by `vox-preview-width` and the space after the insertion
marker. The requested behavior is to render the complete preview and let Emacs
handle display wrapping, rather than introduce a scrolling preview window or a
configurable number of retained lines.

## Decision

Keep the existing read-only overlay in [vox-ui.el](../vox-ui.el), remove its
width calculation and clipping, and remove the public `vox-preview-width`
option. Continue normalizing newlines, carriage returns, and tabs to spaces.

## Why

Emacs already lays out overlay strings. Delegating layout avoids a second
wrapping implementation and does not require a new display surface or editing
workflow. A width option whose sole purpose was clipping no longer has an
effect, so removing it makes the configuration contract explicit.

## Consequence

The overlay carries the complete hypothesis while preview enablement and
throttling remain unchanged. It still adds no buffer text, does not move point,
and leaves authoritative final insertion and undo semantics intact. Users can
remove obsolete `vox-preview-width` settings; no replacement option is needed.
The [configuration guide](../docs/customization.md) describes the current
contract. [Sink regressions](../test/vox-test-core.el) check complete payloads,
whitespace normalization, and captured markers under narrowing; these are
offline checks, not provider acceptance or exhaustive redisplay tests.

## Known limitations

Vox no longer truncates the string itself; Emacs window settings still control
wrapping, clipping, and visibility. A long preview can push following text down
or extend beyond the visible window. This decision adds no scrolling or editing
UI and does not claim to fix the separately reported short-preview disappearance.
