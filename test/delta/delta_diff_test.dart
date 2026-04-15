import 'package:flutter/services.dart';
import 'package:flutter_quill/src/delta/delta_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
