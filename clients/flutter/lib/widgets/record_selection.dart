import 'package:flutter/material.dart';

/// The rows a user ticked in a [RecordList] (pass one as `selection` to turn the checkboxes on). It keeps the whole row, so a selection can
/// span pages and survive a reload, and a screen reads `rows` to print or export them.
class RecordSelection extends ChangeNotifier {
  final _rows = <Object, Map<String, dynamic>>{};

  static Object keyOf(Map<String, dynamic> row) => row['id'] ?? identityHashCode(row);

  /// The selected rows, in the order they were ticked.
  List<Map<String, dynamic>> get rows => List.unmodifiable(_rows.values);

  int get count => _rows.length;
  bool get isEmpty => _rows.isEmpty;

  bool contains(Map<String, dynamic> row) => _rows.containsKey(keyOf(row));

  void set(Map<String, dynamic> row, bool on) {
    final had = _rows.containsKey(keyOf(row));
    if (on) {
      _rows[keyOf(row)] = row;
    } else {
      _rows.remove(keyOf(row));
    }
    if (had != on) notifyListeners();
  }

  void toggle(Map<String, dynamic> row) => set(row, !contains(row));

  void addAll(Iterable<Map<String, dynamic>> rows) {
    for (final r in rows) {
      _rows[keyOf(r)] = r;
    }
    notifyListeners();
  }

  void clear() {
    if (_rows.isEmpty) return;
    _rows.clear();
    notifyListeners();
  }
}
