import 'construction_assets.dart';
import 'construction_boxes.dart';
import 'construction_crew.dart';
import 'construction_layout.dart';

/// The HTML and CSS of the construction sites.
///
/// Plain strings and numbers, no Flutter and no `dart:html`: the web stage
/// puts them in the page, and a test or a preview can read them anywhere.
///
/// Everything moves by CSS keyframes (engineering rule 2: no Flutter frames
/// while the agent works). Nothing blurs: shadows are hard offsets.
///
/// A site has three phases, all driven by animation delays that start when
/// the site's element is put in the page:
///
/// * Planning, from 0 to [planMillis]: the planners, at the right, and the
///   blueprint drawn as if it were measured.
/// * Building, from [planMillis] until the class [revealClass] is set: the
///   blueprint breaks, the builder and the wheelbarrow walk in from the left
///   and repair it box by box, then a slow loop goes on. On a site with room
///   the wheelbarrow worker hands light blocks to the stacker, who flies up
///   with booster shoes and repairs the boxes in the upper half; their
///   keyframes are made per site (see [siteCss]).
/// * Finishing and reveal, from the moment the class [revealClass] is set,
///   for [revealMillis]: the boxes snap into place, the painter rolls across,
///   the "done" worker turns to the viewer, the tape snaps, the cover peels
///   and the picture of the new widget bounces.
abstract final class ConstructionMarkup {
  /// The `id` of the one root element.
  static const String rootId = 'pinpoint-construction';

  /// The `id` of the one `<style>` element.
  static const String styleId = 'pinpoint-construction-style';

  /// The asset folder, inside the package.
  static const String assetFolder = 'packages/pinpoint/assets/construction';

  /// The names of the assets in use, as [siteHtml] asks for them.
  static List<String> get assetNames => ConstructionAssets.names;

  /// The path of the file [file] for `ui_web.assetManager.getAssetUrl`.
  static String assetPath(String file) => '$assetFolder/$file.webp';

  /// The class of the root while motion is reduced.
  static const String reducedClass = 'ppc-reduced';

  /// The class a site has while it plays its finish.
  static const String revealClass = 'ppc-reveal';

  /// The class a finish has when it came before the builders walked in.
  static const String earlyClass = 'ppc-early';

  /// The class a site has while it fades away.
  static const String outClass = 'ppc-out';

  /// How long planning takes, in milliseconds.
  static const int planMillis = 2500;

  /// How long the finish takes, in milliseconds: the finishing part first
  /// (0.8 s), then the reveal. After this the site is removed.
  static const int revealMillis = 2250;

  /// How long a fade takes, in milliseconds.
  static const int fadeMillis = 180;

  /// The label on the tape.
  static const String label = 'UNDER PROGRESS';

  /// The `class` text of a site laid out as [layout].
  static String siteClass(
    ConstructionLayout layout, {
    bool revealing = false,
    bool early = false,
    String? key,
  }) => [
    'ppc-site',
    ?(key == null ? null : 'ppc-$key'),
    ...layout.classes,
    if (revealing) revealClass,
    if (revealing && early) earlyClass,
  ].join(' ');

  /// The `style` text of a site: [left] and [top] are CSS pixels in the
  /// page. [landing] is where the stacker is, from his spot, when the finish
  /// begins: he lands from there.
  static String siteStyle(
    ConstructionLayout layout, {
    required double left,
    required double top,
    (double, double)? landing,
  }) =>
      'left:${left.toStringAsFixed(2)}px;top:${top.toStringAsFixed(2)}px;'
      'width:${layout.width.toStringAsFixed(2)}px;'
      'height:${layout.height.toStringAsFixed(2)}px;${layout.variables}'
      '${landing == null ? '' : ';--ax:${_n(landing.$1)}px;--ay:${_n(landing.$2)}px'}';

  /// The per-site CSS of the site whose class is `ppc-$key`: the keyframes
  /// of the stacker, the wheelbarrow worker and the block, made from the
  /// layout and the blueprint (see [ConstructionCrew.css]). Empty for a site
  /// without the stacker.
  static String siteCss(
    ConstructionLayout layout,
    List<ConstructionBox> boxes,
    String key,
  ) => ConstructionCrew.of(layout, boxes)?.css(key, rootId) ?? '';

  static String _attr(String url) => url
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;');

