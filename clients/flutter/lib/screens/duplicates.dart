import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../session.dart';
import '../widgets/actions.dart';
import '../widgets/duplicates.dart';
import '../widgets/load_error.dart';
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
                'Abra os cadastros para corrigir ou excluir. Se dois cadastros estão certos como estão (por exemplo, filiais), use "Não é duplicado".',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final (i, g) in groups.indexed)
            _GroupCard(key: ValueKey('duplicate-group-$i'), session: widget.session, kind: widget.kind, group: g, onDismiss: _dismiss),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({super.key, required this.session, required this.kind, required this.group, required this.onDismiss});

  final Session session;
  final String kind;
  final Map<String, dynamic> group;
  final Future<void> Function(Map<String, dynamic> pair) onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairs = (group['pairs'] as List).cast<Map<String, dynamic>>();
    final canReview = session.canReviewDuplicates;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final m in (group['members'] as List).cast<Map<String, dynamic>>())
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
                    ],
                  ),
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
