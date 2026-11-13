import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../reports/pt_text.dart' show ptPhone;
import 'pipeline.dart' show StatusBadge, Tone;

/// Building blocks of the contact-style lists (customers, suppliers, employees): a letter heading per group, a coloured avatar with the initials,
/// the name with a line under it, a few columns and buttons that show when the pointer is over the row. Used with `RecordList.rowBuilder`.

/// The letter a name is filed under ("Aços Divaltec" -> "A"); names that do not start with a letter go under "#".
String contactLetter(String name) {
  final t = name.trim();
  if (t.isEmpty) return '#';
  const from = 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç';
  const to = 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc';
  final c = t[0];
  final i = from.indexOf(c);
  final base = (i >= 0 ? to[i] : c).toUpperCase();
  return RegExp(r'[A-Z]').hasMatch(base) ? base : '#';
}

/// Initials for the avatar: the first letters of the first two words that are not in every company name ("ACOS IDEAL LTDA" -> "AI", "AMVIAN IND E COM DE PECAS" -> "AP").
String contactInitials(String name) {
  const generic = {'de', 'da', 'do', 'das', 'dos', 'e', 'ind', 'industria', 'indústria', 'com', 'comercio', 'comércio', 'ltda', 'eireli', 'epp', 'me', 'sa', 's/a', 'cia'};
  final all = name.trim().split(RegExp(r'\s+')).where((w) => RegExp(r'^[A-Za-zÀ-ú]').hasMatch(w)).toList();
  final words = all.where((w) => !generic.contains(w.toLowerCase().replaceAll('.', ''))).toList();
  final use = words.isEmpty ? all : words;
  if (use.isEmpty) return '?';
  return (use.first[0] + (use.length > 1 ? use[1][0] : '')).toUpperCase();
}

/// The first phone of a field that holds several ("(11) 2958-4633/2682-0000", "... ou ..."), formatted, and how many more there are.
({String first, int more}) contactPhones(Object? raw) {
  final parts = '${raw ?? ''}'.split(RegExp(r'\s*(?:/|;|,|\bou\b)\s*')).where((p) => RegExp(r'\d').hasMatch(p)).toList();
  if (parts.isEmpty) return (first: '', more: 0);
  return (first: ptPhone(parts.first), more: parts.length - 1);
}

/// Copies [text] and says so.
Future<void> copyContact(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copiado')));
}

/// Opens the e-mail program with [to] filled in.
Future<void> mailContact(BuildContext context, String to) async {
  var opened = false;
  try {
    opened = await launchUrl(Uri(scheme: 'mailto', path: to));
  } catch (e) {
    debugPrint('contact_list: the mail program could not be opened: $e');
  }
  if (!opened && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nenhum programa de e-mail configurado neste computador')));
}

/// Round avatar with the initials; the colour comes from the name, so a person always has the same one.
class ContactAvatar extends StatelessWidget {
  const ContactAvatar({super.key, required this.name, this.initials, this.radius = 20});

  final String name;

  /// Text inside; the initials of [name] when null.
  final String? initials;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final hue = (name.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xFFFFFF) % 360).toDouble();
    return CircleAvatar(
      radius: radius,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.32 : 0.84).toColor(),
      child: Text(initials ?? contactInitials(name), style: theme.textTheme.titleSmall?.copyWith(color: HSLColor.fromAHSL(1, hue, 0.55, dark ? 0.85 : 0.25).toColor(), fontWeight: FontWeight.w700)),
    );
  }
}

class ContactCell {
  const ContactCell(this.text, {this.second});

  final String text;

  /// Smaller line under the text (who to ask for, "+1 número").
  final String? second;
}

class ContactAction {
  const ContactAction(this.icon, this.tooltip, this.onPressed);

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

/// Room of one hover button.
const contactActionWidth = 48.0;

/// Column titles above a wide contact list; [flex] is the one the rows use (first entry: the name column), [actions] the number of hover buttons the rows reserve room for.
class ContactsHeader extends StatelessWidget {
  const ContactsHeader({super.key, required this.titles, required this.flex, this.actions = 0});

  final List<String> titles;
  final List<int> flex;
  final int actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600, letterSpacing: 0.4);
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 8, 16, 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Row(
        children: [
          const SizedBox(width: 56),
          for (final (i, t) in titles.indexed)
            Expanded(flex: flex[i], child: Padding(padding: const EdgeInsets.only(right: 12), child: Text(t, style: style, maxLines: 1, overflow: TextOverflow.ellipsis))),
          SizedBox(width: actions * contactActionWidth),
        ],
      ),
    );
  }
}

/// One person or company in a contact list. Wide: avatar, name with [subtitle], one column per [cells] entry (widths from [flex], name first) and the [actions] on hover.
/// Narrow: avatar, name and one line with the filled [cells] joined.
class ContactRow extends StatefulWidget {
  const ContactRow({super.key, required this.name, this.subtitle = '', this.active = true, required this.cells, required this.flex, this.actions = const [], this.badge, required this.wide, this.maxActions});

  final String name;
  final String subtitle;
  final bool active;
  final List<ContactCell> cells;
  final List<int> flex;
  final List<ContactAction> actions;

  /// A small widget next to the name (an alert badge).
  final Widget? badge;
  final bool wide;

  /// Number of action slots reserved at the end of every row (so the columns line up even when a row has fewer buttons); defaults to [actions].length.
  final int? maxActions;

  @override
  State<ContactRow> createState() => _ContactRowState();
}

class _ContactRowState extends State<ContactRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.name;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final avatar = ContactAvatar(name: name);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: widget.active ? null : theme.colorScheme.onSurfaceVariant))),
            if (widget.badge != null) ...[const SizedBox(width: 6), widget.badge!],
            if (!widget.active) ...[const SizedBox(width: 8), const StatusBadge('Inativo', tone: Tone.neutral)],
          ],
        ),
        if (widget.subtitle.isNotEmpty) Text(widget.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
    if (!widget.wide) {
      final line = widget.cells.map((c) => c.text).where((t) => t.isNotEmpty).join(' · ');
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, if (line.isNotEmpty) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted)],
                ),
              ),
            ],
          ),
        ),
      );
    }
    Widget cell(int i) {
      final c = widget.cells[i];
      return Expanded(
        flex: widget.flex[i + 1],
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: c.text.isEmpty
              ? Text('—', style: muted)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(c.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                    if (c.second != null && c.second!.isNotEmpty) Text(c.second!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
        ),
      );
    }

    final slots = widget.maxActions ?? widget.actions.length;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 68),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 16, 8),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 16),
              Expanded(flex: widget.flex[0], child: Padding(padding: const EdgeInsets.only(right: 12), child: title)),
              for (var i = 0; i < widget.cells.length; i++) cell(i),
              SizedBox(
                width: slots * contactActionWidth,
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _hover ? 1 : 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [for (final a in widget.actions) IconButton(tooltip: a.tooltip, visualDensity: VisualDensity.compact, icon: Icon(a.icon, size: 20), onPressed: a.onPressed)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The actions every contact list shares: send an e-mail (when there is one) and copy the phone.
List<ContactAction> contactActions(BuildContext context, {String email = '', String phone = ''}) => [
  if (email.isNotEmpty) ContactAction(Icons.mail_outline, 'Enviar e-mail', () => unawaited(mailContact(context, email))),
  if (phone.isNotEmpty) ContactAction(Icons.phone_outlined, 'Copiar telefone', () => unawaited(copyContact(context, phone, 'Telefone'))),
];
