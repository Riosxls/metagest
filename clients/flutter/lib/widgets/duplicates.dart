import 'dart:async';

import 'package:flutter/material.dart';

import '../session.dart';
import 'actions.dart';
import 'pipeline.dart' show Tone, toneColors;

/// What the API calls each kind in `/api/<plural>/{id}/duplicates` and `/api/duplicates/<plural>`.
const duplicateKindLabels = {'customers': 'Clientes', 'products': 'Produtos', 'suppliers': 'Fornecedores'};

String duplicateScore(Map<String, dynamic> pair) => '${pair['score']}%';

/// "Mesmo CNPJ/CPF · Mesmo nome": why two records look alike, as the server worded it.
String duplicateReasons(Map<String, dynamic> pair) => [for (final r in (pair['reasons'] as List? ?? const [])) '${(r as Map)['text']}'].join(' · ');

/// Marks a pair as "não é duplicado" after asking for an optional reason. True when the server saved it.
Future<bool> dismissDuplicate(BuildContext context, Session session, String kind, int a, int b) async {
  final reason = await promptText(context, title: 'Não é duplicado', label: 'Por quê? (opcional, ex.: filiais separadas)', confirmLabel: 'Marcar');
  if (reason == null || !context.mounted) return false;
  final r = await runAction(context, () async {
    await session.api.post('/api/duplicates/$kind/$a/$b/dismiss', {'reason': reason});
    return true;
  }, success: 'Marcado como não duplicado');
  return r == true;
}

/// Takes the "não é duplicado" mark back: the pair is flagged again.
Future<bool> restoreDuplicate(BuildContext context, Session session, String kind, int a, int b) async {
  final r = await runAction(context, () async {
    await session.api.delete('/api/duplicates/$kind/$a/$b/dismiss');
    return true;
  }, success: 'Voltou a ser sinalizado');
  return r == true;
}

/// "Possíveis duplicados" on a record's own page: the records that look like this one and why, a way to open each and to mark the pair as
/// "não é duplicado". Shows nothing while there is nothing to say (or when the list cannot be read: it is a hint, never a blocker).
class DuplicatesBanner extends StatefulWidget {
  const DuplicatesBanner({super.key, required this.session, required this.kind, required this.id, required this.onOpen});

  final Session session;

  /// 'customers', 'products' or 'suppliers'.
  final String kind;
  final int id;

  /// Opens the other record (the screen's own `open…` helper, so the page stacks like any other record).
  final void Function(int id) onOpen;

  @override
  State<DuplicatesBanner> createState() => _DuplicatesBannerState();
}

class _DuplicatesBannerState extends State<DuplicatesBanner> {
  List<Map<String, dynamic>> _matches = const [];
  List<Map<String, dynamic>> _dismissed = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(DuplicatesBanner old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.kind != widget.kind) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.session.api.get('/api/${widget.kind}/${widget.id}/duplicates') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _matches = (r['matches'] as List).cast<Map<String, dynamic>>();
        _dismissed = (r['dismissed'] as List).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // A hint only: the page works without it.
    }
  }

  Future<void> _dismiss(Map<String, dynamic> pair) async {
    final other = (pair['b'] as Map)['id'] as int;
    if (await dismissDuplicate(context, widget.session, widget.kind, widget.id, other)) await _load();
  }

  Future<void> _restore(Map<String, dynamic> d) async {
    final other = (d['other'] as Map)['id'] as int;
    if (await restoreDuplicate(context, widget.session, widget.kind, widget.id, other)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_matches.isEmpty && _dismissed.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final (bg, fg) = toneColors(context, _matches.isEmpty ? Tone.neutral : Tone.warning);
    final canReview = widget.session.canReviewDuplicates;
    final first = _matches.isEmpty ? null : _matches.first;
    return Padding(
      key: const ValueKey('duplicates-banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: ValueKey('duplicates-tile-${_matches.length}-${_dismissed.length}'),
            initiallyExpanded: _matches.isNotEmpty && _matches.length <= 3,
            leading: Icon(_matches.isEmpty ? Icons.fact_check_outlined : Icons.content_copy_outlined, color: fg),
            iconColor: fg,
            collapsedIconColor: fg,
            title: Text(
              _matches.isEmpty ? 'Marcados como não duplicados (${_dismissed.length})' : 'Possíveis duplicados (${_matches.length})',
              style: theme.textTheme.titleSmall?.copyWith(color: fg),
            ),
            subtitle: first == null
                ? null
                : Text(
                    '${(first['b'] as Map)['label']} — ${duplicateReasons(first)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg),
                  ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final m in _matches)
                _Row(
                  key: ValueKey('duplicate-${(m['b'] as Map)['id']}'),
                  record: m['b'] as Map<String, dynamic>,
                  note: '${duplicateReasons(m)} · ${duplicateScore(m)}',
                  onOpen: () => widget.onOpen((m['b'] as Map)['id'] as int),
                  actionLabel: canReview ? 'Não é duplicado' : null,
                  onAction: () => _dismiss(m),
                ),
              if (_dismissed.isNotEmpty && _matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Marcados como não duplicados', style: theme.textTheme.labelLarge),
              ],
              for (final d in _dismissed)
                _Row(
                  key: ValueKey('dismissed-${(d['other'] as Map)['id']}'),
                  record: d['other'] as Map<String, dynamic>,
                  note: [if (d['reason'] != null) '${d['reason']}', if (d['createdBy'] != null) 'por ${d['createdBy']}'].join(' · '),
                  onOpen: () => widget.onOpen((d['other'] as Map)['id'] as int),
                  actionLabel: canReview ? 'Voltar a sinalizar' : null,
                  onAction: () => _restore(d),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.record, required this.note, required this.onOpen, required this.actionLabel, required this.onAction});

  final Map<String, dynamic> record;
  final String note;
  final VoidCallback onOpen;
  final String? actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onOpen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${record['label']}${record['active'] == false ? ' (inativo)' : ''}',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (record['detail'] != null) Text('${record['detail']}', style: theme.textTheme.bodySmall),
                  if (note.isNotEmpty) Text(note, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          TextButton(onPressed: onOpen, child: const Text('Abrir')),
          if (actionLabel != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
