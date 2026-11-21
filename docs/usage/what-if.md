# What-if

Back to the [docs index](../README.md).

<!-- MEDIA E4: what-if panel, narrow viewport, text scale 2x, RTL, reset, 10 s -->

What-if changes what the app inherits. It does not touch app code. Open it with the What-if button on the rail. If Pinpoint is idle, the button starts picking first.

## Switches

| Switch | What it does |
| --- | --- |
| Viewport | Sets the app size. Pick a preset, rotate, or set a free width and height. |
| Text scale | Sets `MediaQuery.textScaler`. |
| Bold text | Sets `MediaQuery.boldText`. |
| Safe area | Sets `MediaQuery.padding` and `viewPadding`: system, none, or set values. |
| Fake keyboard | Adds a fake on-screen keyboard (`viewInsets.bottom`). |
| Direction | Sets the `Directionality`: LTR or RTL. Strings stay in the current locale. |
| Theme | Uses the app's light or dark theme. With `PinPointConfig.themeVariants`, lists your named themes instead. |
| Color scheme | Makes a Material 3 color scheme from a seed color. |
| Platform | Sets `debugDefaultTargetPlatformOverride`. |
| Slow motion | Sets `timeDilation`. |

While any switch is on, a bar stays on screen. It names the switch and has a one-click reset. **Reset all** clears every switch. Every note records the active switches in its `environment`. The agent can set the same switches with `set_environment` and clear them with `reset_environment`.

## What the switches cannot do

- Code that reads `View.of(context).physicalSize` or `PlatformDispatcher` directly sees the real window, not the viewport. That is a finding about the app: read `MediaQuery` instead.
- The device pixel ratio cannot be faked. A 390-wide viewport on a 1x screen renders at 1x.
- The color scheme switch is Material 3 only. In a Material 2 theme, `copyWith(colorScheme:)` does not re-derive the component themes, so the switch is off there.
- The platform switch rebuilds the whole app, like hot reload, and clears the selection. Outside web, a switch between iOS or macOS and another platform also mounts the widgets above the Navigator again. The routes keep their state. Pass your own `PinPointController` to keep the switches too.

## Related

- [Findings](findings.md) are measured again after each switch change.
- `stress_matrix` (agent tool) tries widths, text scales, directions and brightness. See [agent tools](../agent-tools.md).
