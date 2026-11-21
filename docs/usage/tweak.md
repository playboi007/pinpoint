# Tweak

Back to the [docs index](../README.md).

<!-- MEDIA E6: tweak tab, change padding and a color, reset one, 8 s -->

The TWEAK tab edits the selected widget's values in the running app. It changes values the widget already has. Wrapping a widget in a new one (for example a `Padding`) has no render object to edit, so write that as a request in the comment.

## What you can edit

Padding, size, flex, alignment, stack, opacity, clip radius, aspect ratio, wrap gaps, image fit, text style and decoration.

- Number fields have steppers with steps of 1, 4 and 8. Arrow keys also step.
- Colors take hex values.
- Some values use menus.
- Insets have four linked fields.
- A `Container` shows its padding, size and decoration together. `Container(color:)` is read-only.

## How tweaks behave

- A tweak holds through rebuilds. The widget can show the old value for at most one frame.
- Pinpoint stops a tweak and shows a warning when the widget animates.
- Reset one tweak at a time, or all at once.
- A tweaked widget gets a dotted outline. An "N tweaks active" chip shows in every mode.

## In the note

Every note lists the active tweaks as from-and-to pairs. For each value it names the widget that made the value and the nearest widget in your source. With a screenshot, the image shows the crop before and after the tweaks.

The editors come from the same extractors as the INFO tab.
