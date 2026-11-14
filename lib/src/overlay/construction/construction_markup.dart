import 'construction_layout.dart';

/// The HTML and CSS of the construction sites.
///
/// Plain strings and numbers, no Flutter and no `dart:html`: the web stage
/// puts them in the page, and a test or a preview can read them anywhere.
///
/// Everything moves by CSS keyframes (engineering rule 2: no Flutter frames
/// while the agent works). Nothing blurs: shadows are hard offsets.
abstract final class ConstructionMarkup {
  /// The `id` of the one root element.
  static const String rootId = 'pinpoint-construction';

  /// The `id` of the one `<style>` element.
  static const String styleId = 'pinpoint-construction-style';

  /// The asset folder, inside the package.
  static const String assetFolder = 'packages/pinpoint/assets/construction';

  /// The assets, by the name used in [siteHtml].
  static const List<String> assetNames = [
    'hammer_body',
    'hammer_arm',
    'walk_a',
    'walk_b',
    'painter',
    'roller',
    'done',
    'cone',
  ];

  /// The path of the asset [name] for `ui_web.assetManager.getAssetUrl`.
  static String assetPath(String name) => '$assetFolder/$name.webp';

  /// The class of the root while motion is reduced.
  static const String reducedClass = 'ppc-reduced';

  /// The class a site has while it plays its finish.
  static const String revealClass = 'ppc-reveal';

  /// The class a site has while it fades away.
  static const String outClass = 'ppc-out';

  /// How long the finish takes, in milliseconds. After this the site is
  /// removed.
  static const int revealMillis = 1400;

  /// How long a fade takes, in milliseconds.
  static const int fadeMillis = 180;

  /// The label on the tape.
  static const String label = 'UNDER PROGRESS';

  /// The `class` text of a site laid out as [layout].
  static String siteClass(
    ConstructionLayout layout, {
    bool revealing = false,
  }) => ['ppc-site', ...layout.classes, if (revealing) revealClass].join(' ');

  /// The `style` text of a site: [left] and [top] are CSS pixels in the
  /// page.
  static String siteStyle(
    ConstructionLayout layout, {
    required double left,
    required double top,
  }) =>
      'left:${left.toStringAsFixed(2)}px;top:${top.toStringAsFixed(2)}px;'
      'width:${layout.width.toStringAsFixed(2)}px;'
      'height:${layout.height.toStringAsFixed(2)}px;${layout.variables}';

  static String _attr(String url) => url
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;');

