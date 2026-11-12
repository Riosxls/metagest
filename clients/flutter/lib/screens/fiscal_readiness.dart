import 'package:flutter/material.dart';

import '../api.dart';
import '../entities.dart' show carriers, taxRules;
import 'dashboard.dart' show Navigate;

/// How one line of the Fiscal checklist stands.
enum CheckState { ok, warn, info }

/// One line of the "Pronto para emitir?" checklist: what is checked, what was found and the screen that fixes it.
class FiscalCheck {
  const FiscalCheck(this.id, this.title, this.detail, this.state, {this.goTo, this.filter});

  final String id;
  final String title;
  final String detail;
  final CheckState state;

  /// Screen id that fixes it (null when nothing to do).
  final String? goTo;

  /// Filter passed to that screen (the company, for the issuer screen).
  final String? filter;
}

/// The CFOPs the sale needs: 5101 inside the state, 6101 to another state.
const requiredSaleCfops = ['5101', '6101'];

/// Readiness of the NF-e emission, built from existing endpoints (`/api/fiscal/settings`, `/cfops`, `/legacy-import/summary`).
class FiscalReadiness {
  const FiscalReadiness(this.checks);

  final List<FiscalCheck> checks;

  /// Lines that block or threaten the emission.
  int get pending => checks.where((c) => c.state == CheckState.warn).length;

  bool get ready => pending == 0;

  static Future<FiscalReadiness> fetch(ApiClient api) async {
    final r = await Future.wait([api.get('/api/fiscal/settings/all'), api.get('/api/fiscal/cfops'), api.get('/api/fiscal/legacy-import/summary')]);
    final raw = r[0];
    return FiscalReadiness.from(
      issuers: raw is List ? [for (final x in raw) x as Map<String, dynamic>] : [raw as Map<String, dynamic>],
      cfops: [for (final c in (r[1] as List)) (c as Map)['code'] as String],
      summary: r[2] as Map<String, dynamic>,
    );
  }

  /// Pure: the same answers always give the same checklist (tests build it from maps). [issuers] has one row per issuing company (EBT, BST).
  static FiscalReadiness from({required List<Map<String, dynamic>> issuers, required List<String> cfops, required Map<String, dynamic> summary}) {
    int n(String k) => (summary[k] as num?)?.toInt() ?? 0;
    final missingCfops = [
      for (final c in requiredSaleCfops)
        if (!cfops.contains(c)) c,
    ];
    // The certificate is one per server, not per company: every issuer row says the same.
    final simulated = issuers.every((s) => s['sefazSimulated'] != false);
    final rules = n('taxRules');
    final carrierCount = n('carriers');
    String environmentOf(Map<String, dynamic> s) => s['environment'] == 'Production' ? 'Produção' : 'Homologação';
    return FiscalReadiness([
      for (final s in issuers) ..._issuerChecks(s),
      FiscalCheck(
        'cfops',
        'CFOPs de venda (${requiredSaleCfops.join(' e ')})',
        missingCfops.isEmpty ? 'Cadastrados' : 'Faltam: ${missingCfops.join(', ')}. Importe os dados do sistema antigo.',
        missingCfops.isEmpty ? CheckState.ok : CheckState.warn,
        goTo: missingCfops.isEmpty ? null : 'fiscal-import',
      ),
      FiscalCheck(
        'tax-rules',
        'Regras de imposto',
        rules == 0 ? 'Nenhuma regra. Sem elas o ICMS e o IPI saem do pedido ou do padrão do estado.' : '$rules cadastradas',
        rules == 0 ? CheckState.warn : CheckState.ok,
        goTo: rules == 0 ? taxRules.path : null,
      ),
      FiscalCheck(
        'carriers',
        'Transportadoras',
        carrierCount == 0 ? 'Nenhuma cadastrada (só é preciso quando a nota leva transporte por terceiros)' : '$carrierCount cadastradas',
        carrierCount == 0 ? CheckState.info : CheckState.ok,
        goTo: carrierCount == 0 ? carriers.path : null,
      ),
      FiscalCheck(
        'certificate',
        'Certificado digital A1',
        simulated ? 'Ainda sem certificado: a SEFAZ é simulada e nenhuma nota vale de verdade.' : 'Conectado à SEFAZ (${environmentOf(issuers.first)})',
        simulated ? CheckState.warn : CheckState.ok,
      ),
    ]);
  }

  /// The two lines of one issuing company: its data, and whether it emits (with its series and next number).
  static List<FiscalCheck> _issuerChecks(Map<String, dynamic> s) {
    String has(String k) => '${s[k] ?? ''}'.trim();
    final company = has('company').isEmpty ? 'EBT' : has('company');
    final missing = [
      if (has('companyName').isEmpty) 'razão social',
      if (has('cnpj').isEmpty) 'CNPJ',
      if (has('stateRegistration').isEmpty) 'inscrição estadual',
      if (has('street').isEmpty || has('city').isEmpty || has('cityIbgeCode').isEmpty) 'endereço completo',
    ];
    final enabled = s['enabled'] == true;
    final environment = s['environment'] == 'Production' ? 'Produção' : 'Homologação';
    return [
      FiscalCheck(
        'issuer-$company',
        'Dados do emitente ($company)',
        missing.isEmpty ? '${has('companyName')} · CNPJ ${has('cnpj')}' : 'Falta preencher: ${missing.join(', ')}',
        missing.isEmpty ? CheckState.ok : CheckState.warn,
        goTo: missing.isEmpty ? null : 'fiscal-settings',
        filter: company,
      ),
      FiscalCheck(
        'emission-$company',
        'Emissão de NF-e ($company)',
        '${enabled ? 'Ligada ($environment)' : 'Desligada: o número da NF continua sendo digitado à mão'} · série ${s['series'] ?? 1} · próximo número ${s['nextNumber'] ?? '—'}',
        enabled ? CheckState.ok : CheckState.info,
        goTo: 'fiscal-settings',
        filter: company,
      ),
    ];
  }
}

/// The checklist card of the Fiscal overview.
class FiscalChecklist extends StatelessWidget {
  const FiscalChecklist({super.key, required this.readiness, this.onNavigate});

  final FiscalReadiness readiness;
  final Navigate? onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              readiness.ready ? 'Tudo certo para emitir.' : '${readiness.pending} ${readiness.pending == 1 ? 'item precisa' : 'itens precisam'} de atenção antes de emitir.',
              key: const ValueKey('fiscal-readiness-headline'),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final c in readiness.checks)
            ListTile(
              key: ValueKey('fiscal-check-${c.id}'),
              leading: Icon(switch (c.state) {
                CheckState.ok => Icons.check_circle_outline,
                CheckState.warn => Icons.warning_amber_rounded,
                CheckState.info => Icons.info_outline,
              }, color: switch (c.state) {
                CheckState.ok => cs.primary,
                CheckState.warn => cs.error,
                CheckState.info => cs.onSurfaceVariant,
              }),
              title: Text(c.title),
              subtitle: Text(c.detail),
              trailing: c.goTo != null && onNavigate != null ? const Icon(Icons.chevron_right) : null,
              onTap: c.goTo != null && onNavigate != null ? () => onNavigate!(c.goTo!, c.filter) : null,
            ),
        ],
      ),
    );
  }
}
