import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../entities.dart' show fmtNum;
import '../session.dart';
import '../widgets/responsive.dart';

/// How the screen asks for the JSON of the old fiscal data; tests replace it (the system file dialog does not run there).
Future<({String name, Uint8List bytes})?> Function() fiscalDataFilePicker = pickFiscalDataFile;

Future<({String name, Uint8List bytes})?> pickFiscalDataFile() async {
  final files = await FilePicker.pickFiles(dialogTitle: 'Dados fiscais do sistema antigo', type: FileType.custom, allowedExtensions: const ['json']);
  if (files.isEmpty) return null;
  final f = files.first;
  return (name: f.name, bytes: await f.readAsBytes());
}

/// Admin tool: brings the fiscal data of the old billing system (issuer, CFOPs, carriers, tax rules, monthly prices) into MetaGest, always after a preview.
Future<void> showFiscalImportDialog(BuildContext context, Session session) => showDialog<void>(context: context, builder: (_) => _FiscalImport(session: session));

class _FiscalImport extends StatefulWidget {
  const _FiscalImport({required this.session});

  final Session session;

  @override
  State<_FiscalImport> createState() => _FiscalImportState();
}

class _FiscalImportState extends State<_FiscalImport> {
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _result;
  ({String name, Uint8List bytes})? _file;
  String? _message;
  String? _error;
  bool _busy = false;

  ApiClient get api => widget.session.api;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    try {
      final s = await api.get('/api/fiscal/legacy-import/summary');
      if (mounted) setState(() => _summary = s is Map<String, dynamic> ? s : null);
    } catch (_) {
      if (mounted) setState(() => _summary = null);
    }
  }

  Future<void> _choose() async {
    if (_busy) return;
    final file = await fiscalDataFilePicker();
    if (file == null || !mounted) return;
    setState(() {
      _file = file;
      _result = null;
      _message = null;
    });
    await _run(apply: false);
  }

  Future<void> _run({required bool apply}) async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.upload('/api/fiscal/legacy-import?apply=$apply', 'file', file.name, file.bytes);
      if (!mounted) return;
      setState(() {
        _result = r is Map<String, dynamic> ? r : null;
        if (apply) {
          _message = 'Dados importados.';
          _file = null;
          _result = null;
        }
      });
      if (apply) await _loadSummary();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _summaryText() {
    final s = _summary;
    if (s == null) return '';
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    return 'Agora no sistema: emitente ${s['issuerFilled'] == true ? 'preenchido' : 'vazio'} · ${n('cfops')} CFOPs · ${n('carriers')} transportadoras · ${n('taxRules')} regras de imposto · ${n('monthlyPrices')} preços mensais · próximo nº da NF ${n('nextNumber')}';
  }

  int _changes(Map<String, dynamic> r) => [for (final x in (r['sections'] as List).cast<Map<String, dynamic>>()) ((x['added'] as num?) ?? 0) + ((x['updated'] as num?) ?? 0)].fold<num>(0, (a, b) => a + b).toInt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return AlertDialog(
      title: const Text('Dados fiscais do sistema antigo'),
      content: SizedBox(
        width: dialogWidth(context, 640),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
              const Text(
                'Traz para o MetaGest o que a emissão da NF precisa e não veio com os cadastros: dados do emitente (CNPJ, IE, endereço), CFOPs que faltam, transportadoras, '
                'impostos por produto e cliente (ICMS da UF, IPI, PIS e COFINS) e os preços mensais da NF. Nada é apagado: o que já está preenchido fica como está e a emissão continua desligada.',
              ),
              const SizedBox(height: 8),
              Text(
                '1. No computador do servidor rode  powershell -File scripts\\export-fiscal-data.ps1  (gera fiscal-data.json a partir dos arquivos do sistema antigo).\n2. Escolha o arquivo abaixo: o sistema mostra o que mudaria.\n3. Confira e confirme.',
                style: theme.textTheme.bodySmall,
              ),
              if (_summary != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_summaryText(), key: const ValueKey('fiscal-import-summary'), style: theme.textTheme.bodySmall)),
              const SizedBox(height: 12),
              OutlinedButton.icon(key: const ValueKey('fiscal-import-choose'), onPressed: _busy ? null : _choose, icon: const Icon(Icons.upload_file), label: Text(_file == null ? 'Escolher fiscal-data.json' : 'Escolher outro arquivo')),
              if (_file != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_file!.name, style: theme.textTheme.bodySmall)),
              if (r != null) ...[
                const SizedBox(height: 14),
                Text('Prévia: nada foi salvo ainda', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                for (final x in (r['sections'] as List).cast<Map<String, dynamic>>()) _SectionResult(x),
                const SizedBox(height: 10),
                if (_changes(r) == 0)
                  const Text('Nada a importar: tudo já está no sistema.', key: ValueKey('fiscal-import-nothing'))
                else
                  FilledButton.icon(key: const ValueKey('fiscal-import-apply'), onPressed: _busy ? null : () => _run(apply: true), icon: const Icon(Icons.download_done), label: Text('Importar ${fmtNum(_changes(r), 0)} registros')),
              ],
              if (_message != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_message!, key: const ValueKey('fiscal-import-message'), style: TextStyle(color: theme.colorScheme.primary))),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(_error!, key: const ValueKey('fiscal-import-error'), style: TextStyle(color: theme.colorScheme.error))),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
    );
  }
}

class _SectionResult extends StatelessWidget {
  const _SectionResult(this.x);

  final Map<String, dynamic> x;

  @override
  Widget build(BuildContext context) {
    int n(String k) => (x[k] as num?)?.toInt() ?? 0;
    final notes = (x['notes'] as List? ?? const []).cast<String>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${x['title']}: ${fmtNum(n('read'), 0)} lidos · ${fmtNum(n('added'), 0)} novos · ${fmtNum(n('updated'), 0)} atualizados · ${fmtNum(n('unchanged'), 0)} iguais${n('skipped') > 0 ? ' · ${fmtNum(n('skipped'), 0)} ignorados' : ''}'),
          for (final note in notes.take(6)) Padding(padding: const EdgeInsets.only(left: 12), child: Text('• $note', style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
