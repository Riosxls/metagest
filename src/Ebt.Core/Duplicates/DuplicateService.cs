using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Duplicates;

public enum DuplicateKind { Customer, Product, Supplier }

/// <summary>A record as the duplicate screens show it: enough to recognise it without opening it.</summary>
public sealed record DuplicateRecord(int Id, string Label, string? Detail, bool Active);

/// <summary>One reason two records look alike. <see cref="Code"/> is stable (document, document-root, name, name-contains, name-similar, legacy-code, code, measures, customer-part).</summary>
public sealed record DuplicateReason(string Code, string Text, int Score);

public sealed record DuplicatePair(DuplicateRecord A, DuplicateRecord B, int Score, IReadOnlyList<DuplicateReason> Reasons);

/// <summary>Records tied together by pairs of suspected duplicates (a record in the middle can link two that do not look alike directly).</summary>
public sealed record DuplicateGroup(IReadOnlyList<DuplicateRecord> Members, IReadOnlyList<DuplicatePair> Pairs, int Score);

/// <summary>A pair somebody marked as "not a duplicate".</summary>
public sealed record DismissedPair(int Id, DuplicateRecord Other, string? Reason, DateTimeOffset CreatedAt, string? CreatedBy);

/// <summary>
/// Finds records that look like the same real-world thing: customers and suppliers by CNPJ/CPF, name and legacy code, products by code,
/// measures and the customer's own part number. It only reports; nothing is merged. A pair marked as "not a duplicate" is never reported again.
/// Records flagged as Test data are left out, like in the dashboards.
/// </summary>
public sealed class DuplicateService(EbtDbContext db)
{
    public const int DefaultMinScore = 60;

    // ---- normalization (public: the rules are the contract and have their own tests) ----

    /// <summary>Only the digits of a CNPJ/CPF (or any code).</summary>
    public static string Digits(string? s) => s is null ? "" : new string(s.Where(char.IsDigit).ToArray());

    private static readonly HashSet<string> NameNoise = ["LTDA", "LTD", "ME", "EPP", "EIRELI", "MEI", "SA", "SS", "CIA", "DE", "DA", "DO", "DAS", "DOS", "E"];
    private static readonly Regex SaForms = new(@"\bS\s*[/.]\s*A\b\.?", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// <summary>Upper case, no accents, no punctuation.</summary>
    public static string Fold(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        var d = s.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (var c in d)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.NonSpacingMark) continue;
            sb.Append(char.IsLetterOrDigit(c) ? char.ToUpperInvariant(c) : ' ');
        }
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary>Tokens of a company name without case, accents, punctuation and legal suffixes (LTDA, S.A., ME, EPP, EIRELI...).</summary>
    public static string[] NameTokens(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return [];
        return Fold(SaForms.Replace(name, " SA ")).Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(t => !NameNoise.Contains(t)).ToArray();
    }

    public static string NameKey(string? name) => string.Join(' ', NameTokens(name));

    /// <summary>A product code without separators and case ("060.075.1" equals "0600751").</summary>
    public static string CodeKey(string? code) => string.Concat(Fold(code).Where(char.IsLetterOrDigit));

    // ---- loading ----

    private sealed record Party(int Id, DuplicateRecord Record, string[] NameKeys, string[] Documents, string? Legacy);

    private static string? Join(params string?[] parts) => parts.Any(p => !string.IsNullOrWhiteSpace(p)) ? string.Join(" · ", parts.Where(p => !string.IsNullOrWhiteSpace(p))) : null;

    private static string FmtDocument(string digits) => digits.Length switch
    {
        14 => $"{digits[..2]}.{digits[2..5]}.{digits[5..8]}/{digits[8..12]}-{digits[12..]}",
        11 => $"{digits[..3]}.{digits[3..6]}.{digits[6..9]}-{digits[9..]}",
        _ => digits
    };

    private static string[] ValidDocuments(IEnumerable<string?> raw) => raw.Select(Digits).Where(d => d.Length is 11 or 14).Distinct().ToArray();

    private static string? LegacyKey(string? code) => string.IsNullOrWhiteSpace(code) ? null : (code.Trim().TrimStart('0') is { Length: > 0 } t ? t.ToUpperInvariant() : "0");

    private static string[] Keys(params string?[] names) => names.Select(NameKey).Where(k => k.Length >= 3).Distinct().ToArray();

