# Info, rulers and the candidate dial

Back to the [docs index](../README.md).

<!-- MEDIA E3: info tab, rulers, Alt-hover gap, turning the candidate dial, 10 s -->

The INFO tab shows layout data of the selected widget: its size, constraints, parent and render object, and properties by widget type. It also says what the widget's subtree started in the last 5 seconds (requests and rebuilds). That line needs the [flight recorder](../flight-recorder.md); causes need `PinPoint.run`.

## Move the selection

- Arrow Up or `[` selects the next local ancestor (a widget written in your project).
- Arrow Down or `]` moves back toward the widget you picked.
- Hold Alt with an arrow to step through framework widgets too.
- Click a part of the breadcrumb to select it.

Arrow keys belong to the comment field while it has focus. Click the INFO tab first.

## The candidate dial

Many widgets can sit under one spot. The dial in the panel header steps through them. It shows one tick for each candidate. The current one is in the middle.

- Index 0 is the innermost widget. The last is the outermost. Up is outer, down is inner. The counter `N/M` counts the same way.
- Drag the dial up to select the inner widget below. Drag down to select an outer one.
- Scroll the wheel or trackpad over the dial: one candidate for each step.
- Click the upper half for the outer widget. Click the lower half for the inner one.
- Hover shows the neighbours, for example `↑ Positioned  ↓ Semantics`.

## Rulers

Rulers measure from the selected widget to its nearest local ancestor. Hold Alt and hover another widget to measure the gap between the two.

## Source location

A small folder button stands for the source location. Click it. A popover shows the short path and the line, with a Copy button. Esc or a click outside closes it.