  static String _n(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  /// The blueprint of the widget: one element per box, then the line that
  /// measures. [seed] comes from the note id (see [ConstructionBoxes.seedOf]).
  static String boxesHtml(
    int seed,
    List<ConstructionBox> boxes, {
    ConstructionCrew? crew,
  }) {
    final out = StringBuffer();
    for (final p in ConstructionBoxes.plan(seed, boxes, crew: crew)) {
      final slipClass = p.stackerSlip != null
          ? ' ppc-ss ppc-ss${p.stackerSlip}'
          : p.slipDelay != null
          ? ' ppc-sl'
          : '';
      final b = p.box;
      final style =
          'left:${_n(b.left)}px;top:${_n(b.top)}px;'
          'width:${_n(b.width)}px;height:${_n(b.height)}px;'
          '--dx:${_n(p.dx)}px;--dy:${_n(p.dy)}px;--dr:${_n(p.degrees)}deg;'
          '--pd:${_n(p.drawDelay)}s;--pd2:${_n(p.drawDelay + 0.25)}s;'
          '--bd:${_n(p.breakDelay)}s;--rd:${_n(p.repairDelay)}s'
          '${p.slipDelay == null ? '' : ';--sl:${_n(p.slipDelay!)}s'}';
      out.write(
        '<div class="ppc-box" style="$style"><div class="ppc-fix">'
        '<div class="ppc-slip$slipClass">'
        '${p.dimX ? '<i class="ppc-dx"></i>' : ''}'
        '${p.dimY ? '<i class="ppc-dy"></i>' : ''}'
        '</div></div></div>',
      );
    }
    out.write('<i class="ppc-measure"></i>');
    return out.toString();
  }

  /// The inside of a site. Every part is there; the site's classes pick
  /// which show. [urls] maps each of [assetNames] to its URL. The blueprint
  /// is [boxes], broken the way the note [id] says; with the site's [layout]
  /// the stacker takes the boxes in the upper half (see [ConstructionCrew]).
  static String siteHtml(
    Map<String, String> urls, {
    String id = '',
    List<ConstructionBox> boxes = const [],
    ConstructionLayout? layout,
  }) {
    // [fixed]: the picture has its own size in px (the CSS places it).
    String img(String cls, String name, {bool fixed = false}) {
      final asset = ConstructionAssets.of(name);
      final size = fixed
          ? ' style="width:${_n(asset.width)}px;height:${_n(asset.height)}px"'
          : '';
      return '<img class="$cls" alt="" '
          'draggable="false"$size src="${_attr(urls[name] ?? '')}">';
    }

    String frames(String a, String b, String an, String bn, String cls) =>
        '${img('$cls $a', an, fixed: true)}${img('$cls $b', bn, fixed: true)}';

    // A pose of the stacker: on the canvas, at the bottom, in the middle.
    String pose(String cls, String name) {
      final asset = ConstructionAssets.of(name);
      return '<img class="ppc-sp $cls" alt="" draggable="false" '
          'style="width:${_n(asset.width)}px;height:${_n(asset.height)}px;'
          'margin-left:${_n(-asset.width / 2)}px" '
          'src="${_attr(urls[name] ?? '')}">';
    }

    const art = ConstructionAssets.stackerArt;
    final crew = layout == null ? null : ConstructionCrew.of(layout, boxes);
    final tape =
        '<div class="ppc-tape"><span class="ppc-label">$label</span></div>';
    return '<div class="ppc-cover"><div class="ppc-bp">'
        '${boxesHtml(ConstructionBoxes.seedOf(id), boxes, crew: crew)}</div>'
        '<i class="ppc-paint"></i></div>'
        '<div class="ppc-w ppc-w-cones">'
        '${img('ppc-cone ppc-cone-l', 'cone')}'
        '${img('ppc-cone ppc-cone-r', 'cone')}</div>'
        '<div class="ppc-w ppc-w-plan">'
        '<div class="ppc-pl ppc-pl-a"><div class="ppc-sc">'
        '${frames('ppc-fa', 'ppc-fb', 'planner_point_a', 'planner_point_b', 'ppc-pi')}'
        '</div></div>'
        '<div class="ppc-pl ppc-pl-b"><div class="ppc-sc">'
        '${frames('ppc-fa', 'ppc-fb', 'planner_read_a', 'planner_read_b', 'ppc-pi')}'
        '</div></div></div>'
        '<div class="ppc-w ppc-w-hammer"><div class="ppc-hammer">'
        '<div class="ppc-hin"><div class="ppc-dip">'
        '${frames('ppc-ha', 'ppc-hb', 'builder_a', 'builder_b', 'ppc-body')}'
        '<i class="ppc-dust"></i></div></div></div></div>'
        '<div class="ppc-w ppc-w-barrow"><div class="ppc-barrow">'
        '<div class="ppc-bwalk"><div class="ppc-flip">'
        '${img('ppc-wa', 'walk_a')}${img('ppc-wb', 'walk_b')}'
        '</div></div></div></div>'
        '<div class="ppc-w ppc-w-stack"><div class="ppc-lnd"><div class="ppc-stk">'
        '<div class="ppc-sk">'
        '${pose('ppc-sp-st', ConstructionAssets.stackerStand)}'
        '<div class="ppc-sfly"><div class="ppc-sbob">'
        '${pose('ppc-sfa', ConstructionAssets.stackerFlyA)}'
        '${pose('ppc-sfb', ConstructionAssets.stackerFlyB)}'
        '</div></div>'
        '${pose('ppc-sp-pl', ConstructionAssets.stackerPlace)}'
        '${art ? '' : '<div class="ppc-sfl"><div class="ppc-sbob">'
                  '<i class="ppc-fl ppc-fl-a"></i><i class="ppc-fl ppc-fl-b"></i>'
                  '</div></div><div class="ppc-scb"><div class="ppc-sbob">'
                  '<div class="ppc-blk"></div></div></div>'}'
        '</div></div></div>'
        '<div class="ppc-thrown"><div class="ppc-tb">'
        '${art ? img('ppc-blkimg', 'block') : '<div class="ppc-blk"></div>'}'
        '</div></div></div>'
        '<div class="ppc-w ppc-w-painter"><div class="ppc-painter">'
        '${img('ppc-pa', 'painter_a')}${img('ppc-pb', 'painter_b')}'
        '</div></div>'
        '<div class="ppc-half ppc-half-l">$tape</div>'
        '<div class="ppc-half ppc-half-r">$tape</div>'
        '<div class="ppc-done-box">${img('ppc-done', 'done')}</div>';
  }

