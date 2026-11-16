/// Texto do cadastro (herdado do sistema antigo: tudo em maiúsculas e sem acento) em português correto para as folhas impressas:
/// "METALURGICA FORMIGARI LTDA." vira "Metalúrgica Formigari Ltda.". Só para exibir e imprimir: o cadastro não muda.
library;

/// Palavras que o sistema antigo gravava sem acento. Chave em minúsculas e sem acento; o valor já vem com a grafia certa.
const _words = <String, String>{
  'metalurgica': 'metalúrgica',
  'metalurgicas': 'metalúrgicas',
  'metalurgico': 'metalúrgico',
  'metalurgicos': 'metalúrgicos',
  'metalica': 'metálica',
  'metalicas': 'metálicas',
  'metalico': 'metálico',
  'metalicos': 'metálicos',
  'metaltecnica': 'metaltécnica',
  'eletrotecnica': 'eletrotécnica',
  'tecnica': 'técnica',
  'tecnico': 'técnico',
  'industria': 'indústria',
  'industrias': 'indústrias',
  'comercio': 'comércio',
  'servico': 'serviço',
  'servicos': 'serviços',
  'solucoes': 'soluções',
  'conexoes': 'conexões',
  'importacao': 'importação',
  'exportacao': 'exportação',
  'manutencao': 'manutenção',
  'locacao': 'locação',
  'construcao': 'construção',
  'galvanizacao': 'galvanização',
  'galvonoplastia': 'galvanoplastia',
  'iluminacao': 'iluminação',
  'inspecao': 'inspeção',
  'automacao': 'automação',
  'medicao': 'medição',
  'precisao': 'precisão',
  'papelao': 'papelão',
  'quimica': 'química',
  'mecanica': 'mecânica',
  'eletrica': 'elétrica',
  'eletricas': 'elétricas',
  'eletrico': 'elétrico',
  'eletricos': 'elétricos',
  'termica': 'térmica',
  'termico': 'térmico',
  'termometros': 'termômetros',
  'pecas': 'peças',
  'peca': 'peça',
  'aco': 'aço',
  'acos': 'aços',
  'maquinas': 'máquinas',
  'maquina': 'máquina',
  'siderurgicos': 'siderúrgicos',
  'siderurgica': 'siderúrgica',
  'siderurgicas': 'siderúrgicas',
  'especiasis': 'especiais',
  'feros': 'ferros',
  'eirelli': 'Eireli',
  'atica': 'Ática',
  'maua': 'Mauá',
  'sao': 'São',
  'joao': 'João',
  'jose': 'José',
  'antao': 'Antão',
  'falcao': 'Falcão',
  'ribeirao': 'Ribeirão',
  'taboao': 'Taboão',
  'sertaozinho': 'Sertãozinho',
  'jundiai': 'Jundiaí',
  'itajai': 'Itajaí',
  'indio': 'Índio',
  'tibirica': 'Tibiriçá',
  'jeronimo': 'Jerônimo',
  'eugenio': 'Eugênio',
  'cesario': 'Cesário',
  'claudio': 'Cláudio',
  'lucilio': 'Lucílio',
  'julio': 'Júlio',
  'andre': 'André',
  'nobrega': 'Nóbrega',
  'conceicao': 'Conceição',
  'gracas': 'Graças',
  'assuncao': 'Assunção',
  'esperanca': 'Esperança',
  'convencao': 'Convenção',
  'oratorio': 'Oratório',
  'satelite': 'Satélite',
  'solimoes': 'Solimões',
  'inacio': 'Inácio',
  'angelo': 'Ângelo',
  'agua': 'Água',
  'jaguare': 'Jaguaré',
  'cambara': 'Cambará',
  'maracana': 'Maracanã',
  'boqueirao': 'Boqueirão',
  'capao': 'Capão',
  'campanario': 'Campanário',
  'balneario': 'Balneário',
  'camboriu': 'Camboriú',
  'laroca': 'Laroça',
  'adlia': 'Adélia',
  'mrechal': 'Marechal',
  'iporangar': 'Iporanga',
  'alvaro': 'Álvaro',
  'fabricacao': 'fabricação',
  'diametro': 'diâmetro',
  'materia': 'matéria',
  'primario': 'primário',
  'responsavel': 'responsável',
  'especificacao': 'especificação',
  'observacao': 'observação',
  'observacoes': 'observações',
  'numero': 'número',
  'codigo': 'código',
  'sn': 's/n',
  'ltda': 'Ltda.',
  'ind': 'Ind.',
  'dist': 'Dist.',
  'rod': 'Rod.',
  'av': 'Av.',
  'est': 'Est.',
  'jd': 'Jd.',
  'vl': 'Vl.',
  'pq': 'Pq.',
  'sta': 'Sta.',
  'dr': 'Dr.',
  'dra': 'Dra.',
  'repr': 'Repr.',
  'tecnol': 'Tecnol.',
};

/// Ligações que ficam em minúsculas no meio do nome.
const _small = {'de', 'da', 'do', 'das', 'dos', 'e', 'em', 'para', 'com', 'por'};