  /// The inside of a site. Every part is there; the site's classes pick
  /// which show. [urls] maps each of [assetNames] to its URL.
  static String siteHtml(Map<String, String> urls) {
    String img(String cls, String name) =>
        '<img class="$cls" alt="" draggable="false" '
        'src="${_attr(urls[name] ?? '')}">';
    final tape =
        '<div class="ppc-tape"><span class="ppc-label">$label</span></div>';
    return '<div class="ppc-cover"></div>'
        '<div class="ppc-w ppc-w-cones">'
        '${img('ppc-cone ppc-cone-l', 'cone')}'
        '${img('ppc-cone ppc-cone-r', 'cone')}</div>'
        '<div class="ppc-w ppc-w-hammer"><div class="ppc-hammer">'
        '<div class="ppc-dip">'
        '${img('ppc-arm', 'hammer_arm')}'
        '${img('ppc-body', 'hammer_body')}'
        '<i class="ppc-dust"></i></div></div></div>'
        '<div class="ppc-w ppc-w-barrow"><div class="ppc-barrow">'
        '<div class="ppc-flip">'
        '${img('ppc-wa', 'walk_a')}${img('ppc-wb', 'walk_b')}'
        '</div></div></div>'
        '<div class="ppc-w ppc-w-painter"><div class="ppc-painter">'
        '${img('ppc-man', 'painter')}${img('ppc-roller', 'roller')}'
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
  static const String css =
      '''
#$rootId{position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483000;pointer-events:none;overflow:visible}
#$rootId .ppc-site{position:absolute;box-sizing:border-box;isolation:isolate;pointer-events:none;animation:ppc-in .16s linear both}
#$rootId .ppc-site *{box-sizing:border-box;pointer-events:none}
#$rootId .ppc-site.ppc-out{animation:ppc-out .18s linear forwards}
#$rootId img{display:block;position:absolute;max-width:none;mix-blend-mode:multiply;user-select:none;-webkit-user-drag:none}
#$rootId .ppc-cover{position:absolute;left:0;top:0;right:0;bottom:0;z-index:1;border:1px solid var(--ppc-ink);background:repeating-linear-gradient(45deg,transparent 0,transparent 5px,var(--ppc-hatch) 5px,var(--ppc-hatch) 6px),var(--ppc-paper)}
#$rootId .ppc-w{position:absolute;left:0;top:0;right:0;bottom:0;z-index:2}
#$rootId .ppc-bare .ppc-w,#$rootId .ppc-bare .ppc-done-box,#$rootId .ppc-w-cones,#$rootId .ppc-w-barrow,#$rootId .ppc-w-painter{display:none}
#$rootId .ppc-cones .ppc-w-cones,#$rootId .ppc-barrow-on .ppc-w-barrow,#$rootId .ppc-painter-on .ppc-w-painter{display:block}
#$rootId .ppc-cone{bottom:2px;width:calc(65px*var(--sc));height:calc(81px*var(--sc))}
#$rootId .ppc-cone-l{left:4px}
#$rootId .ppc-cone-r{right:4px}
#$rootId .ppc-hammer{position:absolute;left:var(--hl);bottom:2px;width:95px;height:123px;transform:scale(var(--sh));transform-origin:0 100%}
#$rootId .ppc-dip{position:absolute;left:0;top:0;width:95px;height:123px;animation:ppc-dip .6s linear infinite}
#$rootId .ppc-body{left:0;top:0;width:60px;height:123px;z-index:2}
#$rootId .ppc-arm{left:6.6px;top:4.3px;width:68px;height:68px;z-index:1;transform-origin:9.9px 58.4px;animation:ppc-swing .6s linear infinite}
#$rootId .ppc-dust{position:absolute;left:88px;top:58px;width:7px;height:7px;z-index:3;opacity:0;border:1px solid var(--ppc-ink);background:var(--ppc-paper);animation:ppc-dust .6s linear infinite}
#$rootId .ppc-barrow{position:absolute;left:var(--bl);bottom:2px;width:calc(121px*var(--sb));height:calc(112px*var(--sb));animation:ppc-walk var(--wd) linear infinite}
#$rootId .ppc-flip{position:absolute;left:0;top:0;right:0;bottom:0;animation:ppc-turn var(--wd) step-end infinite}
#$rootId .ppc-flip img,#$rootId .ppc-painter img{left:0;top:0;width:100%;height:100%}
#$rootId .ppc-wa{animation:ppc-la .5s step-end infinite}
#$rootId .ppc-wb{opacity:0;animation:ppc-lb .5s step-end infinite}
#$rootId .ppc-painter{position:absolute;right:var(--pr);bottom:2px;width:calc(114px*var(--sp));height:calc(189px*var(--sp))}
#$rootId .ppc-roller{animation:ppc-roll 1.2s ease-in-out infinite}
#$rootId .ppc-half{position:absolute;left:-4px;right:-4px;top:var(--tt);height:var(--th);z-index:5}
#$rootId .ppc-half-l{clip-path:inset(-4px 50% -4px -4px)}
#$rootId .ppc-half-r{clip-path:inset(-4px -4px -4px 50%)}
#$rootId .ppc-tape{position:absolute;left:0;top:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center;overflow:hidden;border:1px solid var(--ppc-ink);box-shadow:2px 2px 0 var(--ppc-shadow);background:repeating-linear-gradient(-45deg,var(--ppc-accent) 0,var(--ppc-accent) 6px,var(--ppc-paper) 6px,var(--ppc-paper) 12px)}
#$rootId .ppc-label{padding:0 4px;border:1px solid var(--ppc-ink);background:var(--ppc-paper);color:var(--ppc-ink);font:500 var(--tf)/1 "packages/pinpoint/RobotoMono","RobotoMono",ui-monospace,monospace;letter-spacing:.08em;white-space:nowrap;text-transform:uppercase}
#$rootId .ppc-done-box{position:absolute;left:0;right:0;bottom:2px;z-index:4;display:none;justify-content:center}
#$rootId .ppc-reveal .ppc-done-box{display:flex}
#$rootId .ppc-done{position:relative;height:calc(146px*var(--sd));width:calc(88px*var(--sd));opacity:0;transform-origin:50% 100%}
#$rootId .ppc-shotbox{position:absolute;left:0;top:0;right:0;bottom:0;z-index:7;outline:2px solid var(--ppc-accent);background:var(--ppc-paper);animation:ppc-bounce .7s ease-in-out .7s both}
#$rootId .ppc-shotbox img{mix-blend-mode:normal;left:0;top:0;width:100%;height:100%}
#$rootId .ppc-reveal .ppc-w{animation:ppc-hop .4s cubic-bezier(.3,.6,.5,1) .05s forwards}
#$rootId .ppc-reveal .ppc-done{animation:ppc-pop 1s linear .1s forwards}
#$rootId .ppc-reveal .ppc-half-l{animation:ppc-fall-l .55s cubic-bezier(.5,0,.9,.6) forwards}
#$rootId .ppc-reveal .ppc-half-r{animation:ppc-fall-r .55s cubic-bezier(.5,0,.9,.6) forwards}
#$rootId .ppc-reveal .ppc-cover{animation:ppc-peel .45s cubic-bezier(.6,0,.4,1) .4s forwards}
@keyframes ppc-in{from{opacity:0}to{opacity:1}}
@keyframes ppc-out{from{opacity:1}to{opacity:0}}
@keyframes ppc-swing{0%{transform:rotate(0deg);animation-timing-function:cubic-bezier(.55,0,1,.45)}25%{transform:rotate(45deg)}30%{transform:rotate(45deg);animation-timing-function:cubic-bezier(.2,.6,.4,1)}100%{transform:rotate(0deg)}}
@keyframes ppc-dip{0%,22%{transform:translateY(0)}25%{transform:translateY(2px)}36%{transform:translateY(0)}100%{transform:translateY(0)}}
@keyframes ppc-dust{0%,24%{opacity:0;transform:translate(0,0) scale(.4)}25%{opacity:1;transform:translate(0,0) scale(.6)}45%{opacity:0;transform:translate(6px,-8px) scale(1.3)}100%{opacity:0;transform:translate(6px,-8px) scale(1.3)}}
@keyframes ppc-walk{0%{transform:translateX(0)}46%{transform:translateX(var(--run))}50%{transform:translateX(var(--run))}96%{transform:translateX(0)}100%{transform:translateX(0)}}
@keyframes ppc-turn{0%{transform:scaleX(1)}48%{transform:scaleX(-1)}98%{transform:scaleX(1)}}
@keyframes ppc-la{0%{opacity:1}50%{opacity:0}}
@keyframes ppc-lb{0%{opacity:0}50%{opacity:1}}
@keyframes ppc-roll{0%,100%{transform:translateY(0)}50%{transform:translateY(calc(-14px*var(--sp)))}}
@keyframes ppc-hop{0%{transform:translateY(0);opacity:1}30%{transform:translateY(-14px);opacity:1}100%{transform:translateY(10px);opacity:0}}
@keyframes ppc-pop{0%{opacity:0;transform:translateY(40%) scale(.3);animation-timing-function:cubic-bezier(.34,1.56,.64,1)}45%{opacity:1;transform:translateY(0) scale(1)}80%{opacity:1;transform:translateY(0) scale(1)}100%{opacity:0;transform:translateY(-10px) scale(1)}}
@keyframes ppc-fall-l{0%{transform:none;opacity:1}12%{transform:translate(-4px,-2px) rotate(-2deg);opacity:1}100%{transform:translate(-18px,40px) rotate(-38deg);opacity:0}}
@keyframes ppc-fall-r{0%{transform:none;opacity:1}12%{transform:translate(4px,-2px) rotate(2deg);opacity:1}100%{transform:translate(18px,40px) rotate(38deg);opacity:0}}
@keyframes ppc-peel{0%{clip-path:polygon(0 0,100% 0,100% 100%,0 100%)}100%{clip-path:polygon(130% 0,100% 0,100% 100%,100% 100%)}}
@keyframes ppc-bounce{0%{opacity:0;transform:scale(.9);outline-color:var(--ppc-accent)}1%{opacity:1;transform:scale(.9)}40%{transform:scale(1.06)}70%{transform:scale(.98)}100%{opacity:1;transform:scale(1);outline-color:transparent}}
#$rootId.$reducedClass .ppc-site,#$rootId.$reducedClass .ppc-site *{animation:none!important}
@media (prefers-reduced-motion:reduce){#$rootId .ppc-site,#$rootId .ppc-site *{animation:none!important}}
''';
}