    private async Task<List<Party>> LoadCustomersAsync(CancellationToken ct)
    {
        var rows = await db.Customers.AsNoTracking().Where(c => c.Source != DataSource.Test)
            .Select(c => new { c.Id, c.Name, c.TradeName, c.Document, c.LegacyCode, c.Active, c.City, c.Uf }).ToListAsync(ct);
        var addr = (await db.CustomerAddresses.AsNoTracking().Where(a => a.Customer!.Source != DataSource.Test).Select(a => new { a.CustomerId, a.Document }).ToListAsync(ct))
            .GroupBy(a => a.CustomerId).ToDictionary(g => g.Key, g => g.Select(a => a.Document).ToList());
        return rows.Select(c =>
        {
            var docs = ValidDocuments([c.Document, .. addr.GetValueOrDefault(c.Id) ?? []]);
            var place = string.IsNullOrWhiteSpace(c.City) ? null : $"{c.City}/{c.Uf}";
            var shown = docs.Length > 0 ? FmtDocument(Digits(c.Document).Length is 11 or 14 ? Digits(c.Document) : docs[0]) : null;
            return new Party(c.Id, new DuplicateRecord(c.Id, c.Name, Join(c.TradeName, shown, place), c.Active), Keys(c.Name, c.TradeName), docs, LegacyKey(c.LegacyCode));
        }).ToList();
    }

    private async Task<List<Party>> LoadSuppliersAsync(CancellationToken ct)
    {
        var rows = await db.Suppliers.AsNoTracking().Where(s => s.Source != DataSource.Test).Select(s => new { s.Id, s.Name, s.TradeName, s.LegacyCode, s.Active }).ToListAsync(ct);
        var addr = (await db.SupplierAddresses.AsNoTracking().Where(a => a.Supplier!.Source != DataSource.Test).Select(a => new { a.SupplierId, a.Document, a.City, a.Uf }).ToListAsync(ct))
            .GroupBy(a => a.SupplierId).ToDictionary(g => g.Key, g => g.ToList());
        return rows.Select(s =>
        {
            var list = addr.GetValueOrDefault(s.Id) ?? [];
            var docs = ValidDocuments(list.Select(a => a.Document));
            var first = list.FirstOrDefault();
            var place = first is null || string.IsNullOrWhiteSpace(first.City) ? null : $"{first.City}/{first.Uf}";
            return new Party(s.Id, new DuplicateRecord(s.Id, s.Name, Join(s.TradeName, docs.Length > 0 ? FmtDocument(docs[0]) : null, place), s.Active), Keys(s.Name, s.TradeName), docs, LegacyKey(s.LegacyCode));
        }).ToList();
    }

    // ---- matching ----

    private sealed class Pairs
    {
        public readonly Dictionary<(int, int), List<DuplicateReason>> Found = [];

        public void Add(int x, int y, DuplicateReason r)
        {
            if (x == y) return;
            var key = x < y ? (x, y) : (y, x);
            if (!Found.TryGetValue(key, out var list)) Found[key] = list = [];
            if (list.All(o => o.Code != r.Code)) list.Add(r);
        }

        /// <summary>Every pair of the records that share one key.</summary>
        public void AddGroup(IEnumerable<int> ids, DuplicateReason r)
        {
            var a = ids.Distinct().ToList();
            if (a.Count > 30) return; // a key this common (a placeholder name) says nothing about identity
            for (var i = 0; i < a.Count; i++)
                for (var j = i + 1; j < a.Count; j++) Add(a[i], a[j], r);
        }
    }

    private static readonly DuplicateReason ReasonDocument = new("document", "Mesmo CNPJ/CPF", 100);
    private static readonly DuplicateReason ReasonRoot = new("document-root", "Mesma raiz de CNPJ (matriz e filial)", 60);
    private static readonly DuplicateReason ReasonLegacy = new("legacy-code", "Mesmo código antigo", 95);
    private static readonly DuplicateReason ReasonName = new("name", "Mesmo nome (sem LTDA, S.A. e pontuação)", 90);
    private static readonly DuplicateReason ReasonContains = new("name-contains", "Um nome contém o outro", 75);
    private static readonly DuplicateReason ReasonSimilar = new("name-similar", "Nomes parecidos", 70);

