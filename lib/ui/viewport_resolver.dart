import 'terminal_viewport.dart';
import 'viewport_geometry.dart';

/// Maps a [ViewportQuery] to a [TerminalViewport]. Always returns a usable
/// viewport — fractional leftover pixels become centered padding, never phantom
/// terminal rows.
class ViewportResolver {
  const ViewportResolver();

  TerminalViewport resolve(
    ViewportQuery query, {
    double devicePixelRatio = 1.0,
  }) {
    final availW =
        (query.available.width - query.reserve.horizontal)
            .clamp(TerminalGrid.minWidthPx, double.infinity);
    final availH =
        (query.available.height - query.reserve.vertical)
            .clamp(TerminalGrid.minHeightPx, double.infinity);

    final cw = query.cell.width;
    final ch = query.cell.height;

    // Below usable floors: clamp to minimum grid and center (never return null
    // and leave the widget larger than the committed engine grid).
    var cols = availW > 0 ? (availW / cw).floor() : 0;
    var rows = availH > 0 ? (availH / ch).floor() : 0;

    if (cols < TerminalGrid.minCols) cols = TerminalGrid.minCols;
    if (rows < TerminalGrid.minRows) rows = TerminalGrid.minRows;

    final cellW = cols * cw;
    final cellH = rows * ch;

    // Effective window for padding math: at least the cell area.
    final winW = availW > cellW ? availW : cellW;
    final winH = availH > cellH ? availH : cellH;

    final paddingX = (winW - cellW) / 2;
    final paddingY = (winH - cellH) / 2;

    return TerminalViewport(
      windowWidth: winW,
      windowHeight: winH,
      cellWidth: cw,
      cellHeight: ch,
      paddingX: paddingX,
      paddingY: paddingY,
      columns: cols,
      screenLines: rows,
      devicePixelRatio: devicePixelRatio,
    );
  }
}
