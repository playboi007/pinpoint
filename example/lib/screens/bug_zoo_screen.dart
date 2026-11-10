import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Milestone 10: one planted instance of every problem the detectors find.
/// Open the findings list, Scan this screen and Check accessibility; with
/// rebuild heat on, the pulsing dot is the hot spot.
///
/// The row overflows only below 432 px wide: pick a 360 or 390 viewport in
/// the what-if panel to see it.
class BugZooScreen extends StatelessWidget {
  const BugZooScreen({super.key});

  /// Long enough to be cut at one line at any width.
  static const String longTitle =
      'A product title much too long for one line, so it is cut with an '
      'ellipsis at the end of the line, which hides the rest of it';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bug zoo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Overflow below 432 px wide:'),
          // Planted: two 200 px boxes need 400 px; at 360 wide there are 328.
          const Row(
            children: [
              SizedBox(
                width: 200,
                height: 24,
                child: ColoredBox(color: Colors.teal),
              ),
              SizedBox(
                width: 200,
                height: 24,
                child: ColoredBox(color: Colors.amber),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Planted: cut at one line.
          const Text(longTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          const Text('A 2000 x 2000 image shown at 100 x 100:'),
          const Align(alignment: Alignment.centerLeft, child: _BigImage()),
          const SizedBox(height: 16),
          Row(
            spacing: 8,
            children: [
              // Planted: 24 x 24 and no tooltip, so no label either.
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.add, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 24,
                  height: 24,
                ),
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              // Planted: light grey on the page's near-white.
              const Flexible(
                child: Text(
                  'Low contrast hint text',
                  style: TextStyle(color: Color(0xFFBDBDBD)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Rebuilds every frame:'),
          const Align(alignment: Alignment.centerLeft, child: _Pulse()),
          const SizedBox(height: 16),
          // Planted: its build throws. Sized, so Flutter's error box does
          // not take the list's unbounded height.
          const SizedBox(height: 80, child: _BrokenCard()),
        ],
      ),
    );
  }
}

/// A 2000 x 2000 image drawn once, shown at 100 x 100.
class _BigImage extends StatefulWidget {
  const _BigImage();

  @override
  State<_BigImage> createState() => _BigImageState();
}

class _BigImageState extends State<_BigImage> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 2000, 2000),
      Paint()..color = Colors.indigo,
    );
    final picture = recorder.endRecording();
    picture.toImage(2000, 2000).then((image) {
      picture.dispose();
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawImage(
    image: _image,
    width: 100,
    height: 100,
    debugImageLabel: 'bug zoo 2000x2000',
  );
}

/// A dot that rebuilds on every animation frame.
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    // setState per tick, the hot spot rebuild heat is for (an
    // AnimatedBuilder would rebuild only its builder).
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: Center(
      child: Container(
        width: 8 + 16 * _controller.value,
        height: 8 + 16 * _controller.value,
        decoration: const BoxDecoration(
          color: Colors.pink,
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

class _BrokenCard extends StatelessWidget {
  const _BrokenCard();

  @override
  Widget build(BuildContext context) =>
      throw StateError('bug zoo: a planted build error');
}
