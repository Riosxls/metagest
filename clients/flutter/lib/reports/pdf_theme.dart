import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// Shared PDF fonts and theme for every document builder. The Roboto files are read and parsed once per app run, not once per PDF.
///
/// [italicAsRegular] maps italic text to the regular face (Roboto italic is not bundled): used by the NF and DANFE papers.
Future<pw.ThemeData> pdfTheme({bool italicAsRegular = false}) async {
  // The parsed fonts are remembered, not the Future that produced them: a finished Future from another zone (a previous widget test) would never call back.
  final f = _loaded ?? await _loadFonts();
  return pw.ThemeData.withFont(base: f.regular, bold: f.bold, italic: italicAsRegular ? f.regular : null);
}

typedef _Fonts = ({pw.Font regular, pw.Font bold});

_Fonts? _loaded;
Future<_Fonts>? _loading;

Future<_Fonts> _loadFonts() => _loading ??= () async {
  try {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/roboto-regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/roboto-bold.ttf'));
    return _loaded = (regular: regular, bold: bold);
  } finally {
    // Success is remembered in [_loaded]; after a failure the next document tries again.
    _loading = null;
  }
}();

/// Whether the last [savePdf] ran in another isolate; for tests.
@visibleForTesting
bool lastSaveOffThread = false;

/// Final step of every builder: lays out and serializes the document. With [offThread] (a long report: thousands of table rows) the work runs in another isolate, so the
/// screen does not freeze while the pages are laid out; the document travels with its page closures and fonts, and when that cannot be sent (a closure capturing something that
/// cannot cross isolates, or the web, which has none) it is saved here instead. Short papers stay on the calling isolate: copying them costs more than saving them.
Future<Uint8List> savePdf(pw.Document doc, {bool offThread = false}) async {
  lastSaveOffThread = false;
  if (offThread && !kIsWeb) {
    try {
      final bytes = await compute(_saveInIsolate, doc);
      lastSaveOffThread = true;
      return bytes;
    } catch (e) {
      debugPrint('pdf: could not save in an isolate, saving here: $e');
    }
  }
  return doc.save();
}

Future<Uint8List> _saveInIsolate(pw.Document doc) => doc.save();
