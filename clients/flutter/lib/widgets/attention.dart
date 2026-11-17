import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'pipeline.dart' show Tone, toneColors;

/// One thing that needs attention on a list (suspected duplicates, incomplete registers): what it says and what opening it does.
class AttentionNotice {
  const AttentionNotice(this.icon, this.text, this.onOpen);

  final IconData icon;
  final String text;
  final VoidCallback onOpen;
}

/// A warning strip above a list with a message and an X. The X hides it for good on this computer, until the count grows (new problems show it again).
/// The way to look at the problem is the [AttentionButton] of the list's toolbar, which is there as long as the problem is.
class NoticeStrip extends StatefulWidget {
  const NoticeStrip({super.key, required this.id, required this.count, required this.icon, required this.text, this.stripKey});

  /// Names the notice in the stored preference ("customers-duplicates").
  final String id;

  /// How many problems there are now; a dismissed strip comes back when this grows past what was dismissed.
  final int count;
  final IconData icon;
  final String text;
  final Key? stripKey;

  @override
  State<NoticeStrip> createState() => _NoticeStripState();
}

class _NoticeStripState extends State<NoticeStrip> {
  int? _dismissedAt;
  bool _loaded = false;

  String get _key => 'notice:${widget.id}';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _dismissedAt = prefs.getInt(_key);
    } catch (e) {
      debugPrint('attention: dismissal not read: $e');
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _dismiss() async {
    setState(() => _dismissedAt = widget.count);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, widget.count);
    } catch (e) {
      debugPrint('attention: dismissal not saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || widget.count <= 0 || (_dismissedAt != null && widget.count <= _dismissedAt!)) return const SizedBox.shrink();
    final (bg, fg) = toneColors(context, Tone.warning);
    return Padding(
      key: widget.stripKey,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(widget.text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: fg)),
                ),
              ),
              IconButton(
                key: ValueKey('dismiss-notice-${widget.id}'),
                tooltip: 'Dispensar este aviso',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: fg,
                onPressed: _dismiss,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The warning button of a list's toolbar, beside "Selecionar" and "Atualizar": there while the list has something to look at, with the number of
/// notices on it; it opens a menu of them. Nothing when there is none.
class AttentionButton extends StatelessWidget {
  const AttentionButton({super.key, required this.notices});

  final List<AttentionNotice> notices;

  @override
  Widget build(BuildContext context) {
    if (notices.isEmpty) return const SizedBox.shrink();
    final (_, fg) = toneColors(context, Tone.warning);
    return PopupMenuButton<int>(
      key: const ValueKey('attention-button'),
      tooltip: 'Atenção: ${notices.length} ${notices.length == 1 ? 'aviso' : 'avisos'}',
      icon: Badge(label: Text('${notices.length}'), child: Icon(Icons.warning_amber_rounded, color: fg)),
      onSelected: (i) => notices[i].onOpen(),
      itemBuilder: (_) => [
        for (final (i, n) in notices.indexed)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(n.icon, size: 18),
                const SizedBox(width: 10),
                Flexible(child: Text(n.text)),
              ],
            ),
          ),
      ],
    );
  }
}

/// How many groups of suspected duplicates each kind has, loaded once per session and shared by the strip and the toolbar button of the same list.
class DuplicatesInfo {
  DuplicatesInfo._();

  static final _counts = <String, ValueNotifier<int>>{};

  static String _id(ApiClient api, String kind) => '${identityHashCode(api)}:$kind';

  /// The count for [kind] ('customers', 'products', 'suppliers'); starts a load the first time it is asked for.
  static ValueNotifier<int> of(ApiClient api, String kind) {
    final id = _id(api, kind);
    final existing = _counts[id];
    if (existing != null) return existing;
    final n = _counts[id] = ValueNotifier<int>(0);
    unawaited(refresh(api, kind));
    return n;
  }

  /// Asks the server again (after a group was settled or a pair dismissed). A failure keeps the last count: this is a hint, never a reason to hide a screen.
  static Future<void> refresh(ApiClient api, String kind) async {
    final n = _counts.putIfAbsent(_id(api, kind), () => ValueNotifier<int>(0));
    try {
      final r = await api.get('/api/duplicates/$kind');
      n.value = r is Map ? (r['groups'] as List?)?.length ?? 0 : 0;
    } catch (e) {
      debugPrint('duplicates: count not loaded: $e');
    }
  }
}
