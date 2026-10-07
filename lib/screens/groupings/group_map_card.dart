import 'package:flutter/material.dart';

import '../../services/chat_groupings.dart';
import '../../services/group_map.dart';
import '../../theme/tokens.dart';
import '../../widgets/format.dart';
import '../../widgets/paper_ui.dart';
import '../../widgets/bidi.dart';

/// The summary at the top of the groupings: every reply as a dot on a flat
/// map, coloured by its group, with a legend of names, counts and shares.
///
/// Every group has its own colour, but past a handful no set of colours stays
/// distinguishable to every eye, so colour never works alone: each group's
/// centre carries its number, the legend repeats it, and tapping a dot or a
/// name picks that group out and greys the rest.
class GroupMapCard extends StatefulWidget {
  const GroupMapCard({required this.groups, required this.map, super.key});

  final List<ChatGroup> groups;
  final GroupMap map;

  /// The categorical order, light and dark: the first eight groups, biggest
  /// first, take these in turn; later ones get generated colours.
  static const List<Color> _light = [
    Color(0xFF2A78D6),
    Color(0xFFEB6834),
    Color(0xFF1BAF7A),
    Color(0xFFEDA100),
    Color(0xFFE87BA4),
    Color(0xFF008300),
    Color(0xFF4A3AA7),
    Color(0xFFE34948),
  ];
  static const List<Color> _dark = [
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF008300),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ];

  static Color colourOf(int group) {
    final palette = Paper.isDark ? _dark : _light;
    if (group < palette.length) return palette[group];
    // Past the eighth, each next colour steps round the wheel by the golden
    // angle, so it lands away from the ones before it, alternating lighter
    // and deeper. These are not all easy to tell apart, which is why every
    // group also carries its number.
    final n = group - palette.length;
    final hue = (25 + n * 137.508) % 360;
    final deep = n.isEven;
    return HSLColor.fromAHSL(
      1,
      hue,
      deep ? 0.62 : 0.55,
      Paper.isDark ? (deep ? 0.55 : 0.68) : (deep ? 0.40 : 0.55),
    ).toColor();
  }

  @override
  State<GroupMapCard> createState() => _GroupMapCardState();
}

class _GroupMapCardState extends State<GroupMapCard> {
  int? _focus;

  /// The reply under the last tap, as (group, member).
  (int, int)? _picked;

  static const double _hitRadius = 22;

  void _toggle(int group) => setState(() {
    _focus = _focus == group ? null : group;
    _picked = null;
  });