    private static void MatchParties(List<Party> parties, Pairs pairs)
    {
        foreach (var g in parties.SelectMany(p => p.Documents.Select(d => (d, p.Id))).GroupBy(x => x.d)) pairs.AddGroup(g.Select(x => x.Id), ReasonDocument);
        foreach (var g in parties.SelectMany(p => p.Documents.Where(d => d.Length == 14).Select(d => (d[..8], p.Id))).GroupBy(x => x.Item1)) pairs.AddGroup(g.Select(x => x.Id), ReasonRoot);
        foreach (var g in parties.Where(p => p.Legacy != null).GroupBy(p => p.Legacy!)) pairs.AddGroup(g.Select(p => p.Id), ReasonLegacy);
        foreach (var g in parties.SelectMany(p => p.NameKeys.Select(k => (k, p.Id))).GroupBy(x => x.k)) pairs.AddGroup(g.Select(x => x.Id), ReasonName);

        // Similar names: only records that share a meaningful word are compared.
        var byId = parties.ToDictionary(p => p.Id);
        var tokens = parties.ToDictionary(p => p.Id, p => p.NameKeys.Select(k => k.Split(' ')).ToList());
        var index = new Dictionary<string, List<int>>();
        foreach (var p in parties)
            foreach (var t in tokens[p.Id].SelectMany(x => x).Where(t => t.Length >= 3).Distinct())
            {
                if (!index.TryGetValue(t, out var l)) index[t] = l = [];
                l.Add(p.Id);
            }
        var seen = new HashSet<(int, int)>();
        foreach (var posting in index.Values.Where(l => l.Count is > 1 and <= 40))
            for (var i = 0; i < posting.Count; i++)
                for (var j = i + 1; j < posting.Count; j++)
                {
                    var key = posting[i] < posting[j] ? (posting[i], posting[j]) : (posting[j], posting[i]);
                    if (!seen.Add(key)) continue;
                    var r = SimilarName(tokens[key.Item1], tokens[key.Item2]);
                    if (r != null) pairs.Add(key.Item1, key.Item2, r);
                }
    }

    /// <summary>"ACME TUBOS" inside "ACME TUBOS INDUSTRIAIS", or two names that differ by a word or a typo.</summary>
    private static DuplicateReason? SimilarName(List<string[]> a, List<string[]> b)
    {
        DuplicateReason? best = null;
        foreach (var x in a)
            foreach (var y in b)
            {
                var (small, big) = x.Length <= y.Length ? (x, y) : (y, x);
                if (small.Length == 0 || small.SequenceEqual(big)) continue; // equal keys are reported by the exact rule
                var common = small.Intersect(big).Count();
                if (common == small.Length && (small.Length >= 2 || small[0].Length >= 5)) return ReasonContains;
                var dice = 2.0 * common / (small.Length + big.Length);
                if (small.Length >= 2 && dice >= 0.8) best = ReasonSimilar;
            }
        return best;
    }

    private async Task<(Dictionary<int, DuplicateRecord> Records, Pairs Pairs)> ComputeProductsAsync(CancellationToken ct)
    {
        var rows = await db.Products.AsNoTracking().Where(p => p.Source != DataSource.Test)
            .Select(p => new { p.Id, p.Code, p.Name, p.Shape, p.DiameterMm, p.WidthMm, p.HeightMm, p.ThicknessMm, p.LengthMm, p.Blocked }).ToListAsync(ct);
        var records = rows.ToDictionary(p => p.Id, p => new DuplicateRecord(p.Id, $"{p.Code} · {p.Name}", Measures(p.Shape, p.DiameterMm, p.WidthMm, p.HeightMm, p.ThicknessMm, p.LengthMm), !p.Blocked));
        var pairs = new Pairs();
        foreach (var g in rows.Where(p => CodeKey(p.Code).Length > 0).GroupBy(p => CodeKey(p.Code))) pairs.AddGroup(g.Select(p => p.Id), new DuplicateReason("code", "Mesmo código (sem pontos e traços)", 100));
        foreach (var g in rows.Select(p => (Key: MeasureKey(p.Shape, p.DiameterMm, p.WidthMm, p.HeightMm, p.ThicknessMm, p.LengthMm), p.Id)).Where(x => x.Key != null).GroupBy(x => x.Key))
            pairs.AddGroup(g.Select(x => x.Id), new DuplicateReason("measures", "Mesmas medidas", 85));
        foreach (var g in rows.Where(p => NameKey(p.Name).Length >= 3).GroupBy(p => NameKey(p.Name))) pairs.AddGroup(g.Select(p => p.Id), new DuplicateReason("name", "Mesmo nome", 70));
        var parts = await db.ProductCustomers.AsNoTracking().Where(pc => pc.Product!.Source != DataSource.Test && pc.CustomerPartNumber != null)
            .Select(pc => new { pc.ProductId, pc.CustomerId, pc.CustomerPartNumber }).ToListAsync(ct);
        foreach (var g in parts.Where(x => CodeKey(x.CustomerPartNumber).Length >= 3).GroupBy(x => (x.CustomerId, Key: CodeKey(x.CustomerPartNumber))))
            pairs.AddGroup(g.Select(x => x.ProductId), new DuplicateReason("customer-part", "Mesmo código do cliente para o mesmo cliente", 80));
        return (records, pairs);
    }

