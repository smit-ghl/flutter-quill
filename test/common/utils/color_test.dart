import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
// ignore: implementation_imports
import 'package:flutter_quill/src/common/utils/color.dart';
import 'package:flutter_test/flutter_test.dart';

import 'quill_test_app.dart';

// GHL patch tests: content-derived color strings must never crash the
// editor build. `stringToColor` throws on anything it cannot parse; the
// `tryStringToColor` wrapper returns null instead, and the render-path call
// sites (text_line.dart, color_button.dart) skip the color when null.
//
// Regression: gohighlevel Sentry HIGHLEVEL-FLUTTER-13R — product
// descriptions pasted from website builders carried
// `color: rgba(0,0,0,var(--O42jJQ,1))`; `double.parse('var(--O42jJQ')`
// threw mid-build and the resulting RenderErrorBox crashed
// `_TextLineElement` with a RenderContentProxyBox cast error.
void main() {
  group('tryStringToColor', () {
    test('parses everything stringToColor parses', () {
      expect(tryStringToColor('red'), Colors.red);
      expect(tryStringToColor('transparent'), Colors.transparent);
      expect(tryStringToColor('#336699'), const Color(0xff336699));
      expect(tryStringToColor('#ff336699'), const Color(0xff336699));
      expect(
        tryStringToColor('rgba(255, 0, 0, 1.0)'),
        const Color.fromRGBO(255, 0, 0, 1),
      );
      expect(tryStringToColor('inherit', Colors.green), Colors.green);
    });

    test('returns originalColor for null input', () {
      expect(tryStringToColor(null), isNull);
      expect(tryStringToColor(null, Colors.green), Colors.green);
    });

    test('returns null instead of throwing for unparseable input', () {
      const hostile = [
        'rgba(0,0,0,var(--O42jJQ,1))', // the HIGHLEVEL-FLUTTER-13R shape
        'rgba(255.5, 0, 0, 1)', // float channel → int.parse throws
        'rgba(0,0,0)', // missing alpha → arr[3] RangeError
        'rgb(0, 0, 0)', // rgb prefix → UnsupportedError
        'hsl(0, 100%, 50%)', // hsl → UnsupportedError
        'cornflowerblue', // not in the named switch
        '#zzz999', // malformed hex → FormatException
        'var(--brand)', // unresolved CSS variable
        '',
      ];
      for (final value in hostile) {
        expect(
          () => stringToColor(value),
          throwsA(anything),
          reason: '"$value" is expected to throw in stringToColor — if it '
              'no longer does, this list needs updating',
        );
        expect(
          tryStringToColor(value),
          isNull,
          reason: 'tryStringToColor must swallow "$value"',
        );
      }
    });
  });

  group('editor renders unparseable content colors without crashing', () {
    Future<void> pumpDelta(WidgetTester tester, Delta delta) async {
      final controller = QuillController(
        document: Document.fromDelta(delta),
        selection: const TextSelection.collapsed(offset: 0),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        QuillTestApp.withScaffold(
          QuillEditor.basic(controller: controller),
        ),
      );

      expect(tester.takeException(), isNull);
    }

    testWidgets('color: rgba with CSS variable alpha', (tester) async {
      final delta = Delta()
        ..insert('hi', {'color': 'rgba(0,0,0,var(--O42jJQ,1))'})
        ..insert('\n');
      await pumpDelta(tester, delta);
    });

    testWidgets('background: rgba with CSS variable alpha', (tester) async {
      final delta = Delta()
        ..insert('hi', {'background': 'rgba(0,0,0,var(--O42jJQ,1))'})
        ..insert('\n');
      await pumpDelta(tester, delta);
    });

    testWidgets('unparseable color combined with underline '
        '(decoration-color call site)', (tester) async {
      final delta = Delta()
        ..insert('hi', {'color': 'rgba(0,0,0)', 'underline': true})
        ..insert('\n');
      await pumpDelta(tester, delta);
    });

    testWidgets('parseable colors still render', (tester) async {
      final delta = Delta()
        ..insert('red', {'color': '#ff0000'})
        ..insert('named', {'color': 'red'})
        ..insert('rgba', {'color': 'rgba(0, 0, 0, 0.5)'})
        ..insert('bg', {'background': '#ffff00'})
        ..insert('\n');
      await pumpDelta(tester, delta);
    });
  });
}
