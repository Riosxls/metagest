import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/actions.dart';
import '../widgets/duplicate_compare.dart';
import '../widgets/duplicates.dart';
import '../widgets/load_error.dart';
import '../widgets/pipeline.dart' show Tone, toneColors;
import 'customers.dart' show openCustomer;
import 'product_detail.dart' show openProduct;
import 'suppliers.dart' show openSupplier;

/// Every suspected group of duplicate customers, products and suppliers, with why they look alike. Detection only: records are opened to fix or
/// delete them, and a pair that is fine as it is gets "Não é duplicado" so it stops being flagged.
class DuplicatesScreen extends StatelessWidget {
  const DuplicatesScreen({super.key, required this.session, this.initialKind});

  final Session session;

  /// 'customers', 'products' or 'suppliers'.
  final String? initialKind;

  @override
  Widget build(BuildContext context) {
    final kinds = duplicateKindLabels.keys.toList();
    return DefaultTabController(
      length: kinds.length,
      initialIndex: initialKind == null ? 0 : kinds.indexOf(initialKind!).clamp(0, kinds.length - 1),
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final k in kinds) Tab(text: duplicateKindLabels[k])],
          ),
          Expanded(
            child: TabBarView(
              children: [for (final k in kinds) DuplicateGroupsView(session: session, kind: k)],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a record of [kind] ('customers', 'products' or 'suppliers') with the screen's own helper.
void openDuplicateRecord(BuildContext context, Session session, String kind, int id) => switch (kind) {
  'customers' => unawaited(openCustomer(context, session, id)),
  'products' => unawaited(openProduct(context, session, id)),
  _ => unawaited(openSupplier(context, session, id)),
};

class DuplicateGroupsView extends StatefulWidget {
  const DuplicateGroupsView({super.key, required this.session, required this.kind});

  final Session session;
  final String kind;

  @override
  State<DuplicateGroupsView> createState() => _DuplicateGroupsViewState();
}

class _DuplicateGroupsViewState extends State<DuplicateGroupsView> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? _groups;
  int _pairs = 0;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.session.api.get('/api/duplicates/${widget.kind}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _groups = (r['groups'] as List).cast<Map<String, dynamic>>();
        _pairs = r['pairs'] as int;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _dismiss(Map<String, dynamic> pair) async {
    if (await dismissDuplicate(context, widget.session, widget.kind, (pair['a'] as Map)['id'] as int, (pair['b'] as Map)['id'] as int)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final groups = _groups;
    if (_error != null) return LoadError(message: _error!, onRetry: _load);
    if (groups == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  groups.isEmpty
                      ? 'Nenhum duplicado suspeito'
                      : '${groups.length} ${groups.length == 1 ? 'grupo' : 'grupos'} com $_pairs ${_pairs == 1 ? 'par suspeito' : 'pares suspeitos'}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(tooltip: 'Atualizar', onPressed: _load, icon: const Icon(Icons.refresh)),
            ],
          ),
          if (groups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Marque "É o atual" no cadastro que fica ou use "Comparar informações" para escolher o valor certo de cada campo; os outros ficam inativos. Se dois cadastros estão certos como estão (por exemplo, filiais), use "Não é duplicado".',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final (i, g) in groups.indexed)
            _GroupCard(key: ValueKey('duplicate-group-$i'), session: widget.session, kind: widget.kind, group: g, onDismiss: _dismiss, onChanged: _load),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({super.key, required this.session, required this.kind, required this.group, required this.onDismiss, required this.onChanged});

  final Session session;
  final String kind;
  final Map<String, dynamic> group;
  final Future<void> Function(Map<String, dynamic> pair) onDismiss;
  final Future<void> Function() onChanged;

  Future<void> _compare(BuildContext context, List<int> ids, {int? keepId}) async {
    if (await showDuplicateCompare(context, session, kind, ids, keepId: keepId)) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairs = (group['pairs'] as List).cast<Map<String, dynamic>>();
    final canReview = session.canReviewDuplicates;
    final members = (group['members'] as List).cast<Map<String, dynamic>>();
    final ids = [for (final m in members) m['id'] as int];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in members)
              InkWell(
                key: ValueKey('duplicate-member-${m['id']}'),
                onTap: () => openDuplicateRecord(context, session, kind, m['id'] as int),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.open_in_new, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${m['label']}${m['active'] == false ? ' (inativo)' : ''}',
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (m['detail'] != null) Text('${m['detail']}', style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      if (canReview)
                        TextButton(key: ValueKey('current-${m['id']}'), onPressed: () => _compare(context, ids, keepId: m['id'] as int), child: const Text('É o atual')),
                    ],
                  ),
                ),
              ),
            if (canReview)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: ValueKey('compare-${ids.join('-')}'),
                  onPressed: () => _compare(context, ids),
                  icon: const Icon(Icons.compare_arrows, size: 18),
                  label: const Text('Comparar informações'),
                ),
              ),
            const Divider(),
            for (final p in pairs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${(p['a'] as Map)['label']}  ↔  ${(p['b'] as Map)['label']}\n${duplicateReasons(p)} · ${duplicateScore(p)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (canReview)
                      TextButton(
                        key: ValueKey('dismiss-${(p['a'] as Map)['id']}-${(p['b'] as Map)['id']}'),
                        onPressed: () => onDismiss(p),
                        child: const Text('Não é duplicado'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the duplicates screen on the tab of [kind] ('customers', 'products' or 'suppliers') as a page of its own, with Back to the list.
void openDuplicates(BuildContext context, Session session, String kind) => unawaited(
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Cadastros duplicados')),
        body: DuplicatesScreen(session: session, initialKind: kind),
      ),
    ),
  ),
);

/// "Atenção" strip above the list of customers, products or suppliers: shown only when the server finds suspected duplicates of that kind, and a tap
/// opens the duplicates screen on that kind. It is a hint, never a blocker: while loading or when the check fails, nothing shows.
class DuplicatesAlert extends StatefulWidget {
  const DuplicatesAlert({super.key, required this.session, required this.kind});

  final Session session;

  /// 'customers', 'products' or 'suppliers'.
  final String kind;

  @override
  State<DuplicatesAlert> createState() => _DuplicatesAlertState();
}

class _DuplicatesAlertState extends State<DuplicatesAlert> {
  int _groups = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.session.api.get('/api/duplicates/${widget.kind}');
      final groups = r is Map ? (r['groups'] as List?)?.length ?? 0 : 0;
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      debugPrint('duplicates: alert not loaded: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_groups == 0) return const SizedBox.shrink();
    final (bg, fg) = toneColors(context, Tone.warning);
    final what = duplicateKindLabels[widget.kind]!.toLowerCase();
    return Padding(
      key: const ValueKey('duplicates-alert'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openDuplicates(context, widget.session, widget.kind),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.content_copy_outlined, color: fg, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _groups == 1 ? 'Atenção: 1 grupo de $what parece duplicado' : 'Atenção: $_groups grupos de $what parecem duplicados',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: fg),
                  ),
                ),
                Text('Ver', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right, color: fg, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