  void _tapAt(Offset at, Size size) {
    final points = widget.map.points;
    (int, int)? best;
    var bestDistance = _hitRadius * _hitRadius;
    for (var g = 0; g < points.length; g++) {
      if (_focus != null && _focus != g) continue;
      for (var i = 0; i < points[g].length; i++) {
        final p = _MapPainter.toCanvas(points[g][i], size);
        final d = (p - at).distanceSquared;
        if (d < bestDistance) {
          bestDistance = d;
          best = (g, i);
        }
      }
    }
    setState(() {
      if (best == null) {
        _focus = null;
        _picked = null;
      } else {
        _focus = best.$1;
        _picked = best;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final total = groups.fold(0, (sum, g) => sum + g.size);
    final picked = _picked;
    final focus = _focus;
    final readout = picked != null
        ? '“${_clip(groups[picked.$1].members[picked.$2].replyText)}” · '
              '${groups[picked.$1].name}'
        : focus != null
        ? '${groups[focus].name} · ${grouped(groups[focus].size)} replies'
        : 'Tap a dot or a name to pick out a group';

    return PaperCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('The map', style: Type.display(22)),
          const SizedBox(height: 2),
          Text(
            'Each dot is a reply; close means alike.',
            style: Type.prose(size: 12.5, color: Paper.tertiary, height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            readout,
            textDirection: directionOf(readout),
            key: const ValueKey('map-readout'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Type.prose(size: 12.5, color: Paper.secondary, height: 1.35),
          ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _tapAt(details.localPosition, size),
                  child: Semantics(
                    label:
                        'Map of ${grouped(total)} replies in '
                        '${groups.length} groups. The list below gives each '
                        "group's share.",
                    child: CustomPaint(
                      key: const ValueKey('group-map'),
                      size: size,
                      painter: _MapPainter(
                        map: widget.map,
                        focus: focus,
                        picked: picked,
                        surface: Paper.card,
                        grid: Paper.divider,
                        faded: Paper.ink.withValues(alpha: 0.13),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          for (var g = 0; g < groups.length; g++)
            _LegendRow(
              key: ValueKey('legend-$g'),
              number: g + 1,
              colour: GroupMapCard.colourOf(g),
              name: groups[g].name,
              count: groups[g].size,
              share: total == 0 ? 0 : groups[g].size / total,
              focused: focus == g,
              dimmed: focus != null && focus != g,
              onTap: () => _toggle(g),
            ),
        ],
      ),
    );
  }

  static String _clip(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 79)}…';
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.number,
    required this.colour,
    required this.name,
    required this.count,
    required this.share,
    required this.focused,
    required this.dimmed,
    required this.onTap,
    super.key,
  });

  final int number;
  final Color colour;
  final String name;
  final int count;
  final double share;
  final bool focused;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = dimmed ? Paper.muted : Paper.ink;
    return InkWell(
      onTap: onTap,
      borderRadius: Corner.all(Corner.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            GroupBadge(number: number, colour: dimmed ? Paper.divider : colour),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: focused
                    ? Type.strong(size: 13.5, color: ink, height: 1.3)
                    : Type.prose(size: 13.5, color: ink, height: 1.3),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              grouped(count),
              style: Type.numeric(
                size: 12.5,
                color: dimmed ? Paper.muted : Paper.secondary,
                weight: FontWeight.w400,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                percent(share),
                textAlign: TextAlign.end,
                style: Type.numeric(size: 12.5, color: ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group's number on its colour, as on the map.
class GroupBadge extends StatelessWidget {
  const GroupBadge({
    required this.number,
    required this.colour,
    this.size = 22,
    super.key,
  });

  final int number;
  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
    child: Text(
      '$number',
      style: Type.numeric(size: size / 2, color: _MapPainter.inkOn(colour)),
    ),
  );
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.map,
    required this.focus,
    required this.picked,
    required this.surface,
    required this.grid,
    required this.faded,
  });

  final GroupMap map;
  final int? focus;
  final (int, int)? picked;
  final Color surface;
  final Color grid;

  /// Dots of the groups not picked out.
  final Color faded;

  /// Most dots drawn per group; beyond this an even sample stands in.
  static const int _maxPerGroup = 1500;

  static const double _inset = 14;

  static Offset toCanvas((double, double) p, Size size) {
    final w = size.width - 2 * _inset;
    final h = size.height - 2 * _inset;
    return Offset(
      _inset + (p.$1 + 1) / 2 * w,
      // Screen y grows downwards; the map's grows upwards.
      _inset + (1 - (p.$2 + 1) / 2) * h,
    );
  }

  /// Dark or white ink, whichever reads on [fill].
  static Color inkOn(Color fill) =>
      fill.computeLuminance() > 0.42 ? const Color(0xFF0B0B0B) : Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    // A recessive centre cross, only to anchor the eye.
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas
      ..drawLine(
        Offset(size.width / 2, _inset),
        Offset(size.width / 2, size.height - _inset),
        line,
      )
      ..drawLine(
        Offset(_inset, size.height / 2),
        Offset(size.width - _inset, size.height / 2),
        line,
      );

    void dots(int g, Color colour) {
      final points = map.points[g];
      final step = (points.length / _maxPerGroup).ceil().clamp(1, 1 << 30);
      final paint = Paint()..color = colour;
      for (var i = 0; i < points.length; i += step) {
        canvas.drawCircle(toCanvas(points[i], size), 2.6, paint);
      }
    }

    final order = [
      for (var g = 0; g < map.points.length; g++)
        if (g != focus) g,
      ?focus,
    ];
    for (final g in order) {
      final out = focus != null && focus != g;
      dots(g, out ? faded : GroupMapCard.colourOf(g).withValues(alpha: 0.7));
    }

    final hit = picked;
    if (hit != null) {
      final at = toCanvas(map.points[hit.$1][hit.$2], size);
      canvas
        ..drawCircle(at, 7, Paint()..color = surface)
        ..drawCircle(at, 5.5, Paint()..color = GroupMapCard.colourOf(hit.$1));
    }

    // Each group's number at its centre, ringed in the surface colour so it
    // stands off the dots beneath.
    for (var g = 0; g < map.centres.length; g++) {
      if (focus != null && focus != g) continue;
      final at = toCanvas(map.centres[g], size);
      final fill = GroupMapCard.colourOf(g);
      canvas
        ..drawCircle(at, 12, Paint()..color = surface)
        ..drawCircle(at, 10, Paint()..color = fill);
      final text = TextPainter(
        text: TextSpan(
          text: '${g + 1}',
          style: Type.numeric(size: 11, color: inkOn(fill)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, at - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.map != map ||
      old.focus != focus ||
      old.picked != picked ||
      old.surface != surface ||
      old.grid != grid ||
      old.faded != faded;
}
