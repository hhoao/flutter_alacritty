import 'package:flutter/foundation.dart';

/// Sticky virtual modifiers for touch accessory keys.
class ModifierLatch extends ChangeNotifier {
  bool ctrl = false;
  bool alt = false;
  bool shift = false;

  void toggleCtrl() {
    ctrl = !ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    alt = !alt;
    notifyListeners();
  }

  void toggleShift() {
    shift = !shift;
    notifyListeners();
  }

  void clear() {
    if (!ctrl && !alt && !shift) return;
    ctrl = false;
    alt = false;
    shift = false;
    notifyListeners();
  }

  /// Auto-off after an effective send that consumed the latch.
  void consumeAfterSend() => clear();
}