/// Siglas que ficam em maiúsculas.
const _acronyms = {
  'SP',
  'RJ',
  'MG',
  'SC',
  'RS',
  'PR',
  'BA',
  'GO',
  'CE',
  'MT',
  'MS',
  'AM',
  'EBT',
  'BST',
  'CNPJ',
  'CPF',
  'IE',
  'NF',
  'NCM',
  'CFOP',
  'ME',
  'EPP',
  'MEI',
  'LBA',
  'HSA',
  'DOX',
  'RMI',
  'MPT',
  'CSC',
  'BWT',
  'DM5',
  'M2A',
  'JP',
  'JAF',
  'IKS',
  'PCAD',
  'MGXTEC',
  'ARJ',
  'MCM',
  'FA',
  'KEB',
  'ZAT',
  'STKM',
  'SAE',
  'AISI',
  'GBK',
  'NBK',
  'BK',
  'EN',
  'NBR',
  'ASTM',
  'DIN',
  'ISO',
  'RNC',
  'SA',
  'PV',
  'OF',
  'PO',
};

final _roman = RegExp(r'^(?=[IVXLCDM]+$)M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$');
final _notRoman = {'MIL', 'DI', 'MI', 'LI', 'CI', 'DC', 'MC', 'MD', 'CD', 'DIM', 'MIX', 'VI'};

String _fold(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[áàâãä]'), 'a')
    .replaceAll(RegExp('[éèêë]'), 'e')
    .replaceAll(RegExp('[íìîï]'), 'i')
    .replaceAll(RegExp('[óòôõö]'), 'o')
    .replaceAll(RegExp('[úùûü]'), 'u')
    .replaceAll('ç', 'c');

String _cap(String w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}';

/// True for a text typed entirely in capitals (the old system's way); mixed text was typed by hand and keeps its capitals.
bool _isShouting(String s) {
  final letters = s.replaceAll(RegExp('[^A-Za-zÀ-ÿ]'), '');
  return letters.isNotEmpty && letters == letters.toUpperCase();
}

String _word(String raw, int index, bool shouting, String prev) {
  final m = RegExp(r'^([^A-Za-zÀ-ÿ0-9]*)(.*?)([^A-Za-zÀ-ÿ0-9]*)$').firstMatch(raw)!;
  final lead = m.group(1)!, core = m.group(2)!, trail = m.group(3)!;
  if (core.isEmpty) return raw;
  final upper = core.toUpperCase();
  if (RegExp(r'\d').hasMatch(core) && !_roman.hasMatch(upper)) return raw;
  if (_acronyms.contains(upper) && (shouting || core == upper)) return '$lead$upper$trail';
  if (core.length > 1 && _roman.hasMatch(upper) && !_notRoman.contains(upper) && (shouting || core == upper)) return '$lead$upper$trail';
  final hit = _words[_fold(core)];
  if (hit != null) {
    // "LTDA." already carries its dot.
    var out = hit.endsWith('.') && trail.startsWith('.') ? hit.substring(0, hit.length - 1) : hit;
    final sentenceStart = index == 0 || shouting || core == upper;
    // A word with an accent restored keeps the capital the text had: "SAO" -> "São", "sao" -> "são".
    out = (core[0] == core[0].toUpperCase() && !RegExp(r'\d').hasMatch(core[0])) || (shouting && sentenceStart) ? _cap(out) : out;
    return '$lead$out$trail';
  }
  if (!shouting) return raw;
  final low = core.toLowerCase();
  // "IND E COM DE" abbreviates Comércio; "COM" after anything else is the preposition.
  if (low == 'com' && prev.toLowerCase() == 'e') return '${lead}Com.$trail';
  if (index > 0 && _small.contains(low)) return '$lead$low$trail';
  // Parts joined by dot, hyphen or slash each start with a capital ("J.C" -> "J.C", "INCO-MAR" -> "Inco-Mar").
  return '$lead${low.split(RegExp(r'(?<=[-./])')).map(_cap).join()}$trail';
}

/// "METALURGICA FORMIGARI LTDA." -> "Metalúrgica Formigari Ltda."; "AV PAPA JOAO XXIII" -> "Av. Papa João XXIII".
String ptText(Object? value) {
  final s = (value == null ? '' : '$value').trim().replaceAll(RegExp(r'\s+\.'), '.');
  if (s.isEmpty) return '';
  final shouting = _isShouting(s);
  final parts = s.split(RegExp(r'\s+'));
  return [for (var i = 0; i < parts.length; i++) _word(parts[i], i, shouting, i == 0 ? '' : parts[i - 1])].join(' ');
}

/// E-mail: always lower case.
String ptEmail(Object? value) => value == null ? '' : '$value'.trim().toLowerCase();

/// "Av. Papa João XXIII, 3417".
String ptStreet(Object? street, Object? number) => [ptText(street), if (number != null) '$number'.trim()].where((e) => e.isNotEmpty).join(', ');

/// CEP as 09370-901.
String ptZip(Object? value) {
  final raw = value == null ? '' : '$value';
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.length == 8 ? '${d.substring(0, 5)}-${d.substring(5)}' : raw.trim();
}

/// State registration patterns by state and number of digits ('#' = a digit). States that are not listed (AL, AP, ES, MA, MS, PI, TO) have no punctuation.
const _iePatterns = <String, Map<int, String>>{
  'AC': {13: '##.###.###/###-##'},
  'AM': {9: '##.###.###-#'},
  'BA': {8: '######-##', 9: '#######-##'},
  'CE': {9: '########-#'},
  'DF': {13: '###########-##'},
  'GO': {9: '##.###.###-#'},
  'MT': {11: '##########-#'},
  'MG': {13: '###.###.###/####'},
  'PA': {9: '##-######-#'},
  'PB': {9: '########-#'},
  'PR': {10: '###.#####-##'},
  'PE': {9: '#######-##', 14: '##.#.###.#######-#'},
  'RJ': {8: '##.###.##-#'},
  'RN': {9: '##.###.###-#', 10: '##.#.###.###-#'},
  'RS': {10: '###/#######'},
  'RO': {9: '###.#####-#'},
  'RR': {9: '########-#'},
  'SC': {9: '###.###.###'},
  'SE': {9: '########-#'},
  'SP': {12: '###.###.###.###'},
};

/// Writes the digits [d] into [pattern] ('#' = digit), stopping where the digits end (no trailing separator).
String _fill(String pattern, String d) {
  final out = StringBuffer();
  var at = 0;
  for (var i = 0; i < pattern.length && at < d.length; i++) {
    if (pattern[i] == '#') {
      out.write(d[at++]);
    } else {
      out.write(pattern[i]);
    }
  }
  return out.toString();
}

/// State registration (I.E.) with the punctuation of its state (SP 123.456.789.012, PR 123.45678-90, RS 123/4567890, MG 123.456.789/0123, ...).
/// "ISENTO", a state without punctuation and anything that does not have the digits of its state stay as typed.
String ptIe(Object? value, [Object? uf]) {
  final raw = value == null ? '' : '$value'.trim();
  final d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty || RegExp(r'[A-Za-z]').hasMatch(raw)) return raw;
  final state = '${uf ?? ''}'.toUpperCase();
  // Without the state, twelve digits are a São Paulo registration.
  final pattern = _iePatterns[state.isEmpty ? 'SP' : state]?[d.length];
  return pattern == null ? raw : _fill(pattern, d);
}