  /// The picture of the widget that bounces in at the end.
  static String shotHtml(String url) =>
      '<div class="ppc-shotbox"><img alt="" draggable="false" '
      'src="${_attr(url)}"></div>';

  /// The root's custom properties, from the palette's colours.
  static String rootVariables({
    required String paper,
    required String ink,
    required String accent,
    required String rule,
    required String shadow,
    required String hatch,
  }) =>
      '--ppc-paper:$paper;--ppc-ink:$ink;--ppc-accent:$accent;'
      '--ppc-rule:$rule;--ppc-shadow:$shadow;--ppc-hatch:$hatch;';

  /// All the CSS: rules and keyframes. One `<style>` element holds it.
  ///
  /// The delays in it are the [ConstructionTimeline] in seconds: planning
  /// ends at 2.5 s, the builder walks in until 3.6 s and then hits every
  /// 0.6 s, the wheelbarrow walks in until 4.1 s. Per-box delays are inline
  /// custom properties (see [boxesHtml]).
  static const String css =
      '''
#$rootId{position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;pointer-events:none;overflow:visible}
#$rootId .ppc-site{position:absolute;box-sizing:border-box;isolation:isolate;pointer-events:none;animation:ppc-in .16s linear both}
#$rootId .ppc-site *{box-sizing:border-box;pointer-events:none}
#$rootId .ppc-site.ppc-out{animation:ppc-out .18s linear forwards}
#$rootId img{display:block;position:absolute;max-width:none;user-select:none;-webkit-user-drag:none}
#$rootId .ppc-cover{position:absolute;left:0;top:0;right:0;bottom:0;z-index:1;overflow:hidden;border:1px solid var(--ppc-ink);background:repeating-linear-gradient(45deg,transparent 0,transparent 5px,var(--ppc-hatch) 5px,var(--ppc-hatch) 6px),var(--ppc-paper)}
#$rootId .ppc-bp{position:absolute;left:0;top:0;right:0;bottom:0}
#$rootId .ppc-bare .ppc-bp,#$rootId .ppc-bare .ppc-paint{display:none}
#$rootId .ppc-box{position:absolute;animation:ppc-break .35s ease-out var(--bd) both}
#$rootId .ppc-fix{position:absolute;left:0;top:0;right:0;bottom:0;animation:ppc-fix .55s linear var(--rd) both}
#$rootId .ppc-slip{position:absolute;left:0;top:0;right:0;bottom:0;border:1px solid var(--ppc-ink);animation:ppc-draw .3s linear var(--pd) both}
#$rootId .ppc-slip.ppc-sl{animation:ppc-draw .3s linear var(--pd) both,ppc-slip 12s linear var(--sl) infinite}
#$rootId .ppc-slip:before{content:"";position:absolute;left:0;top:0;right:0;bottom:0;background:var(--ppc-accent);opacity:.1}
#$rootId .ppc-dx{position:absolute;left:12px;right:3px;top:3px;height:5px;border-left:1px solid var(--ppc-ink);border-right:1px solid var(--ppc-ink);transform-origin:0 50%;animation:ppc-dimx .5s linear var(--pd2) both}
#$rootId .ppc-dx:after{content:"";position:absolute;left:0;right:0;top:2px;height:1px;background:var(--ppc-ink)}
#$rootId .ppc-dy{position:absolute;left:3px;top:12px;bottom:3px;width:5px;border-top:1px solid var(--ppc-ink);border-bottom:1px solid var(--ppc-ink);transform-origin:50% 0;animation:ppc-dimy .5s linear var(--pd2) both}
#$rootId .ppc-dy:after{content:"";position:absolute;top:0;bottom:0;left:2px;width:1px;background:var(--ppc-ink)}
#$rootId .ppc-measure{position:absolute;left:0;top:0;bottom:0;width:0;border-left:1px dashed var(--ppc-accent);animation:ppc-sweep 2s linear .25s both}
#$rootId .ppc-paint{position:absolute;left:0;top:0;right:0;bottom:0;transform:scaleX(0);transform-origin:0 50%;border-right:2px solid var(--ppc-ink)}
#$rootId .ppc-paint:before{content:"";position:absolute;left:0;top:0;right:0;bottom:0;background:var(--ppc-accent);opacity:.16}
#$rootId .ppc-w{position:absolute;left:0;top:0;right:0;bottom:0;z-index:2;overflow:hidden}
#$rootId .ppc-w-painter{z-index:3}
#$rootId .ppc-bare .ppc-w,#$rootId .ppc-bare .ppc-done-box,#$rootId .ppc-w-cones,#$rootId .ppc-w-hammer,#$rootId .ppc-w-barrow,#$rootId .ppc-w-stack,#$rootId .ppc-w-painter,#$rootId .ppc-pl-a{display:none}
#$rootId .ppc-cones .ppc-w-cones,#$rootId .ppc-hammer-on .ppc-w-hammer,#$rootId .ppc-barrow-on .ppc-w-barrow,#$rootId .ppc-stacker-on .ppc-w-stack,#$rootId .ppc-plan2 .ppc-pl-a{display:block}
#$rootId .ppc-painter-on.ppc-reveal .ppc-w-painter{display:block}
#$rootId .ppc-early .ppc-w-hammer,#$rootId .ppc-early .ppc-w-barrow,#$rootId .ppc-early .ppc-w-stack{display:none}
#$rootId .ppc-cone{bottom:2px;width:calc(${ConstructionAssets.coneWidth}px*var(--sc));height:calc(${ConstructionAssets.coneHeight}px*var(--sc))}
#$rootId .ppc-cone-l{left:4px}
#$rootId .ppc-cone-r{left:var(--cl2)}
#$rootId .ppc-pl{position:absolute;bottom:2px;width:calc(${ConstructionAssets.plannerPointWidth}px*var(--spl));height:calc(${ConstructionAssets.plannerPointHeight}px*var(--spl))}
#$rootId .ppc-pl-a{right:var(--pa)}
#$rootId .ppc-pl-b{right:var(--pb)}
#$rootId .ppc-sc{position:absolute;left:0;bottom:0;width:${ConstructionAssets.plannerPointWidth}px;height:${ConstructionAssets.plannerPointHeight}px;transform:scale(var(--spl));transform-origin:0 100%}
#$rootId .ppc-sc img{left:0;bottom:0}
#$rootId .ppc-fa{animation:ppc-la .9s step-end infinite}
#$rootId .ppc-fb{opacity:0;animation:ppc-lb .9s step-end infinite}
#$rootId .ppc-pl-a .ppc-fa,#$rootId .ppc-pl-a .ppc-fb{animation-delay:-.4s}
#$rootId .ppc-hammer-on .ppc-pl{animation:ppc-pleave .7s cubic-bezier(.5,0,.8,.5) 2.5s both}
#$rootId .ppc-hammer{position:absolute;left:var(--hl);bottom:2px;width:${ConstructionAssets.builderWidth}px;height:${ConstructionAssets.builderHeight}px;transform:scale(var(--sh));transform-origin:0 100%}
#$rootId .ppc-hin{position:absolute;left:0;top:0;width:${ConstructionAssets.builderWidth}px;height:${ConstructionAssets.builderHeight}px;animation:ppc-hin 1.1s cubic-bezier(.3,.5,.5,1) 2.5s both}
#$rootId .ppc-dip{position:absolute;left:0;top:0;width:${ConstructionAssets.builderWidth}px;height:${ConstructionAssets.builderHeight}px;animation:ppc-bob .275s step-end 2.5s 4,ppc-dip .6s linear 3.6s infinite}
#$rootId .ppc-body{left:0;top:0;z-index:2}
#$rootId .ppc-ha{animation:ppc-ha .6s step-end 3.6s infinite}
#$rootId .ppc-hb{opacity:0;animation:ppc-hb .6s step-end 3.6s infinite}
#$rootId .ppc-dust{position:absolute;left:114px;top:49px;width:7px;height:7px;z-index:3;opacity:0;border:1px solid var(--ppc-ink);background:var(--ppc-paper);animation:ppc-dust .6s linear 3.6s infinite}
#$rootId .ppc-barrow{position:absolute;left:var(--bl);bottom:2px;width:calc(${ConstructionAssets.walkWidth}px*var(--sb));height:calc(${ConstructionAssets.walkHeight}px*var(--sb));animation:ppc-bin 1.6s linear 2.5s both}
#$rootId .ppc-bwalk{position:absolute;left:0;top:0;right:0;bottom:0;animation:ppc-walk var(--wd) linear 4.1s infinite}
#$rootId .ppc-flip{position:absolute;left:0;top:0;right:0;bottom:0;animation:ppc-turn var(--wd) step-end 4.1s infinite}
#$rootId .ppc-flip img,#$rootId .ppc-painter img{left:0;top:0;width:100%;height:100%}
#$rootId .ppc-wa{animation:ppc-la .5s step-end 2.5s infinite}
#$rootId .ppc-wb{opacity:0;animation:ppc-lb .5s step-end 2.5s infinite}
#$rootId .ppc-w-stack{z-index:3}
#$rootId .ppc-lnd{position:absolute;left:var(--kl);bottom:2px;width:calc(${ConstructionAssets.stackerWidth}px*var(--ss));height:calc(${ConstructionAssets.stackerHeight}px*var(--ss))}
#$rootId .ppc-stk{position:absolute;left:0;top:0;right:0;bottom:0}
#$rootId .ppc-sk{position:absolute;left:0;bottom:0;width:${ConstructionAssets.stackerWidth}px;height:${ConstructionAssets.stackerHeight}px;transform:scale(var(--ss));transform-origin:0 100%}
#$rootId .ppc-sfly,#$rootId .ppc-sfl,#$rootId .ppc-scb,#$rootId .ppc-sbob{position:absolute;left:0;top:0;width:${ConstructionAssets.stackerWidth}px;height:${ConstructionAssets.stackerHeight}px}
#$rootId .ppc-sp{left:50%;bottom:0}
#$rootId .ppc-sp-st{opacity:1}
#$rootId .ppc-sfly,#$rootId .ppc-sp-pl,#$rootId .ppc-sfl,#$rootId .ppc-scb,#$rootId .ppc-thrown{opacity:0}
#$rootId .ppc-sbob{animation:ppc-sbob .45s ease-in-out infinite alternate}
#$rootId .ppc-sfa{animation:ppc-la .16s step-end infinite}
#$rootId .ppc-sfb{opacity:0;animation:ppc-lb .16s step-end infinite}
#$rootId .ppc-fl{position:absolute;top:130px;width:0;height:0;border-left:6px solid transparent;border-right:6px solid transparent;border-top:22px solid var(--ppc-accent);transform-origin:50% 0;animation:ppc-flick .12s step-end infinite}
#$rootId .ppc-fl:after{content:"";position:absolute;left:-4px;top:-22px;border-left:4px solid transparent;border-right:4px solid transparent;border-top:13px solid #ffc933}
#$rootId .ppc-fl-a{left:21px}
#$rootId .ppc-fl-b{left:47px;animation-delay:-.06s}
#$rootId .ppc-blk{position:absolute;left:0;top:0;right:0;bottom:0;border:1px solid var(--ppc-ink);background:var(--ppc-paper);box-shadow:2px 2px 0 var(--ppc-shadow)}
#$rootId .ppc-blk:before{content:"";position:absolute;left:25%;right:25%;top:25%;bottom:25%;background:repeating-linear-gradient(0deg,var(--ppc-ink) 0,var(--ppc-ink) 1px,transparent 1px,transparent 4px)}
#$rootId .ppc-scb .ppc-blk{left:${(ConstructionAssets.stackerWidth - ConstructionAssets.blockSize) / 2}px;top:${ConstructionAssets.stackerHeight * ConstructionAssets.stackerBlockBottom - ConstructionAssets.blockSize}px;right:auto;bottom:auto;width:${ConstructionAssets.blockSize}px;height:${ConstructionAssets.blockSize}px;border-width:calc(1px/var(--ss));box-shadow:3px 3px 0 var(--ppc-shadow)}
#$rootId .ppc-thrown{position:absolute;left:0;top:0;width:calc(${ConstructionAssets.blockSize}px*var(--ss));height:calc(${ConstructionAssets.blockSize}px*var(--ss))}
#$rootId .ppc-tb{position:absolute;left:0;top:0;right:0;bottom:0}
#$rootId .ppc-tb img{left:0;top:0;width:100%;height:100%}
#$rootId .ppc-painter{position:absolute;left:0;bottom:2px;width:calc(${ConstructionAssets.painterWidth}px*var(--sp));height:calc(${ConstructionAssets.painterHeight}px*var(--sp))}
#$rootId .ppc-pa{animation:ppc-la .3s step-end infinite}
#$rootId .ppc-pb{opacity:0;animation:ppc-lb .3s step-end infinite}
#$rootId .ppc-half{position:absolute;left:-4px;right:-4px;top:var(--tt);height:var(--th);z-index:5}
#$rootId .ppc-half-l{clip-path:inset(-4px 50% -4px -4px);transform-origin:0 50%}
#$rootId .ppc-half-r{clip-path:inset(-4px -4px -4px 50%);transform-origin:100% 50%}
#$rootId .ppc-tape{position:absolute;left:0;top:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center;overflow:hidden;border:1px solid var(--ppc-ink);box-shadow:2px 2px 0 var(--ppc-shadow);background:repeating-linear-gradient(-45deg,var(--ppc-accent) 0,var(--ppc-accent) 6px,var(--ppc-paper) 6px,var(--ppc-paper) 12px)}
#$rootId .ppc-label{padding:0 4px;border:1px solid var(--ppc-ink);background:var(--ppc-paper);color:var(--ppc-ink);font:500 var(--tf)/1 "packages/pinpoint/RobotoMono","RobotoMono",ui-monospace,monospace;letter-spacing:.08em;white-space:nowrap;text-transform:uppercase}
#$rootId .ppc-done-box{position:absolute;left:var(--dl);bottom:2px;z-index:4;display:none}
#$rootId .ppc-reveal .ppc-done-box{display:block}
#$rootId .ppc-done{position:relative;height:calc(${ConstructionAssets.doneHeight}px*var(--sd));width:calc(${ConstructionAssets.doneWidth}px*var(--sd));opacity:0;transform-origin:50% 100%}
#$rootId .ppc-shotbox{position:absolute;left:0;top:0;right:0;bottom:0;z-index:7;outline:2px solid var(--ppc-accent);background:var(--ppc-paper);animation:ppc-bounce .7s ease-in-out 1.5s both}
#$rootId .ppc-shotbox img{left:0;top:0;width:100%;height:100%}
#$rootId .ppc-reveal .ppc-box{animation:ppc-snap .3s ease-out both}
#$rootId .ppc-reveal .ppc-fix,#$rootId .ppc-reveal .ppc-slip,#$rootId .ppc-reveal .ppc-measure{animation:none}
#$rootId .ppc-reveal .ppc-measure{display:none}
#$rootId .ppc-reveal .ppc-paint{animation:ppc-paint .8s cubic-bezier(.45,0,.55,1) both}
#$rootId .ppc-reveal .ppc-dip,#$rootId .ppc-reveal .ppc-dust,#$rootId .ppc-reveal .ppc-ha,#$rootId .ppc-reveal .ppc-hb{animation:none}
#$rootId .ppc-reveal .ppc-bwalk,#$rootId .ppc-reveal .ppc-flip,#$rootId .ppc-reveal .ppc-wa,#$rootId .ppc-reveal .ppc-wb,#$rootId .ppc-reveal .ppc-barrow{animation-play-state:paused}
#$rootId .ppc-reveal .ppc-painter{animation:ppc-prun .8s cubic-bezier(.45,0,.55,1) both}
#$rootId .ppc-reveal .ppc-lnd{animation:ppc-land .3s cubic-bezier(.5,0,.9,.6) both}
#$rootId .ppc-reveal .ppc-w{animation:ppc-hop .4s cubic-bezier(.3,.6,.5,1) .7s forwards}
#$rootId .ppc-reveal .ppc-w-painter{animation-delay:.95s}
#$rootId .ppc-reveal .ppc-done{animation:ppc-pop 1.2s linear .7s forwards}
#$rootId .ppc-reveal .ppc-half-l{animation:ppc-fall-l .55s cubic-bezier(.5,0,.9,.6) .8s forwards}
#$rootId .ppc-reveal .ppc-half-r{animation:ppc-fall-r .55s cubic-bezier(.5,0,.9,.6) .8s forwards}
#$rootId .ppc-reveal .ppc-cover{animation:ppc-peel .45s cubic-bezier(.6,0,.4,1) 1.2s forwards}
@keyframes ppc-in{from{opacity:0}to{opacity:1}}
@keyframes ppc-out{from{opacity:1}to{opacity:0}}
@keyframes ppc-draw{from{opacity:0}to{opacity:1}}
@keyframes ppc-dimx{from{transform:scaleX(0)}to{transform:scaleX(1)}}
@keyframes ppc-dimy{from{transform:scaleY(0)}to{transform:scaleY(1)}}
@keyframes ppc-sweep{0%{opacity:0;transform:translateX(0)}6%{opacity:1}94%{opacity:1}100%{opacity:0;transform:translateX(var(--sw))}}
@keyframes ppc-break{from{transform:none}to{transform:translate(var(--dx),var(--dy)) rotate(var(--dr))}}
@keyframes ppc-fix{0%{transform:none;animation-timing-function:cubic-bezier(.5,0,.9,.5)}60%{transform:rotate(calc(-1*var(--dr))) translate(calc(-1*var(--dx)),calc(-1*var(--dy)));animation-timing-function:ease-out}72%{transform:rotate(calc(-1.12*var(--dr))) translate(calc(-1.12*var(--dx)),calc(-1.12*var(--dy)));animation-timing-function:ease-in-out}86%{transform:rotate(calc(-.97*var(--dr))) translate(calc(-.97*var(--dx)),calc(-.97*var(--dy)))}100%{transform:rotate(calc(-1*var(--dr))) translate(calc(-1*var(--dx)),calc(-1*var(--dy)))}}
@keyframes ppc-slip{0%{transform:none;animation-timing-function:ease-out}2%{transform:translate(calc(.4*var(--dx)),calc(.4*var(--dy))) rotate(calc(.5*var(--dr)))}7%{transform:translate(calc(.4*var(--dx)),calc(.4*var(--dy))) rotate(calc(.5*var(--dr)));animation-timing-function:cubic-bezier(.5,0,.9,.5)}8.5%{transform:translate(calc(-.06*var(--dx)),calc(-.06*var(--dy))) rotate(calc(-.1*var(--dr)));animation-timing-function:ease-in-out}10%{transform:none}100%{transform:none}}
@keyframes ppc-snap{from{transform:scale(1.05)}to{transform:none}}
@keyframes ppc-pleave{from{transform:none}to{transform:translateX(var(--pout))}}
@keyframes ppc-hin{from{transform:translateX(calc(-1*var(--hin)/var(--sh)))}to{transform:none}}
@keyframes ppc-bin{from{transform:translateX(calc(-1*var(--bin)))}to{transform:none}}
@keyframes ppc-bob{0%{transform:translateY(0)}50%{transform:translateY(-2px)}}
@keyframes ppc-sbob{from{transform:translateY(0)}to{transform:translateY(-3px)}}
@keyframes ppc-flick{0%{transform:scaleY(1)}50%{transform:scaleY(.6)}}
@keyframes ppc-land{from{transform:translate(var(--ax,0px),var(--ay,0px))}to{transform:none}}
@keyframes ppc-ha{0%{opacity:1}25%{opacity:0}40%{opacity:1}}
@keyframes ppc-hb{0%{opacity:0}25%{opacity:1}40%{opacity:0}}
@keyframes ppc-dip{0%,22%{transform:translateY(0)}25%{transform:translateY(2px)}36%{transform:translateY(0)}100%{transform:translateY(0)}}
@keyframes ppc-dust{0%,24%{opacity:0;transform:translate(0,0) scale(.4)}25%{opacity:1;transform:translate(0,0) scale(.6)}45%{opacity:0;transform:translate(6px,-8px) scale(1.3)}100%{opacity:0;transform:translate(6px,-8px) scale(1.3)}}
@keyframes ppc-walk{0%{transform:translateX(0)}46%{transform:translateX(var(--run))}50%{transform:translateX(var(--run))}96%{transform:translateX(0)}100%{transform:translateX(0)}}
@keyframes ppc-turn{0%{transform:scaleX(1)}48%{transform:scaleX(-1)}98%{transform:scaleX(1)}}
@keyframes ppc-la{0%{opacity:1}50%{opacity:0}}
@keyframes ppc-lb{0%{opacity:0}50%{opacity:1}}
@keyframes ppc-prun{from{transform:translateX(calc(-1*var(--ppw)))}to{transform:translateX(var(--prun))}}
@keyframes ppc-paint{from{transform:scaleX(0)}to{transform:scaleX(1)}}
@keyframes ppc-hop{0%{transform:translateY(0);opacity:1}30%{transform:translateY(-14px);opacity:1}100%{transform:translateY(10px);opacity:0}}
@keyframes ppc-pop{0%{opacity:0;transform:scaleX(.15);animation-timing-function:step-end}8%{opacity:1;transform:scaleX(.15);animation-timing-function:cubic-bezier(.34,1.56,.64,1)}40%{opacity:1;transform:scaleX(1)}85%{opacity:1;transform:scaleX(1)}100%{opacity:0;transform:translateY(-10px) scaleX(1)}}
@keyframes ppc-fall-l{0%{transform:none;opacity:1}15%{transform:rotate(-2deg);opacity:1}70%{transform:rotate(var(--fa));opacity:1}100%{transform:rotate(var(--fa)) translateY(6px);opacity:0}}
@keyframes ppc-fall-r{0%{transform:none;opacity:1}15%{transform:rotate(2deg);opacity:1}70%{transform:rotate(calc(-1 * var(--fa)));opacity:1}100%{transform:rotate(calc(-1 * var(--fa))) translateY(6px);opacity:0}}
@keyframes ppc-peel{0%{clip-path:polygon(0 0,100% 0,100% 100%,0 100%)}100%{clip-path:polygon(130% 0,100% 0,100% 100%,100% 100%)}}
@keyframes ppc-bounce{0%{opacity:0;transform:scale(.9);outline-color:var(--ppc-accent)}1%{opacity:1;transform:scale(.9)}40%{transform:scale(1.06)}70%{transform:scale(.98)}100%{opacity:1;transform:scale(1);outline-color:transparent}}
#$rootId.$reducedClass .ppc-site,#$rootId.$reducedClass .ppc-site *{animation:none!important}
@media (prefers-reduced-motion:reduce){#$rootId .ppc-site,#$rootId .ppc-site *{animation:none!important}}
''';
}
