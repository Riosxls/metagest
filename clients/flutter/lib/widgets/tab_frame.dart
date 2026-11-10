import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Screens that share one sidebar entry: the entry opens the first tab, the others are reached from the strip above the screen.
class TabGroup {
  const TabGroup(this.section, this.title, this.icon, this.tabs);

  final String section;
  final String title;
  final IconData icon;
  final List<({String id, String label})> tabs;

  bool has(String id) => tabs.any((t) => t.id == id);

  /// The name of a tab when it differs from the group's own ("Expedição" > "Certificados"), else null.
  String? tabLabel(String id) {
    for (final t in tabs) {
      if (t.id == id) return t.label == title ? null : t.label;
    }
    return null;
  }
}

/// Strip of tabs of a [TabGroup]. A tab is a normal screen of the shell, so [onSelect] navigates and each tab keeps its own state.
/// The selected tab scrolls into view (a phone shows only three or four), and Left / Right move between the tabs.
class TabStrip extends StatefulWidget {
  const TabStrip({super.key, required this.tabs, required this.current, required this.onSelect});

  final List<({String id, String label})> tabs;
  final String current;
  final ValueChanged<String> onSelect;

  @override
  State<TabStrip> createState() => _TabStripState();
}

/// One tab of a [TabStrip]: the label with a bar under it when [selected]. [anchor] marks it for scrolling into view.
class StripTab extends StatelessWidget {
  const StripTab({super.key, required this.anchor, required this.label, required this.selected, required this.onTap});

  final GlobalKey anchor;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: anchor,
        onTap: onTap,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(label, style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
              const SizedBox(height: 10),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 3,
                decoration: BoxDecoration(color: selected ? theme.colorScheme.primary : Colors.transparent, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabStripState extends State<TabStrip> {
  final _chips = <String, GlobalKey>{};

  GlobalKey _key(String id) => _chips.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(TabStrip old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current || old.tabs.length != widget.tabs.length) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final c = _chips[widget.current]?.currentContext;
    if (mounted && c != null && c.mounted) unawaited(Scrollable.ensureVisible(c, alignment: 0.5, duration: const Duration(milliseconds: 180)));
  });

  void _step(int delta) {
    final i = widget.tabs.indexWhere((t) => t.id == widget.current);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= widget.tabs.length) return;
    widget.onSelect(widget.tabs[j].id);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: 'Abas',
    child: FocusTraversalGroup(
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1), const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1)},
        // Tabs in the usual sense: plain text on a line, the current one in the accent colour with a bar under it (the strip of the customer page looks the same).
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                for (final t in widget.tabs)
                  StripTab(
                    key: ValueKey('tab-${t.id}'),
                    anchor: _key(t.id),
                    label: t.label,
                    selected: t.id == widget.current,
                    onTap: () {
                      if (t.id != widget.current) widget.onSelect(t.id);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
