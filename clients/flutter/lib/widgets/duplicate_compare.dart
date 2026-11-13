import 'dart:async';

import 'package:flutter/material.dart';

import '../session.dart';
import 'actions.dart';

/// Compares the records of one duplicate group field by field. The user picks the record that stays ("É o atual") and, for each field that differs,
/// which record holds the correct value; confirming copies those values into the kept record and deactivates the others (nothing is deleted).
/// True when the server settled the group.
Future<bool> showDuplicateCompare(BuildContext context, Session session, String kind, List<int> ids, {int? keepId}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => _CompareDialog(session: session, kind: kind, ids: ids, initialKeep: keepId),
  );
  return r == true;
}

class _CompareDialog extends StatefulWidget {
  const _CompareDialog({required this.session, required this.kind, required this.ids, this.initialKeep});

  final Session session;
  final String kind;
  final List<int> ids;
  final int? initialKeep;

  @override
  State<_CompareDialog> createState() => _CompareDialogState();
}

class _CompareDialogState extends State<_CompareDialog> {
  List<Map<String, dynamic>> _records = const [];
  List<Map<String, dynamic>> _fields = const [];
  final _chosen = <String, int>{};
  int? _keep;
  bool _moveAddresses = true;
  bool _showEqual = false;
  bool _saving = false;
  String? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.session.api.get('/api/duplicates/${widget.kind}/compare?ids=${widget.ids.join(',')}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _records = (r['records'] as List).cast<Map<String, dynamic>>();
        _fields = (r['fields'] as List).cast<Map<String, dynamic>>();
        _keep = widget.initialKeep ?? _suggestKeep();
        _loaded = true;
        _applyDefaults();
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  /// The record most in use (orders, quotes...) is the best guess for the one that stays.
  int _suggestKeep() {
    int use(Map<String, dynamic> r) => [for (final u in (r['usage'] as List)) (u as Map)['count'] as int].fold(0, (a, b) => a + b);
    final sorted = [..._records]..sort((a, b) => use(b).compareTo(use(a)));
    return sorted.first['id'] as int;
  }

  String? _value(Map<String, dynamic> f, int id) => ((f['values'] as Map)['$id'] as String?);

  /// Each field starts with the kept record's value, or the first filled one when the kept record has none.
  void _applyDefaults() {
    _chosen.clear();
    for (final f in _fields) {
      if (f['differs'] != true) continue;
      final keep = _keep!;
      if ((_value(f, keep) ?? '').isNotEmpty) {
        _chosen[f['key'] as String] = keep;
      } else {
        final src = widget.ids.firstWhere((i) => (_value(f, i) ?? '').isNotEmpty, orElse: () => keep);
        _chosen[f['key'] as String] = src;
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.api.post('/api/duplicates/${widget.kind}/resolve', {
        'keepId': _keep,
        'otherIds': [
          for (final i in widget.ids)
            if (i != _keep) i,
        ],
        'fields': _chosen,
        'moveAddresses': _moveAddresses,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAddresses = widget.kind != 'products';
    final differing = [
      for (final f in _fields)
        if (f['differs'] == true) f,
    ];
    final shown = _showEqual ? _fields : differing;
    return AlertDialog(
      title: const Text('Comparar cadastros'),
      content: SizedBox(
        width: 980,
        child: !_loaded
            ? SizedBox(height: 120, child: Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Marque "É o atual" no cadastro que fica. Em cada linha, escolha o valor correto: ele é copiado para o cadastro atual. Os outros ficam inativos (nada é apagado; pedidos e histórico continuam onde estão).',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Table(
                      columnWidths: {0: const FixedColumnWidth(170), for (var i = 1; i <= _records.length; i++) i: const FlexColumnWidth()},
                      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                      children: [
                        TableRow(children: [const SizedBox.shrink(), for (final r in _records) _header(theme, r)]),
                        for (final f in shown)
                          TableRow(
                            decoration: BoxDecoration(
                              border: Border(top: BorderSide(color: theme.dividerColor)),
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Text('${f['label']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                              ),
                              for (final r in _records) _cell(theme, f, r['id'] as int),
                            ],
                          ),
                      ],
                    ),
                    if (shown.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Os cadastros têm as mesmas informações.')),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 16,
                      children: [
                        FilterChip(
                          key: const ValueKey('compare-show-equal'),
                          label: Text(_showEqual ? 'Mostrando todos os campos' : 'Mostrar campos iguais (${_fields.length - differing.length})'),
                          selected: _showEqual,
                          onSelected: (v) => setState(() => _showEqual = v),
                        ),
                        if (hasAddresses)
                          FilterChip(
                            key: const ValueKey('compare-move-addresses'),
                            label: const Text('Passar os endereços dos outros para o atual'),
                            selected: _moveAddresses,
                            onSelected: (v) => setState(() => _moveAddresses = v),
                          ),
                      ],
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(
          key: const ValueKey('compare-confirm'),
          onPressed: _saving || !_loaded ? null : _save,
          child: const Text('Unificar e desativar os outros'),
        ),
      ],
    );
  }

  Widget _header(ThemeData theme, Map<String, dynamic> r) {
    final id = r['id'] as int;
    final keep = _keep == id;
    final usage = [
      for (final u in (r['usage'] as List))
        if ((u as Map)['count'] as int > 0) '${u['count']} ${u['label'].toString().toLowerCase()}',
    ];
    if (r['addresses'] is int && (r['addresses'] as int) > 0) usage.add('${r['addresses']} endereço(s)');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${r['label']}${r['active'] == false ? ' (inativo)' : ''}', style: theme.textTheme.titleSmall),
          Text(usage.isEmpty ? 'sem uso' : usage.join(' · '), style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          keep
              ? FilledButton.tonalIcon(key: ValueKey('keep-$id'), onPressed: null, icon: const Icon(Icons.check, size: 16), label: const Text('É o atual'))
              : OutlinedButton(
                  key: ValueKey('keep-$id'),
                  onPressed: () => setState(() {
                    _keep = id;
                    _applyDefaults();
                  }),
                  child: const Text('É o atual'),
                ),
        ],
      ),
    );
  }

  Widget _cell(ThemeData theme, Map<String, dynamic> f, int id) {
    final v = _value(f, id);
    final differs = f['differs'] == true;
    final text = Text(
      v == null || v.isEmpty ? '—' : v,
      style: theme.textTheme.bodyMedium?.copyWith(color: v == null || v.isEmpty ? theme.colorScheme.onSurfaceVariant : null),
    );
    if (!differs) return Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: text);
    final key = f['key'] as String;
    final empty = v == null || v.isEmpty;
    return InkWell(
      key: ValueKey('pick-$key-$id'),
      onTap: empty && _keep != id ? null : () => setState(() => _chosen[key] = id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            Icon(
              _chosen[key] == id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: empty && _keep != id ? theme.disabledColor : theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(child: text),
          ],
        ),
      ),
    );
  }
}
