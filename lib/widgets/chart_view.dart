import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/chart_maker.dart';
import '../theme/tokens.dart';
import 'format.dart';

/// The colours of up to three series, in this fixed order: teal, amber,
/// violet. Checked for colour-blind separation and contrast against both
/// surfaces.
List<Color> chartColors() => Paper.isDark
    ? const [Color(0xFF00A884), Color(0xFFBF7428), Color(0xFF9670F2)]
    : const [Color(0xFF008069), Color(0xFFC0661A), Color(0xFF7B42FA)];

/// A counted chart: title, legend, the chart itself (tap a bar or point for
/// its numbers) and a table view.
class ChartView extends StatefulWidget {
  const ChartView({required this.data, super.key});

  final ChartData data;

  @override
  State<ChartView> createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  int? _selected;
  bool _table = false;

  static const double _height = 200;

  String _format(double? v) {
    if (v == null) return '–';
    final measure = widget.data.spec.series.first.measure;
    if (measure == ChartMeasure.replyMinutes) {
      final m = v.round();
      return m < 60
          ? '$m min'
          : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')}';
    }
    if (measure == ChartMeasure.avgWords) return v.toStringAsFixed(1);
    return grouped(v.round());
  }

  int _peakIndex() {
    final d = widget.data;
    var best = 0;
    var bestValue = -1.0;
    for (var i = 0; i < d.labels.length; i++) {
      final total = d.values.fold(0.0, (s, series) => s + (series[i] ?? 0));
      if (total > bestValue) {
        best = i;
        bestValue = total;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final spec = d.spec;
    final colors = chartColors();
    final shown = _selected ?? _peakIndex();
    final total = spec.axis == ChartAxis.total;
    final readout = [
      if (!total) d.labels[shown],
      for (final (i, s) in spec.series.indexed)
        '${s.label.isEmpty ? "Value" : s.label} ${_format(d.values[i][shown])}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(spec.title, style: Type.strong(size: 16, height: 1.3)),
        if (spec.note != null) ...[
          const SizedBox(height: 4),
          Text(
            spec.note!,
            style: Type.prose(size: 12.5, color: Paper.muted, height: 1.35),
          ),
        ],
        if (spec.series.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final (i, s) in spec.series.indexed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colors[i],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      s.label,
                      style: Type.prose(size: 12.5, color: Paper.secondary),
                    ),
                  ],
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          readout,
          key: const ValueKey('chart-readout'),
          style: Type.numeric(
            size: 12,
            color: Paper.secondary,
            weight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 8),
        if (_table)
          _Table(data: d, format: _format)
        else
          SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, box) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (e) {
                  final n = d.labels.length;
                  final plot = box.maxWidth - _ChartPainter.left;
                  final x = e.localPosition.dx - _ChartPainter.left;
                  if (x < 0 || n == 0) return;
                  setState(
                    () => _selected = (x / plot * n).floor().clamp(0, n - 1),
                  );
                },
                child: CustomPaint(
                  key: const ValueKey('chart'),
                  size: Size(box.maxWidth, _height),
                  painter: _ChartPainter(
                    data: d,
                    colors: colors,
                    selected: shown,
                    format: _format,
                    grid: Paper.divider,
                    axis: Paper.dividerFirm,
                    labels: Paper.muted,
                    band: Paper.panel,
                    surface: Paper.card,
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            key: const ValueKey('chart-table'),
            onPressed: () => setState(() => _table = !_table),
            child: Text(
              _table ? 'Show the chart' : 'Show as a table',
              style: Type.strong(size: 13, color: Paper.accent),
            ),
          ),
        ),
      ],
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.data, required this.format});

  final ChartData data;
  final String Function(double?) format;

  @override
  Widget build(BuildContext context) {
    final series = data.spec.series;
    Widget row(List<String> cells, {bool header = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          for (final (i, c) in cells.indexed)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                c,
                textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                style: header
                    ? Type.prose(size: 11.5, color: Paper.muted)
                    : Type.numeric(
                        size: 12.5,
                        color: i == 0 ? Paper.ink : Paper.body,
                        weight: FontWeight.w400,
                      ),
              ),
            ),
        ],
      ),
    );
    return Column(
      children: [
        row(['', for (final s in series) s.label], header: true),
        for (var b = data.labels.length - 1; b >= 0; b--)
          row([
            data.labels[b].isEmpty ? 'All' : data.labels[b],
            for (var s = 0; s < series.length; s++) format(data.values[s][b]),
          ]),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.data,
    required this.colors,
    required this.selected,
    required this.format,
    required this.grid,
    required this.axis,
    required this.labels,
    required this.band,
    required this.surface,
  });

  final ChartData data;
  final List<Color> colors;
  final int selected;
  final String Function(double?) format;
  final Color grid;
  final Color axis;
  final Color labels;
  final Color band;
  final Color surface;

  /// Room for the value labels on the left, and the bucket labels below.
  static const double left = 40;
  static const double bottom = 20;

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    TextAlign align = TextAlign.center,
    double width = 40,
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: Type.numeric(size: 10, color: labels, weight: FontWeight.w400),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(minWidth: width, maxWidth: width);
    p.paint(canvas, at);
  }

  /// A round number at or above [v], so the top gridline reads cleanly.
  static double niceCeiling(double v) {
    if (v <= 0) return 1;
    final magnitude = math
        .pow(10, (math.log(v) / math.ln10).floor())
        .toDouble();
    for (final step in [1, 2, 2.5, 5, 10]) {
      if (step * magnitude >= v) return step * magnitude;
    }
    return 10 * magnitude;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = data.labels.length;
    if (n == 0) return;
    final plot = Rect.fromLTRB(left, 6, size.width, size.height - bottom);
    final top = niceCeiling(data.peak);
    double y(double v) => plot.bottom - (v / top) * plot.height;
    final slot = plot.width / n;

    // The picked bucket, as a faint band behind it.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(plot.left + slot * selected, plot.top, slot, plot.height),
        const Radius.circular(6),
      ),
      Paint()..color = band,
    );

    // Recessive gridlines at 0, half and the top, with their values.
    for (final f in [0.0, 0.5, 1.0]) {
      final gy = y(top * f);
      canvas.drawLine(
        Offset(plot.left, gy),
        Offset(plot.right, gy),
        Paint()
          ..color = f == 0 ? axis : grid
          ..strokeWidth = 1,
      );
      _text(
        canvas,
        format(top * f),
        Offset(0, gy - 6),
        align: TextAlign.right,
        width: left - 6,
      );
    }

    // Bucket labels, thinned to about six.
    final every = math.max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += every) {
      _text(
        canvas,
        data.spec.axis == ChartAxis.total ? '' : data.labels[i],
        Offset(plot.left + slot * i + slot / 2 - 24, plot.bottom + 5),
        width: 48,
      );
    }

    final series = data.values;
    if (data.spec.kind == ChartKind.bar || data.spec.axis == ChartAxis.total) {
      final k = series.length;
      final groupWidth = slot * (n <= 3 ? 0.5 : 0.78);
      final barWidth = math.min(28.0, (groupWidth - 2 * (k - 1)) / k);
      final groupStart = (slot - (barWidth * k + 2 * (k - 1))) / 2;
      for (var i = 0; i < n; i++) {
        for (var s = 0; s < k; s++) {
          final v = series[s][i];
          if (v == null || v <= 0) continue;
          final x = plot.left + slot * i + groupStart + s * (barWidth + 2);
          final h = plot.bottom - y(v);
          final r = math.min(4.0, math.min(h, barWidth / 2));
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(x, y(v), barWidth, h),
              topLeft: Radius.circular(r),
              topRight: Radius.circular(r),
            ),
            Paint()..color = colors[s],
          );
        }
      }
    } else {
      for (var s = 0; s < series.length; s++) {
        final paint = Paint()
          ..color = colors[s]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        Path? path;
        for (var i = 0; i < n; i++) {
          final v = series[s][i];
          if (v == null) {
            if (path != null) canvas.drawPath(path, paint);
            path = null;
            continue;
          }
          final p = Offset(plot.left + slot * i + slot / 2, y(v));
          path == null
              ? (path = Path()..moveTo(p.dx, p.dy))
              : path.lineTo(p.dx, p.dy);
        }
        if (path != null) canvas.drawPath(path, paint);
        // The picked point, ringed in the surface colour.
        final v = series[s][selected];
        if (v != null) {
          final p = Offset(plot.left + slot * selected + slot / 2, y(v));
          canvas
            ..drawCircle(p, 6, Paint()..color = surface)
            ..drawCircle(p, 4, Paint()..color = colors[s]);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.data != data || old.selected != selected || old.colors != colors;
}
