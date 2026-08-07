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
//   1. Inline style inheritance (PreserveInlineStylesRule) — a corrected
//      word should keep the inline style (e.g. underline) already active at
//      the edit point.
//   2. Block style carry-over (PreserveBlockStyleOnInsertRule /
//      ResetLineFormatOnNewLineRule) — if the inserted text contains a
//      newline, that newline must inherit the current line's block
//      attribute (list, code-block, quote, ...) or the block silently exits.

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
      expect(
        controller.document
            .collectStyle(10, 1)
            .attributes
            .containsKey('list'),
        isTrue,
        reason:
            'The newly-inserted newline must inherit the bullet-list '
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
      expect(
        controller.document
            .collectStyle(11, 1)
            .attributes
            .containsKey('code-block'),
        isTrue,
        reason:
            'The newly-inserted newline must inherit the code-block '
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
}