    private static string? MeasureKey(TubeShape? shape, decimal? d, decimal? w, decimal? h, decimal? t, decimal? l)
    {
        static string R(decimal? v) => decimal.Round(v!.Value, 2).ToString("0.##", CultureInfo.InvariantCulture);
        if (t is null or <= 0 || l is null or <= 0) return null;
        if (shape == TubeShape.Rectangular) return w is > 0 && h is > 0 ? $"R|{R(w)}|{R(h)}|{R(t)}|{R(l)}" : null;
        return d is > 0 ? $"C|{R(d)}|{R(t)}|{R(l)}" : null;
    }

    private static string? Measures(TubeShape? shape, decimal? d, decimal? w, decimal? h, decimal? t, decimal? l)
    {
        static string N(decimal? v) => v is null ? "?" : v.Value.ToString("0.##", CultureInfo.GetCultureInfo("pt-BR"));
        var size = shape == TubeShape.Rectangular ? $"{N(w)} x {N(h)} x {N(t)} x {N(l)} mm" : $"Ø {N(d)} x {N(t)} x {N(l)} mm";
        return d is null && w is null && t is null && l is null ? null : size;
    }

    // ---- public API ----

    private async Task<(Dictionary<int, DuplicateRecord> Records, Pairs Pairs)> ComputeAsync(DuplicateKind kind, CancellationToken ct)
    {
        if (kind == DuplicateKind.Product) return await ComputeProductsAsync(ct);
        var parties = kind == DuplicateKind.Customer ? await LoadCustomersAsync(ct) : await LoadSuppliersAsync(ct);
        var pairs = new Pairs();
        MatchParties(parties, pairs);
        return (parties.ToDictionary(p => p.Id, p => p.Record), pairs);
    }

    private static string KindName(DuplicateKind k) => k.ToString().ToLowerInvariant();

    private static int Score(List<DuplicateReason> reasons) => Math.Min(100, reasons.Max(r => r.Score) + 5 * (reasons.Count - 1));