/// The I.E. while it is typed: the punctuation of the state appears as the digits do. A number with letters ("ISENTO") is left alone; without a
/// state only a complete São Paulo number (12 digits) is formatted; a state without punctuation keeps the bare digits.
String maskIeInput(String text, [String? uf]) {
  if (RegExp(r'[A-Za-z]').hasMatch(text)) return text;
  final d = text.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return '';
  final state = (uf ?? '').toUpperCase();
  if (state.isEmpty) return d.length == 12 ? _fill(_iePatterns['SP']![12]!, d) : text;
  final patterns = _iePatterns[state];
  if (patterns == null) return d;
  final lengths = patterns.keys.toList()..sort();
  // The shortest pattern that still has room for the digits, else the longest one (extra digits are dropped).
  final len = lengths.firstWhere((l) => l >= d.length, orElse: () => lengths.last);
  final pattern = patterns[len]!;
  return _fill(pattern, d.length > len ? d.substring(0, len) : d);
}

/// The CEP while it is typed: 09370-901.
String maskZip(String text, [String? uf]) {
  final d = text.replaceAll(RegExp(r'\D'), '');
  final x = d.length > 8 ? d.substring(0, 8) : d;
  return x.length > 5 ? '${x.substring(0, 5)}-${x.substring(5)}' : x;
}

/// The telephone while it is typed: (11) 2914-5677 (landline) or (11) 99999-9999 (mobile). A field holding several numbers ("... / ...", "... ou ...") and
/// a local number typed without area code ("2914-5677") are left as typed.
String maskPhone(String text, [String? uf]) {
  if (RegExp(r'[/;,]|[A-Za-z]').hasMatch(text)) return text;
  if (!text.trimLeft().startsWith('(') && RegExp(r'^\d{4,5}-\d').hasMatch(text.trim())) return text;
  final d = text.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return '';
  if (d.length > 11) return text;
  if (d.length <= 2) return '($d';
  final rest = d.substring(2);
  final cut = d.length == 11 ? 5 : 4;
  return '(${d.substring(0, 2)}) ${rest.length > cut ? '${rest.substring(0, cut)}-${rest.substring(cut)}' : rest}';
}

/// Telephone as (11) 4546-8895.
String ptPhone(Object? value) {
  final raw = value == null ? '' : '$value';
  final d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 10) return '(${d.substring(0, 2)}) ${d.substring(2, 6)}-${d.substring(6)}';
  if (d.length == 11) return '(${d.substring(0, 2)}) ${d.substring(2, 7)}-${d.substring(7)}';
  if (d.length == 8) return '${d.substring(0, 4)}-${d.substring(4)}';
  return raw.trim();
}
