import 'package:flutter/services.dart';
import 'package:flutter_quill/src/delta/delta_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // getDiff — prefix/suffix-based algorithm
  // ---------------------------------------------------------------------------
  group('getDiff', () {
    test(
        'produces correct diff when shortcut shares a substring with expansion'
        ' (iOS text replacement — no composing range)', () {
      // The critical regression case: shortcut `prog` expands to a URL that
      // contains `programa`. The old cursor-anchored heuristic collided on the
      // shared `prog` prefix and produced a malformed op. The prefix+suffix
      // algorithm finds the minimal edit without cursor position help.
      const oldText = 'prog';
      const newText = 'https://example.com/programa-schedule-a-call';

      final diff = getDiff(oldText, newText, newText.length);

      expect(diff.start, 0);
      expect(diff.deleted, 'prog');
      expect(diff.inserted, newText);
    });

    test('correct diff when shortcut replacement is in the middle of text', () {
      // "Hello " is the common prefix; " have a nice day" is the common
      // suffix — the algorithm correctly isolates only "prog" as deleted.
      const oldText = 'Hello prog have a nice day';
      const newText =
          'Hello https://example.com/programa-schedule-a-call have a nice day';

      final cursorPosition =
          'Hello https://example.com/programa-schedule-a-call'.length;
      final diff = getDiff(oldText, newText, cursorPosition);

      expect(diff.start, 6); // after 'Hello '
      expect(diff.deleted, 'prog');
      expect(diff.inserted, 'https://example.com/programa-schedule-a-call');
    });

    test('appends a character (normal typing)', () {
      final diff = getDiff('abc', 'abcd', 4);

      expect(diff.start, 3);
      expect(diff.deleted, '');
      expect(diff.inserted, 'd');
    });

    test('deletes a character (backspace)', () {
      final diff = getDiff('abcd', 'abc', 3);

      expect(diff.start, 3);
      expect(diff.deleted, 'd');
      expect(diff.inserted, '');
    });

    test('replaces a character in the middle', () {
      final diff = getDiff('axc', 'abc', 2);

      expect(diff.start, 1);
      expect(diff.deleted, 'x');
      expect(diff.inserted, 'b');
    });

    test('handles completely different strings', () {
      final diff = getDiff('old', 'new', 3);

      expect(diff.start, 0);
      expect(diff.deleted, 'old');
      expect(diff.inserted, 'new');
    });

    test('handles empty old text (first keystroke)', () {
      final diff = getDiff('', 'a', 1);

      expect(diff.start, 0);
      expect(diff.deleted, '');
      expect(diff.inserted, 'a');
    });

    test('handles empty new text (select-all delete)', () {
      final diff = getDiff('abc', '', 0);

      expect(diff.start, 0);
      expect(diff.deleted, 'abc');
      expect(diff.inserted, '');
    });

    test('returns empty diff for identical strings', () {
      final diff = getDiff('same', 'same', 4);

      expect(diff.deleted, '');
      expect(diff.inserted, '');
    });
  });

  // ---------------------------------------------------------------------------
  // computeTextReplacementDiff — composing-range fast path (IME / marked text)
  // ---------------------------------------------------------------------------
  group('computeTextReplacementDiff', () {
    test(
        'recovers exact diff when iOS expands shortcut that shares a substring'
        ' with the expansion', () {
      // Shortcut `prog` expands to a URL containing `programa`. The native
      // `getDiff` forward/backward scan collides on the shared `prog`
      // substring and drops `http` + leaves `prog` at the tail.
      // `computeTextReplacementDiff` must recover the intended replacement
      // from the composing range.
      const oldText = 'prog';
      const newText = 'https://example.com/programa-schedule-a-call';

      final diff = computeTextReplacementDiff(
        oldText: oldText,
        oldComposing: const TextRange(start: 0, end: 4),
        newText: newText,
        newComposing: TextRange.empty,
        newSelection:
            const TextSelection.collapsed(offset: newText.length),
      );

      expect(diff, isNotNull);
      expect(diff!.start, 0);
      expect(diff.deleted, 'prog');
      expect(diff.inserted, newText);
    });

    test('recovers diff when replacement happens in the middle of existing'
        ' text', () {
      // Shortcut in the middle of a sentence.
      const oldText = 'Hello omw have a nice day';
      const newText = 'Hello on my way have a nice day';

      final diff = computeTextReplacementDiff(
        oldText: oldText,
        oldComposing: const TextRange(start: 6, end: 9),
        newText: newText,
        newComposing: TextRange.empty,
        newSelection: const TextSelection.collapsed(offset: 15),
      );

      expect(diff, isNotNull);
      expect(diff!.start, 6);
      expect(diff.deleted, 'omw');
      expect(diff.inserted, 'on my way');
    });

    test('returns null when the previous composing range is missing', () {
      // Normal typing — no composing range on the old value.
      final diff = computeTextReplacementDiff(
        oldText: 'abc',
        oldComposing: TextRange.empty,
        newText: 'abcd',
        newComposing: TextRange.empty,
        newSelection: const TextSelection.collapsed(offset: 4),
      );

      expect(diff, isNull);
    });

    test('returns null when the new composing range is still active', () {
      // User is still composing — not a commit.
      final diff = computeTextReplacementDiff(
        oldText: 'prog',
        oldComposing: const TextRange(start: 0, end: 4),
        newText: 'program',
        newComposing: const TextRange(start: 0, end: 7),
        newSelection: const TextSelection.collapsed(offset: 7),
      );

      expect(diff, isNull);
    });

    test('returns null when the new selection is not collapsed', () {
      // Selection highlighted — not a replacement commit.
      final diff = computeTextReplacementDiff(
        oldText: 'prog',
        oldComposing: const TextRange(start: 0, end: 4),
        newText: 'program',
        newComposing: TextRange.empty,
        newSelection: const TextSelection(baseOffset: 0, extentOffset: 7),
      );

      expect(diff, isNull);
    });

    test('returns null when surrounding text does not match', () {
      // The non-composing portion of the text changed — cannot have been a
      // single iOS text-replacement commit. Fall back to getDiff.
      final diff = computeTextReplacementDiff(
        oldText: 'Hi prog!',
        oldComposing: const TextRange(start: 3, end: 7),
        newText: 'Hello programming',
        newComposing: TextRange.empty,
        newSelection: const TextSelection.collapsed(offset: 17),
      );

      expect(diff, isNull);
    });

    test('returns null when computed insert length would be negative', () {
      final diff = computeTextReplacementDiff(
        oldText: 'abcdef',
        oldComposing: const TextRange(start: 2, end: 5),
        newText: 'ab',
        newComposing: TextRange.empty,
        newSelection: const TextSelection.collapsed(offset: 0),
      );

      expect(diff, isNull);
    });
  });
}
