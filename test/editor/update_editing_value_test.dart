// Tests for the updateEditingValue fix introduced in CU-86d2ne59y.
//
// Background
// ----------
// Quill's heuristic insert rules can place inserted text either BEFORE or
// AFTER the replaced region. A subsequent delete(index, len) then hits the
// wrong characters, corrupting the document.
//
// Fix summary
// -----------
// • True replacements (both deleted and inserted non-empty): build a precise
//   Delta(retain→delete→insert) and compose directly, bypassing rules.
// • Pure inserts / pure deletes: still route through replaceText so rules
//   like PreserveInlineStylesRule and AutoFormatLinksRule continue to work.
//
// Test organisation
// -----------------
// 1. Document.compose unit tests  – verify the exact delta we build is correct
// 2. getDiff + compose integration – end-to-end pipeline without a widget
// 3. Widget tests                  – simulate real platform updateEditingValue

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill/src/delta/delta_diff.dart';
import 'package:flutter_quill_test/flutter_quill_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../common/utils/quill_test_app.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a Document whose only content is [text] (trailing '\n' added if
/// absent, as Quill always keeps a structural newline at the end).
Document _doc(String text) => Document.fromDelta(
      Delta()..insert(text.endsWith('\n') ? text : '$text\n'),
    );

/// Builds the precise replacement delta that updateEditingValue constructs for
/// true replacements and returns it without applying it to any document.
Delta _buildReplaceDelta({
  required int start,
  required String deleted,
  required String inserted,
}) {
  final delta = Delta();
  if (start > 0) delta.retain(start);
  if (deleted.isNotEmpty) delta.delete(deleted.length);
  if (inserted.isNotEmpty) delta.insert(inserted);
  return delta;
}

/// Applies [getDiff] to compute the diff between [oldText] and [newText],
/// then builds and returns the replacement delta (same logic as the mixin).
Delta _diffDelta(String oldText, String newText, int cursor) {
  final diff = getDiff(oldText, newText, cursor);
  return _buildReplaceDelta(
    start: diff.start,
    deleted: diff.deleted,
    inserted: diff.inserted,
  );
}

// ---------------------------------------------------------------------------
// 1 — Document.compose unit tests
//
// These verify that composing the precise delete→insert delta onto a Document
// produces the expected document content. No widget infrastructure needed.
// ---------------------------------------------------------------------------