    /// <summary>Suspected pairs at or above <paramref name="minScore"/>, best first, without the pairs marked as "not a duplicate". With <paramref name="forId"/> only the pairs of that record, with it as <c>A</c>.</summary>
    public async Task<List<DuplicatePair>> PairsAsync(DuplicateKind kind, int minScore = DefaultMinScore, int? forId = null, CancellationToken ct = default)
    {
        var (records, found) = await ComputeAsync(kind, ct);
        var name = KindName(kind);
        var dismissed = (await db.DuplicateDismissals.AsNoTracking().Where(d => d.Kind == name).Select(d => new { d.LowId, d.HighId }).ToListAsync(ct)).Select(d => (d.LowId, d.HighId)).ToHashSet();
        var result = new List<DuplicatePair>();
        foreach (var ((lo, hi), raw) in found.Found)
        {
            if (forId != null && lo != forId && hi != forId) continue;
            if (dismissed.Contains((lo, hi))) continue;
            // The same CNPJ already says everything the root says.
            var reasons = raw.Any(r => r.Code == "document") ? raw.Where(r => r.Code != "document-root").ToList() : raw;
            var score = Score(reasons);
            if (score < minScore) continue;
            var (a, b) = forId == hi ? (hi, lo) : (lo, hi);
            result.Add(new DuplicatePair(records[a], records[b], score, reasons.OrderByDescending(r => r.Score).ToList()));
        }
        return result.OrderByDescending(p => p.Score).ThenBy(p => p.A.Label, StringComparer.CurrentCultureIgnoreCase).ThenBy(p => p.B.Label, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Pairs joined into groups (a record linked to two others puts all three together), best group first.</summary>
    public static List<DuplicateGroup> Group(IReadOnlyList<DuplicatePair> pairs)
    {
        var parent = new Dictionary<int, int>();
        int Find(int x) { while (parent[x] != x) x = parent[x] = parent[parent[x]]; return x; }
        foreach (var p in pairs)
        {
            parent.TryAdd(p.A.Id, p.A.Id);
            parent.TryAdd(p.B.Id, p.B.Id);
            parent[Find(p.A.Id)] = Find(p.B.Id);
        }
        return pairs.GroupBy(p => Find(p.A.Id)).Select(g =>
        {
            var members = g.SelectMany(p => new[] { p.A, p.B }).DistinctBy(r => r.Id).OrderBy(r => r.Label, StringComparer.CurrentCultureIgnoreCase).ToList();
            return new DuplicateGroup(members, g.ToList(), g.Max(p => p.Score));
        }).OrderByDescending(g => g.Score).ThenByDescending(g => g.Members.Count).ToList();
    }

    /// <summary>Pairs somebody marked as "not a duplicate" that involve the record, with who did it, so they can be taken back.</summary>
    public async Task<List<DismissedPair>> DismissedAsync(DuplicateKind kind, int id, CancellationToken ct = default)
    {
        var name = KindName(kind);
        var rows = await db.DuplicateDismissals.AsNoTracking().Where(d => d.Kind == name && (d.LowId == id || d.HighId == id)).OrderByDescending(d => d.CreatedAt).ToListAsync(ct);
        if (rows.Count == 0) return [];
        var others = rows.Select(d => d.LowId == id ? d.HighId : d.LowId).ToList();
        var labels = await LabelsAsync(kind, others, ct);
        return rows.Select(d =>
        {
            var other = d.LowId == id ? d.HighId : d.LowId;
            return new DismissedPair(d.Id, labels.GetValueOrDefault(other) ?? new DuplicateRecord(other, $"#{other} (removido)", null, false), d.Reason, d.CreatedAt, d.CreatedBy);
        }).ToList();
    }

    private async Task<Dictionary<int, DuplicateRecord>> LabelsAsync(DuplicateKind kind, List<int> ids, CancellationToken ct) => kind switch
    {
        DuplicateKind.Customer => await db.Customers.AsNoTracking().Where(c => ids.Contains(c.Id)).ToDictionaryAsync(c => c.Id, c => new DuplicateRecord(c.Id, c.Name, c.TradeName, c.Active), ct),
        DuplicateKind.Supplier => await db.Suppliers.AsNoTracking().Where(s => ids.Contains(s.Id)).ToDictionaryAsync(s => s.Id, s => new DuplicateRecord(s.Id, s.Name, s.TradeName, s.Active), ct),
        _ => await db.Products.AsNoTracking().Where(p => ids.Contains(p.Id)).ToDictionaryAsync(p => p.Id, p => new DuplicateRecord(p.Id, p.Code + " · " + p.Name, null, !p.Blocked), ct)
    };

    private async Task<bool> ExistsAsync(DuplicateKind kind, int id, CancellationToken ct) => kind switch
    {
        DuplicateKind.Customer => await db.Customers.AnyAsync(c => c.Id == id, ct),
        DuplicateKind.Supplier => await db.Suppliers.AnyAsync(s => s.Id == id, ct),
        _ => await db.Products.AnyAsync(p => p.Id == id, ct)
    };

    public enum DismissResult { Done, SameRecord, NotFound }

    /// <summary>Marks the pair as "not a duplicate". Marking it twice keeps the first row.</summary>
    public async Task<DismissResult> DismissAsync(DuplicateKind kind, int a, int b, string? reason, string? user, CancellationToken ct = default)
    {
        if (a == b) return DismissResult.SameRecord;
        if (!await ExistsAsync(kind, a, ct) || !await ExistsAsync(kind, b, ct)) return DismissResult.NotFound;
        var (lo, hi) = a < b ? (a, b) : (b, a);
        var name = KindName(kind);
        if (await db.DuplicateDismissals.AnyAsync(d => d.Kind == name && d.LowId == lo && d.HighId == hi, ct)) return DismissResult.Done;
        db.DuplicateDismissals.Add(new DuplicateDismissal { Kind = name, LowId = lo, HighId = hi, Reason = string.IsNullOrWhiteSpace(reason) ? null : reason.Trim(), CreatedAt = DateTimeOffset.UtcNow, CreatedBy = user });
        await db.SaveChangesAsync(ct);
        return DismissResult.Done;
    }

    /// <summary>Takes the mark back so the pair is flagged again. False when there was none.</summary>
    public async Task<bool> RestoreAsync(DuplicateKind kind, int a, int b, CancellationToken ct = default)
    {
        var (lo, hi) = a < b ? (a, b) : (b, a);
        var name = KindName(kind);
        var row = await db.DuplicateDismissals.FirstOrDefaultAsync(d => d.Kind == name && d.LowId == lo && d.HighId == hi, ct);
        if (row is null) return false;
        db.DuplicateDismissals.Remove(row); // through the change tracker so the audit log sees it
        await db.SaveChangesAsync(ct);
        return true;
    }
}
