import 'dart:math' as math;
import 'dart:ui' show TextDirection, TextRange;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show TextSelection;

import '../../quill_delta.dart';
import '../document/attribute.dart';
import '../document/nodes/node.dart';

// Diff between two texts - old text and new text
@immutable
class Diff {
  const Diff({
    required this.start,
    required this.deleted,
    required this.inserted,
  });

  // Start index in old text at which changes begin.
  final int start;

  /// The deleted text
  final String deleted;

  // The inserted text
  final String inserted;

  @override
  String toString() {
    return 'Diff[$start, "$deleted", "$inserted"]';
  }
}

/// Get diff operation between old text and new text.
///
/// Uses a longest-common-prefix + longest-common-suffix scan to find the
/// minimal edit region. This correctly handles cases where the deleted text
/// shares a substring with the inserted text — for example, an iOS system
/// text-replacement shortcut (e.g. `prog`) whose shortcut word appears inside
/// the expansion (e.g. a URL containing `programa`). The previous
/// cursor-position-anchored heuristic misaligned the start/end pointers in
/// such cases, producing a malformed Delta op.
///
/// [cursorPosition] is kept in the signature for API compatibility but is no
/// longer used in the computation.
Diff getDiff(String oldText, String newText, int cursorPosition) {
  // Find the length of the longest common prefix.
  final maxPrefix = math.min(oldText.length, newText.length);
  var start = 0;
  while (start < maxPrefix && oldText[start] == newText[start]) {
    start++;
  }

  // Find the length of the longest common suffix, not overlapping the prefix.
  var oldEnd = oldText.length;
  var newEnd = newText.length;
  while (oldEnd > start &&
      newEnd > start &&
      oldText[oldEnd - 1] == newText[newEnd - 1]) {
    oldEnd--;
    newEnd--;
  }

  return Diff(
    start: start,
    deleted: oldText.substring(start, oldEnd),
    inserted: newText.substring(start, newEnd),
  );
}

/// Detects an iOS system text-replacement commit (Settings → General →
/// Keyboard → Text Replacement) and derives the [Diff] directly from the
/// composing range instead of the heuristic [getDiff] scan.
///
/// iOS commits a text replacement in a single `updateEditingValue` where the
/// previous state's composing range marks the shortcut being replaced and the
/// new state's composing is cleared. When the shortcut shares a substring
/// with the expansion (e.g. shortcut `prog` expanding to a URL containing
/// `programa`), [getDiff]'s forward/backward character scan can misalign
/// start/end pointers and produce a malformed op that leaves the shortcut in
/// the document and drops a prefix of the expansion.
///
/// Returns `null` when the change does not match the text-replacement commit
/// signature so callers fall back to the original [getDiff] path.
Diff? computeTextReplacementDiff({
  required String oldText,
  required TextRange oldComposing,
  required String newText,
  required TextRange newComposing,
  required TextSelection newSelection,
}) {
  // Only act when the previous state had an active composing range and the
  // new state has cleared it — that is the signature of a commit.
  if (!oldComposing.isValid || oldComposing.isCollapsed) {
    return null;
  }
  if (newComposing.isValid && !newComposing.isCollapsed) {
    return null;
  }

  // Selection must be collapsed (caret, not a highlighted range) after a
  // replacement commit.
  if (!newSelection.isValid || !newSelection.isCollapsed) {
    return null;
  }

  final cursor = newSelection.extentOffset;
  final start = oldComposing.start;
  final deletedLength = oldComposing.end - oldComposing.start;
  final insertedLength = cursor - start;

  // Bounds checks — bail to the fallback if anything looks off.
  if (start < 0 ||
      deletedLength <= 0 ||
      insertedLength < 0 ||
      start + deletedLength > oldText.length ||
      start + insertedLength > newText.length) {
    return null;
  }

  // Confirm the surrounding context matches: everything before the composing
  // start and everything after the composing end in the old text must be
  // preserved verbatim in the new text.
  final oldTailStart = start + deletedLength;
  final newTailStart = start + insertedLength;
  if (oldText.length - oldTailStart != newText.length - newTailStart) {
    return null;
  }
  if (oldText.substring(0, start) != newText.substring(0, start)) {
    return null;
  }
  if (oldText.substring(oldTailStart) != newText.substring(newTailStart)) {
    return null;
  }

  return Diff(
    start: start,
    deleted: oldText.substring(start, oldTailStart),
    inserted: newText.substring(start, newTailStart),
  );
}

int getPositionDelta(Delta user, Delta actual) {
  if (actual.isEmpty) {
    return 0;
  }

  final userItr = DeltaIterator(user);
  final actualItr = DeltaIterator(actual);
  var diff = 0;
  while (userItr.hasNext || actualItr.hasNext) {
    final length = math.min(userItr.peekLength(), actualItr.peekLength());
    final userOperation = userItr.next(length);
    final actualOperation = actualItr.next(length);
    if (userOperation.length != actualOperation.length) {
      throw ArgumentError(
        'userOp ${userOperation.length} does not match actualOp '
        '${actualOperation.length}',
      );
    }
    if (userOperation.key == actualOperation.key) {
      /// Insertions must update diff allowing for type mismatch of Operation
      if (userOperation.key == Operation.insertKey) {
        if (userOperation.data is Delta && actualOperation.data is String) {
          diff += actualOperation.length!;
        }
      }
      continue;
    } else if (userOperation.isInsert && actualOperation.isRetain) {
      diff -= userOperation.length!;
    } else if (userOperation.isDelete && actualOperation.isRetain) {
      diff += userOperation.length!;
    } else if (userOperation.isRetain && actualOperation.isInsert) {
      diff += actualOperation.length!;
    }
  }
  return diff;
}

TextDirection getDirectionOfNode(Node node, [TextDirection? currentDirection]) {
  final direction = node.style.attributes[Attribute.direction.key];
  // If it is RTL, then create the opposite direction
  if (currentDirection == TextDirection.rtl && direction == Attribute.rtl) {
    return TextDirection.ltr;
  } else if (direction == Attribute.rtl) {
    return TextDirection.rtl;
  }
  return currentDirection ?? TextDirection.ltr;
}
