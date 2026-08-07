// Tests for the fix introduced for CU-86d32rw03 / CU-86d32rrzk.
//
// Background
// ----------
// updateEditingValue's "true replacement" bypass (added for CU-86d2ne59y,
// see update_editing_value_test.dart) composes a raw delete+insert Delta
// directly onto the document whenever the platform reports a non-empty
// delete AND a non-empty insert in the same call. That bypass is
// unconditional — see the comment at its call site for why narrowing it to
// "only verified iOS shortcut commits" reintroduces the substring-collision
// corruption CU-86d2ne59y fixed (an IME committing a composing word at the
// same moment as Enter produces exactly the same delete+insert shape, e.g.
// deleted="item", inserted="item\n").
//
// Bypassing the Rules engine loses two things it normally provides, which
// this fix reproduces explicitly inside the bypass:
//   1. Inline style inheritance (PreserveInlineStylesRule) — the replacement
//      text should keep the inline style of the text it REPLACED. Sampling
//      the style at the caret instead (collectStyle(start, 0)) reads the
//      *preceding* character for an intra-line position, which both drops
//      the replaced run's own style and leaks the previous run's style —
//      both boundary directions are covered below.
//   2. Line/block style carry-over (PreserveBlockStyleOnInsertRule /
//      ResetLineFormatOnNewLineRule) — an inserted newline must inherit the
//      split line's block attribute (list, code-block, quote, ...) or the
//      block silently exits, and must inherit `header` so a heading does not
//      jump to the following line.
//
// Inline and line attributes go to disjoint parts of the inserted string:
// inline only to non-newline runs (Quill throws "It is not allowed to apply
// inline attributes to line itself" otherwise), line attributes only to the
// newlines.

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill_test/flutter_quill_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../common/utils/quill_test_app.dart';