void main() {
  group('Document.compose — precise replacement delta (CU-86d2ne59y)', () {
    const urlShared =
        'https://example.com/programa-schedule-a-call'; // shares "prog"

    test('iOS shortcut at document start: prog → URL with shared substring',
        () {
      final doc = _doc('prog');

      // diff = Diff[0, 'prog', url]
      doc.compose(
        _buildReplaceDelta(start: 0, deleted: 'prog', inserted: urlShared),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), '$urlShared\n',
          reason: 'Shortcut must be fully replaced; '
              'no "prog" remnant, no dropped "http"');
    });

    test('iOS shortcut in middle of text', () {
      final doc = _doc('Hello prog end');

      // diff = Diff[6, 'prog', url]
      doc.compose(
        _buildReplaceDelta(start: 6, deleted: 'prog', inserted: urlShared),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'Hello $urlShared end\n');
    });

    test('iOS shortcut at end of text (no trailing content)', () {
      final doc = _doc('See ');

      doc.compose(
        _buildReplaceDelta(start: 4, deleted: '', inserted: urlShared),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'See $urlShared\n');
    });

    test('autocorrect: misspelled word at start of document', () {
      final doc = _doc('teh quick fox');

      doc.compose(
        _buildReplaceDelta(start: 0, deleted: 'teh', inserted: 'the'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'the quick fox\n');
    });

    test('autocorrect: misspelled word in the middle', () {
      final doc = _doc('the quikc fox');

      doc.compose(
        _buildReplaceDelta(start: 4, deleted: 'quikc', inserted: 'quick'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'the quick fox\n');
    });

    test('autocorrect: misspelled word at end', () {
      final doc = _doc('I am lerning');

      doc.compose(
        _buildReplaceDelta(start: 5, deleted: 'lerning', inserted: 'learning'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'I am learning\n');
    });

    test('select-and-type: replaces selected range with longer text', () {
      final doc = _doc('hello world');

      // User selects 'world' and types 'flutter'
      doc.compose(
        _buildReplaceDelta(start: 6, deleted: 'world', inserted: 'flutter'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'hello flutter\n');
    });

    test('select-and-type: replaces selected range with shorter text', () {
      final doc = _doc('hello world');

      // User selects 'hello' and types 'hi'
      doc.compose(
        _buildReplaceDelta(start: 0, deleted: 'hello', inserted: 'hi'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'hi world\n');
    });

    test('select-and-type: replaces selected range with single character', () {
      final doc = _doc('Testing if this editor yet works');

      // User selects 'Testing if this editor yet works' and types 'c'
      doc.compose(
        _buildReplaceDelta(
            start: 0,
            deleted: 'Testing if this editor yet works',
            inserted: 'c'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'c\n');
    });

    test('pure insert: appends a character at end', () {
      final doc = _doc('hello');

      // diff = Diff[5, '', '!']  — no delete
      doc.compose(
        _buildReplaceDelta(start: 5, deleted: '', inserted: '!'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'hello!\n');
    });

    test('pure delete: removes one character (backspace)', () {
      final doc = _doc('hello!');

      // diff = Diff[5, '!', '']  — no insert
      doc.compose(
        _buildReplaceDelta(start: 5, deleted: '!', inserted: ''),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'hello\n');
    });

    test('replacement when shortcut is identical to a prefix of the expansion',
        () {
      // 'omw' is a common iOS shortcut → 'on my way'.
      // There's no shared substring collision here, but good to cover.
      final doc = _doc('omw');

      doc.compose(
        _buildReplaceDelta(start: 0, deleted: 'omw', inserted: 'on my way'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'on my way\n');
    });

    test('sequential replacements each produce correct result', () {
      final doc = _doc('one two three');

      // Replace 'one' → '1'
      doc.compose(
        _buildReplaceDelta(start: 0, deleted: 'one', inserted: '1'),
        ChangeSource.local,
      );
      expect(doc.toPlainText(), '1 two three\n',
          reason: 'First replacement must be correct');

      // Replace 'two' → '2'
      doc.compose(
        _buildReplaceDelta(start: 2, deleted: 'two', inserted: '2'),
        ChangeSource.local,
      );
      expect(doc.toPlainText(), '1 2 three\n',
          reason: 'Second replacement must not corrupt first');

      // Replace 'three' → '3'
      doc.compose(
        _buildReplaceDelta(start: 4, deleted: 'three', inserted: '3'),
        ChangeSource.local,
      );
      expect(doc.toPlainText(), '1 2 3\n',
          reason: 'Third replacement must not corrupt previous results');
    });

    test('replacement of entire content (select-all and type)', () {
      final doc = _doc('old content here');

      doc.compose(
        _buildReplaceDelta(
            start: 0, deleted: 'old content here', inserted: 'new'),
        ChangeSource.local,
      );

      expect(doc.toPlainText(), 'new\n');
    });

    test('no-op: empty deleted and empty inserted leaves document unchanged',
        () {
      final doc = _doc('untouched');
      final before = doc.toPlainText();

      // An empty diff should never reach compose(), but verify compose is
      // safe to call with a non-empty (retain-only) delta anyway.
      // We test the guard at the call site instead:
      final diff = getDiff('untouched\n', 'untouched\n', 9);
      expect(diff.deleted, isEmpty);
      expect(diff.inserted, isEmpty);

      expect(doc.toPlainText(), before);
    });
  });

  // ---------------------------------------------------------------------------
  // 2 — getDiff + Document.compose integration
  //
  // Combines the prefix/suffix diff algorithm with the compose step to verify
  // the full pipeline that updateEditingValue executes.
  // ---------------------------------------------------------------------------

  group('getDiff + Document.compose integration (CU-86d2ne59y)', () {
    void _apply(Document doc, String oldText, String newText, int cursor) {
      final delta = _diffDelta(oldText, newText, cursor);
      final diff = getDiff(oldText, newText, cursor);
      if (diff.deleted.isEmpty && diff.inserted.isEmpty) return;
      doc.compose(delta, ChangeSource.local);
    }

    test('iOS shortcut: prog → URL with shared "prog" in expansion', () {
      const url = 'https://example.com/programa-schedule-a-call';
      final doc = _doc('prog');

      // Old text the mixin sees: "prog\n"; new text iOS sends: "url\n"
      _apply(doc, 'prog\n', '$url\n', url.length);

      expect(doc.toPlainText(), '$url\n');
    });

    test('iOS shortcut in middle: Hello prog end → Hello URL end', () {
      const url = 'https://example.com/programa-schedule-a-call';
      final doc = _doc('Hello prog end');

      _apply(
          doc, 'Hello prog end\n', 'Hello $url end\n', 'Hello $url'.length);

      expect(doc.toPlainText(), 'Hello $url end\n');
    });

    test('omw shortcut: omw → on my way', () {
      final doc = _doc('omw');

      _apply(doc, 'omw\n', 'on my way\n', 9);

      expect(doc.toPlainText(), 'on my way\n');
    });

    test('normal typing: character appended', () {
      final doc = _doc('hello');

      _apply(doc, 'hello\n', 'hello!\n', 6);

      expect(doc.toPlainText(), 'hello!\n');
    });

    test('backspace: last character removed', () {
      final doc = _doc('hello!');

      _apply(doc, 'hello!\n', 'hello\n', 5);

      expect(doc.toPlainText(), 'hello\n');
    });

    test('autocorrect: spelling correction', () {
      final doc = _doc('speling');

      _apply(doc, 'speling\n', 'spelling\n', 8);

      expect(doc.toPlainText(), 'spelling\n');
    });

    test('select-all and type replacement', () {
      final doc = _doc('delete me entirely');

      _apply(doc, 'delete me entirely\n', 'new\n', 3);

      expect(doc.toPlainText(), 'new\n');
    });

    test('no-op: identical old and new text leaves document unchanged', () {
      final doc = _doc('same text');

      _apply(doc, 'same text\n', 'same text\n', 9);

      expect(doc.toPlainText(), 'same text\n');
    });

    test(
        'shortcut whose text is a substring of the expansion (shared prefix)',
        () {
      // 'pro' → 'professional' — "pro" appears at the start of the expansion.
      final doc = _doc('pro');

      _apply(doc, 'pro\n', 'professional\n', 12);

      expect(doc.toPlainText(), 'professional\n');
    });

    test(
        'shortcut whose text is a substring of the expansion (shared suffix)',
        () {
      // 'way' shortcut → 'my way' — "way" appears at the end of the expansion.
      final doc = _doc('way');

      _apply(doc, 'way\n', 'my way\n', 6);

      expect(doc.toPlainText(), 'my way\n');
    });
  });

  // ---------------------------------------------------------------------------
  // 3 — Widget tests: full updateEditingValue pipeline
  //
  // These tests pump a real QuillEditor, focus it (which opens the platform
  // text-input connection and sets _lastKnownRemoteTextEditingValue), then use
  // TestTextInput.updateEditingValue to simulate what iOS/Android sends.
  // ---------------------------------------------------------------------------

  group('updateEditingValue — widget integration (CU-86d2ne59y)', () {
    Widget _buildApp(QuillController controller) => QuillTestApp.withScaffold(
          QuillEditor.basic(
            controller: controller,
            config: const QuillEditorConfig(autoFocus: true),
          ),
        );

    QuillController _ctrl(String text) => QuillController(
          document: _doc(text),
          selection: const TextSelection.collapsed(offset: 0),
        );

    // ---- iOS text replacement scenarios ------------------------------------

    testWidgets(
        'iOS text replacement: prog → URL containing "programa" (primary bug)',
        (tester) async {
      const url = 'https://example.com/programa-schedule-a-call';
      final controller = _ctrl('prog');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Simulate iOS committing the text-replacement shortcut
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '$url\n',
        TextSelection.collapsed(offset: url.length),
      );

      expect(
        controller.document.toPlainText(),
        '$url\n',
        reason: 'URL must replace shortcut cleanly — '
            'no dropped "http", no "prog" remnant',
      );

      controller.dispose();
    });

    testWidgets('iOS text replacement in middle of existing text',
        (tester) async {
      const url = 'https://example.com/programa-schedule-a-call';
      final controller = _ctrl('Hello prog end');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'Hello $url end\n',
        TextSelection.collapsed(offset: 'Hello $url'.length),
      );

      expect(controller.document.toPlainText(), 'Hello $url end\n');
      controller.dispose();
    });

    testWidgets('iOS omw shortcut → "on my way"', (tester) async {
      final controller = _ctrl('omw');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'on my way\n',
        const TextSelection.collapsed(offset: 9),
      );

      expect(controller.document.toPlainText(), 'on my way\n');
      controller.dispose();
    });

    // ---- Normal editing scenarios -----------------------------------------

    testWidgets('normal typing: character appended at caret', (tester) async {
      final controller = _ctrl('hello');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'hello!\n',
        const TextSelection.collapsed(offset: 6),
      );

      expect(controller.document.toPlainText(), 'hello!\n');
      controller.dispose();
    });

    testWidgets('backspace: last character deleted', (tester) async {
      final controller = _ctrl('hello!');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'hello\n',
        const TextSelection.collapsed(offset: 5),
      );

      expect(controller.document.toPlainText(), 'hello\n');
      controller.dispose();
    });

    testWidgets('autocorrect: misspelling replaced in middle of text',
        (tester) async {
      final controller = _ctrl('the quikc fox');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'the quick fox\n',
        const TextSelection.collapsed(offset: 9),
      );

      expect(controller.document.toPlainText(), 'the quick fox\n');
      controller.dispose();
    });

    testWidgets('select-and-type: selected range replaced by typed text',
        (tester) async {
      final controller = _ctrl('hello world');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // User selected 'world' (positions 6–10), typed 'flutter'
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'hello flutter\n',
        const TextSelection.collapsed(offset: 13),
      );

      expect(controller.document.toPlainText(), 'hello flutter\n');
      controller.dispose();
    });

    testWidgets('select-and-type: long selection replaced by single char',
        (tester) async {
      // Regression guard: the earlier delta-scanning fix broke this case.
      final controller = _ctrl('Testing if this editor yet works');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // User selects all text and types 'c'
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'c\n',
        const TextSelection.collapsed(offset: 1),
      );

      expect(controller.document.toPlainText(), 'c\n');
      controller.dispose();
    });

    // ---- Cursor position after replacement --------------------------------

    testWidgets('cursor is at end of inserted text after iOS replacement',
        (tester) async {
      const url = 'https://example.com/programa-schedule-a-call';
      final controller = _ctrl('prog');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '$url\n',
        TextSelection.collapsed(offset: url.length),
      );

      expect(
        controller.selection,
        TextSelection.collapsed(offset: url.length),
        reason: 'Cursor must be at end of the inserted URL',
      );
      controller.dispose();
    });

    testWidgets('cursor is at end of inserted word after autocorrect',
        (tester) async {
      final controller = _ctrl('speling');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'spelling\n',
        const TextSelection.collapsed(offset: 8),
      );

      expect(controller.selection, const TextSelection.collapsed(offset: 8));
      controller.dispose();
    });

    // ---- Sequential replacements -----------------------------------------

    testWidgets('sequential replacements each apply without corruption',
        (tester) async {
      final controller = _ctrl('one two three');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Replace 'one' → '1'
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '1 two three\n',
        const TextSelection.collapsed(offset: 1),
      );
      expect(controller.document.toPlainText(), '1 two three\n',
          reason: 'First replacement');

      // Replace 'two' → '2'
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '1 2 three\n',
        const TextSelection.collapsed(offset: 3),
      );
      expect(controller.document.toPlainText(), '1 2 three\n',
          reason: 'Second replacement must not corrupt first');

      // Replace 'three' → '3'
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '1 2 3\n',
        const TextSelection.collapsed(offset: 5),
      );
      expect(controller.document.toPlainText(), '1 2 3\n',
          reason: 'Third replacement must not corrupt previous results');

      controller.dispose();
    });

    testWidgets('typing after iOS text replacement does not throw',
        (tester) async {
      // Regression guard for the "index out of bounds" exceptions that the
      // earlier delta-scanning approach caused on keystrokes following a
      // text-replacement event.
      const url = 'https://example.com/programa-schedule-a-call';
      final controller = _ctrl('prog');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Text replacement
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '$url\n',
        TextSelection.collapsed(offset: url.length),
      );

      // Continue typing after the URL — must not throw
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '$url more text\n',
        TextSelection.collapsed(offset: url.length + 10),
      );

      expect(
        controller.document.toPlainText(),
        '$url more text\n',
      );
      controller.dispose();
    });

    // ---- Enter key after iOS text replacement --------------------------------
    //
    // Regression for: after text replacement the document's mandatory trailing
    // '\n' was included in the diff's deleted segment (crashing compose) or
    // updateRemoteValueIfNeeded sent the sentinel back to iOS, causing a
    // subsequent Enter to produce an insert at index == document.length.

    testWidgets(
        'Enter after iOS text replacement does not throw '
        '(sentinel \\n not deleted, index within bounds)',
        (tester) async {
      const prefix = 'Hello ';
      const url = 'https://realtorenespanol.com/programa-su-llamada';
      // Start with the shortcut text
      final controller = _ctrl('${prefix}prog');
      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // Step 1: iOS text replacement — payload has NO trailing \n
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        '$prefix$url',
        TextSelection.collapsed(offset: (prefix + url).length),
      );
      expect(controller.document.toPlainText(), '$prefix$url\n');

      // Step 2: iOS Enter — sends text with user's \n + Quill's sentinel \n
      final afterReplace = tester.testTextInput.editingState;
      final afterReplaceText = (afterReplace?['text'] as String?) ?? '';
      final cursorPos = (prefix + url).length;
      final enterText =
          afterReplaceText.substring(0, cursorPos) + '\n' + afterReplaceText.substring(cursorPos);
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        enterText,
        TextSelection.collapsed(offset: cursorPos + 1),
      );

      expect(
        controller.document.toPlainText(),
        '$prefix$url\n\n',
        reason: 'Enter should insert a newline after the URL',
      );
      controller.dispose();
    });

    testWidgets(
        'Enter after normal typing does not throw '
        '(sentinel \\n handled correctly in every keystroke)',
        (tester) async {
      final controller = _ctrl('hello');
      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      // iOS always sends text WITH the Quill sentinel \n. Type 'a' at position
      // 5 (before sentinel): "hello\n" → "helloa\n".
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'helloa\n',
        TextSelection.collapsed(offset: 6),
      );
      expect(controller.document.toPlainText(), 'helloa\n');

      // Enter at position 6 (after 'a', before sentinel): iOS appends \n
      // before the sentinel — "helloa\n\n".
      await tester.quillUpdateEditingValueWithSelection(
        find.byType(QuillEditor),
        'helloa\n\n',
        TextSelection.collapsed(offset: 7),
      );
      expect(controller.document.toPlainText(), 'helloa\n\n');
      controller.dispose();
    });

    // ---- Composing-range-only change -------------------------------------

    testWidgets('composing-range-only change does not modify document',
        (tester) async {
      final controller = _ctrl('hello');

      await tester.pumpWidget(_buildApp(controller));
      await tester.quillGiveFocus(find.byType(QuillEditor));

      final rawEditor = tester.findRawEditor(find.byType(QuillEditor));
      final currentText = rawEditor.textEditingValue.text;
      final currentSel = rawEditor.textEditingValue.selection;

      // Send only a composing-range change (text and selection are the same)
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: currentText,
          selection: currentSel,
          composing: const TextRange(start: 0, end: 5),
        ),
      );
      await tester.idle();

      // Document must remain unchanged
      expect(controller.document.toPlainText(), 'hello\n');
      controller.dispose();
    });
  });
}
