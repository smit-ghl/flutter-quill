import 'package:flutter/material.dart';

import '../../editor/widgets/default_styles.dart';

/// GHL patch: a total version of [stringToColor] for content-derived values.
///
/// [stringToColor] throws on anything it cannot parse (`UnsupportedError`
/// for unknown formats, `FormatException`/`RangeError` for malformed
/// `rgba(…)`/hex). When the input comes from document content — pasted HTML,
/// stored Deltas — that throw happens mid-build and takes down the whole
/// editor screen (a build error inside a quill text line becomes a
/// RenderErrorBox that `_TextLineElement` cannot adopt).
///
/// This wrapper never throws: unparseable input yields `null`, so callers
/// skip the color instead of crashing. Use it for any value that originates
/// from document content; [stringToColor] remains for trusted literals.
Color? tryStringToColor(
  String? s, [
  Color? originalColor,
  DefaultStyles? defaultStyles,
]) {
  if (s == null) return originalColor;
  try {
    return stringToColor(s, originalColor, defaultStyles);
  } catch (_) {
    return null;
  }
}

Color stringToColor(
  String? s, [
  Color? originalColor,
  DefaultStyles? defaultStyles,
]) {
  final palette = defaultStyles?.palette;
  if (s != null && palette != null) {
    final maybeColor = palette[s];
    if (maybeColor != null) {
      return maybeColor;
    }
  }

  switch (s) {
    case 'transparent':
      return Colors.transparent;
    case 'black':
      return Colors.black;
    case 'black12':
      return Colors.black12;
    case 'black26':
      return Colors.black26;
    case 'black38':
      return Colors.black38;
    case 'black45':
      return Colors.black45;
    case 'black54':
      return Colors.black54;
    case 'black87':
      return Colors.black87;
    case 'white':
      return Colors.white;
    case 'white10':
      return Colors.white10;
    case 'white12':
      return Colors.white12;
    case 'white24':
      return Colors.white24;
    case 'white30':
      return Colors.white30;
    case 'white38':
      return Colors.white38;
    case 'white54':
      return Colors.white54;
    case 'white60':
      return Colors.white60;
    case 'white70':
      return Colors.white70;
    case 'red':
      return Colors.red;
    case 'redAccent':
      return Colors.redAccent;
    case 'amber':
      return Colors.amber;
    case 'amberAccent':
      return Colors.amberAccent;
    case 'yellow':
      return Colors.yellow;
    case 'yellowAccent':
      return Colors.yellowAccent;
    case 'teal':
      return Colors.teal;
    case 'tealAccent':
      return Colors.tealAccent;
    case 'purple':
      return Colors.purple;
    case 'purpleAccent':
      return Colors.purpleAccent;
    case 'pink':
      return Colors.pink;
    case 'pinkAccent':
      return Colors.pinkAccent;
    case 'orange':
      return Colors.orange;
    case 'orangeAccent':
      return Colors.orangeAccent;
    case 'deepOrange':
      return Colors.deepOrange;
    case 'deepOrangeAccent':
      return Colors.deepOrangeAccent;
    case 'indigo':
      return Colors.indigo;
    case 'indigoAccent':
      return Colors.indigoAccent;
    case 'lime':
      return Colors.lime;
    case 'limeAccent':
      return Colors.limeAccent;
    case 'grey':
      return Colors.grey;
    case 'blueGrey':
      return Colors.blueGrey;
    case 'green':
      return Colors.green;
    case 'greenAccent':
      return Colors.greenAccent;
    case 'lightGreen':
      return Colors.lightGreen;
    case 'lightGreenAccent':
      return Colors.lightGreenAccent;
    case 'blue':
      return Colors.blue;
    case 'blueAccent':
      return Colors.blueAccent;
    case 'lightBlue':
      return Colors.lightBlue;
    case 'lightBlueAccent':
      return Colors.lightBlueAccent;
    case 'cyan':
      return Colors.cyan;
    case 'cyanAccent':
      return Colors.cyanAccent;
    case 'brown':
      return Colors.brown;
  }

  if (s!.startsWith('rgba')) {
    s = s.substring(5); // trim left 'rgba('
    s = s.substring(0, s.length - 1); // trim right ')'
    final arr = s.split(',').map((e) => e.trim()).toList();
    return Color.fromRGBO(
      int.parse(arr[0]),
      int.parse(arr[1]),
      int.parse(arr[2]),
      double.parse(arr[3]),
    );
  }

  // TODO: take care of "color": "inherit"
  if (s.startsWith('inherit')) {
    return originalColor ?? Colors.black;
  }

  if (!s.startsWith('#')) {
    throw UnsupportedError('Color code not supported');
  }

  var hex = s.replaceFirst('#', '');
  hex = hex.length == 6 ? 'ff$hex' : hex;
  final val = int.parse(hex, radix: 16);
  return Color(val);
}