void main() {
  Widget buildApp(QuillController controller) => QuillTestApp.withScaffold(
        QuillEditor.basic(
          controller: controller,
          config: const QuillEditorConfig(autoFocus: true),
        ),
      );

  /// Drives an IME commit: first primes a composing range (text and selection
  /// unchanged, so the mixin only records it), then sends the commit that
  /// `computeTextReplacementDiff` recovers a delete+insert diff from.
  Future<void> imeCommit(
    WidgetTester tester, {
    required String primedText,
    required int primedCursor,
    required TextRange composing,
    required String committedText,
    required int committedCursor,
  }) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: primedText,
        selection: TextSelection.collapsed(offset: primedCursor),
        composing: composing,
      ),
    );
    await tester.idle();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: committedText,
        selection: TextSelection.collapsed(offset: committedCursor),
      ),
    );
    await tester.idle();
  }

  group('inline style inheritance through the true-replacement bypass '
      '(CU-86d32rw03 — underline dropped on autocorrect)', () {
    testWidgets(
        'autocorrect replacing a fully-underlined word keeps the underline',
        (tester) async {
      // "teh" is entirely underlined, matching "enable Underline, type a
      // word that autocorrect fixes" from the ticket's repro steps.
      final doc = Document.fromDelta(
        Delta()
          ..insert('teh', {'underline': true})
          ..insert('\n'),
      );
      final controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 3),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Autocorrect commits "teh" -> "the" (no composing range set, matching
      // how the existing "autocorrect: misspelling replaced" test in
      // update_editing_value_test.dart drives this — via the generic getDiff
      // fallback, not computeTextReplacementDiff).
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'the\n',
        const TextSelection.collapsed(offset: 3),
      );

      expect(controller.document.toPlainText(), 'the\n');
      expect(
        controller.document.collectStyle(0, 3).attributes.containsKey(
              'underline',
            ),
        isTrue,
        reason:
            'The corrected word must keep the underline that was already '
            'active on the text it replaced.',
      );

      controller.dispose();
    });

    testWidgets(
        'autocorrect replacing part of a bold word keeps the bold style',
        (tester) async {
      final doc = Document.fromDelta(
        Delta()
          ..insert('quikc fox', {'bold': true})
          ..insert('\n'),
      );
      final controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 5),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'quick fox\n',
        const TextSelection.collapsed(offset: 5),
      );

      expect(controller.document.toPlainText(), 'quick fox\n');
      expect(
        controller.document.collectStyle(0, 9).attributes.containsKey('bold'),
        isTrue,
      );

      controller.dispose();
    });
  });

  group('block style carry-over through the true-replacement bypass '
      '(CU-86d32rrzk — list does not continue; '
      'CU-86d32rw03 — code block exits)', () {
    testWidgets(
        'bullet list continues when Enter is bundled with a composing-word '
        'commit (delete "item", insert "item\\n")',
        (tester) async {
      final doc = Document.fromDelta(
        Delta()
          ..insert('First item')
          ..insert('\n', {'list': 'bullet'}),
      );
      final controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 10),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Prime the composing range: text and selection unchanged from the
      // last known value, only composing differs — the mixin stores this
      // without running the diff pipeline (see the "composing-range-only
      // change" test in update_editing_value_test.dart).
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'First item\n',
          selection: TextSelection.collapsed(offset: 10),
          composing: TextRange(start: 6, end: 10), // covers "item"
        ),
      );
      await tester.idle();

      // The IME commits the composing word ("item", unchanged) and Enter in
      // one call. computeTextReplacementDiff recovers
      // Diff(start: 6, deleted: 'item', inserted: 'item\n') from the
      // composing-range signature.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'First item\n\n',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      await tester.idle();

      expect(controller.document.toPlainText(), 'First item\n\n');
      // Explicit Delta assertion, not just collectStyle: both the
      // newly-inserted newline (from Enter) and the original one (from the
      // source document, untouched by the edit) must carry the list
      // attribute — Quill's Delta serialization compacts two consecutive
      // newlines with identical attributes into one "\n\n" insert op, which
      // is what confirms neither line dropped the attribute.
      expect(
        controller.document.toDelta(),
        Delta()
          ..insert('First item')
          ..insert('\n\n', {'list': 'bullet'}),
      );
      expect(
        controller.document
            .collectStyle(10, 1)
            .attributes
            .containsKey('list'),
        isTrue,
        reason:
            'The newly-inserted newline (offset 10 — see the Delta assertion '
            'above: it is the first of the two compacted "\\n" ops, not the '
            'pre-existing one at offset 11) must inherit the bullet-list '
            'attribute from the line it split, or the list visibly stops.',
      );

      controller.dispose();
    });

    testWidgets(
        'code block persists when Enter is bundled with a composing-word '
        'commit mid-block',
        (tester) async {
      final doc = Document.fromDelta(
        Delta()
          ..insert('const x = 1')
          ..insert('\n', {'code-block': true}),
      );
      final controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 11),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'const x = 1\n',
          selection: TextSelection.collapsed(offset: 11),
          composing: TextRange(start: 10, end: 11), // covers "1"
        ),
      );
      await tester.idle();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'const x = 1\n\n',
          selection: TextSelection.collapsed(offset: 12),
        ),
      );
      await tester.idle();

      expect(controller.document.toPlainText(), 'const x = 1\n\n');
      // Explicit Delta assertion — see the list-continuation test above for
      // why this, not just collectStyle, is what actually distinguishes the
      // newly-inserted newline from the pre-existing one.
      expect(
        controller.document.toDelta(),
        Delta()
          ..insert('const x = 1')
          ..insert('\n\n', {'code-block': true}),
      );
      expect(
        controller.document
            .collectStyle(11, 1)
            .attributes
            .containsKey('code-block'),
        isTrue,
        reason:
            'The newly-inserted newline (offset 11 — the first of the two '
            'compacted "\\n" ops in the Delta assertion above, not the '
            'pre-existing one at offset 12) must inherit the code-block '
            'attribute, or the block visibly closes mid-typing.',
      );

      controller.dispose();
    });

    testWidgets(
        'a plain autocorrect replacement with no newline is unaffected '
        '(no spurious block attribute applied)',
        (tester) async {
      // Regression guard: the block-carry-over logic must only fire when
      // the inserted text actually contains a newline.
      final doc = Document.fromDelta(
        Delta()
          ..insert('the quikc fox')
          ..insert('\n', {'list': 'bullet'}),
      );
      final controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 13),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'the quick fox\n',
        const TextSelection.collapsed(offset: 13),
      );

      expect(controller.document.toPlainText(), 'the quick fox\n');
      controller.dispose();
    });
  });

  group('inline style is sampled from the replaced range, not the caret', () {
    testWidgets(
        'autocapitalizing a styled single character keeps its own style '
        '(style must not be read from the plain character before it)',
        (tester) async {
      // "say " is plain, the trailing "i" is underlined. Sampling the caret
      // position would read the space and drop the underline.
      final controller = QuillController(
        document: Document.fromDelta(
          Delta()
            ..insert('say ')
            ..insert('i', {'underline': true})
            ..insert('\n'),
        ),
        selection: const TextSelection.collapsed(offset: 5),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await imeCommit(
        tester,
        primedText: 'say i\n',
        primedCursor: 5,
        composing: const TextRange(start: 4, end: 5),
        committedText: 'say I\n',
        committedCursor: 5,
      );

      expect(
        controller.document.toDelta(),
        Delta()
          ..insert('say ')
          ..insert('I', {'underline': true})
          ..insert('\n'),
        reason: 'The autocapitalized "I" must keep the underline that the '
            '"i" it replaced carried.',
      );

      controller.dispose();
    });

    testWidgets(
        'autocapitalizing a plain character after a styled run stays plain '
        '(style must not leak from the character before it)',
        (tester) async {
      // Mirror of the test above: "bold" is bold, the trailing "i" is plain.
      // Sampling the caret position would read the bold "d" and wrongly
      // bold the replacement.
      final controller = QuillController(
        document: Document.fromDelta(
          Delta()
            ..insert('bold', {'bold': true})
            ..insert('i')
            ..insert('\n'),
        ),
        selection: const TextSelection.collapsed(offset: 5),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await imeCommit(
        tester,
        primedText: 'boldi\n',
        primedCursor: 5,
        composing: const TextRange(start: 4, end: 5),
        committedText: 'boldI\n',
        committedCursor: 5,
      );

      expect(
        controller.document.toDelta(),
        Delta()
          ..insert('bold', {'bold': true})
          ..insert('I\n'),
        reason: 'The replacement for a plain character must stay plain — '
            'bold must not leak from the preceding run.',
      );

      controller.dispose();
    });

    testWidgets(
        'replacing styled text with only a newline does not throw '
        '(inline attributes must not be applied to a line terminator)',
        (tester) async {
      // Quill rejects inline attributes on a line's own terminator with
      // "It is not allowed to apply inline attributes to line itself".
      final controller = QuillController(
        document: Document.fromDelta(
          Delta()
            ..insert('x', {'underline': true})
            ..insert('\n'),
        ),
        selection: const TextSelection.collapsed(offset: 1),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await imeCommit(
        tester,
        primedText: 'x\n',
        primedCursor: 1,
        composing: const TextRange(start: 0, end: 1),
        committedText: '\n\n',
        committedCursor: 1,
      );

      expect(controller.document.toDelta(), Delta()..insert('\n\n'));
      controller.dispose();
    });
  });

  group('header carry-over through the true-replacement bypass', () {
    testWidgets(
        'Enter at the end of a heading leaves the heading on its own line '
        'and starts a plain line, matching the Rules engine',
        (tester) async {
      final controller = QuillController(
        document: Document.fromDelta(
          Delta()
            ..insert('Title')
            ..insert('\n', {'header': 1}),
        ),
        selection: const TextSelection.collapsed(offset: 5),
      );

      await tester.pumpWidget(buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await imeCommit(
        tester,
        primedText: 'Title\n',
        primedCursor: 5,
        composing: const TextRange(start: 0, end: 5),
        committedText: 'Title\n\n',
        committedCursor: 6,
      );

      // Identical to what Document.insert(5, '\n') produces through the
      // Rules engine — asserted directly in the test below.
      expect(
        controller.document.toDelta(),
        Delta()
          ..insert('Title')
          ..insert('\n', {'header': 1})
          ..insert('\n'),
        reason: 'The heading must stay on the "Title" line; the new empty '
            'line must be a plain paragraph.',
      );

      controller.dispose();
    });

    test(
        'the bypass result matches the Rules engine for Enter at end of '
        'a heading', () {
      // Pins the expectation used above to the Rules engine itself, so this
      // stays honest if upstream ever changes that behavior.
      final doc = Document.fromDelta(
        Delta()
          ..insert('Title')
          ..insert('\n', {'header': 1}),
      )..insert(5, '\n');

      expect(
        doc.toDelta(),
        Delta()
          ..insert('Title')
          ..insert('\n', {'header': 1})
          ..insert('\n'),
      );
    });
  });
}
