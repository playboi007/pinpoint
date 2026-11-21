# Findings

Back to the [docs index](../README.md).

<!-- MEDIA E5: findings list on the Bug zoo screen, hover a finding, Send note, 10 s -->

Findings are problems Pinpoint finds by itself. Open the list with the Findings button on the rail. The button shows a count.

## What it finds

- **Scan this screen** finds:
  - Flex overflow. It is measured, so it is found again after each what-if change.
  - Text cut at its line limit.
  - Images decoded at more than twice the pixels they show.
- **Errors** are captured as they happen. Each error shows the widget's file and line. Oversized decoration images are captured as they happen too.
- **Check accessibility** lists:
  - Actions without a label.
  - Tap targets smaller than 48x48.
  - Text under the WCAG contrast ratio (4.5:1, or 3:1 for large text).
- **Rebuild heat** is off by default. When on, it lists and tints the ten widgets that rebuilt most in the last 5 seconds.
- **Debug paint** chips turn Flutter's debug paint flags on and off.

The DETECTORS section has switches for error capture and the oversized image tracker.

## Use a finding

- Hover a finding to outline its widget.
- Press **Send note** to turn a finding into a note with a matching check. Pinpoint sends it at once.
- If a sink fails, the note stays a draft. The row then offers **Send draft**.
- **Clear** empties the list.

The agent can run the same detectors with the `scan` tool. `stress_matrix` runs scans over many what-if settings and files one draft note for each distinct problem.

## Try it

The example app's Bug zoo screen has one planted problem of each kind. See [example app](../example-app.md). The overflow shows only below 432 px wide: pick a 360 or 390 viewport in [what-if](what-if.md).
