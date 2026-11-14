import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Bounded, throttled log store. Notifies listeners at most every 150 ms so a
/// chatty cloudflared does not rebuild the UI for every single line.
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.maxLines = 1500});

  final int maxLines;
  final List<String> _lines = [];
  Timer? _debounce;

  UnmodifiableListView<String> get lines => UnmodifiableListView(_lines);
  int get length => _lines.length;
  String get text => _lines.join('\n');

  void add(String line) {
    _lines.add(line);
    _trim();
    _scheduleNotify();
  }

  void addAll(Iterable<String> lines) {
    _lines.addAll(lines);
    _trim();
    _scheduleNotify();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  List<String> tail(int n) =>
      _lines.length <= n ? List.of(_lines) : _lines.sublist(_lines.length - n);

  void _trim() {
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  void _scheduleNotify() {
    if (_debounce?.isActive ?? false) return;
    _debounce = Timer(const Duration(milliseconds: 150), notifyListeners);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
