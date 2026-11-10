using System.Globalization;
using System.Text.RegularExpressions;
using Ebt.Core.Data;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Sales;

/// <summary>One internal sales order ("Pedido Interno de Venda") as read from the legacy workbooks: its number (<c>04183-25</c>), the customer as typed on it and the taxes it charged.</summary>
public sealed record TaxOrderRow(string? Reference, DateOnly? Date, string? Customer, string? Document, string? Uf, decimal? Icms, decimal? Ipi,
    string? Street = null, string? District = null, string? City = null, string? ZipCode = null, string? StateRegistration = null,
    string? Contact = null, string? Phone = null, string? Email = null, string? PaymentTerm = null, string? ProductCode = null, string? Material = null, string? DeliveryAddress = null, string? Notes = null);

public sealed record CustomerTaxMatch(int CustomerId, string CustomerName, string MatchedBy, int Orders, decimal? Ipi, decimal? Icms, string Note, bool Applied);

public sealed record CustomerTaxResult(int Read, int Used, int Skipped, IReadOnlyList<CustomerTaxMatch> Matches, IReadOnlyList<string> Unmatched,
    IReadOnlyList<string>? Created = null, IReadOnlyList<string>? Ambiguous = null, int ContactsFilled = 0, int Materials = 0, IReadOnlyList<string>? IeCorrected = null, IReadOnlyList<string>? DeliveryAddresses = null, int NotesLearned = 0);

/// <summary>
/// Learns each customer's usual IPI and ICMS from the old internal sales orders and stores them on the customer (company data): the IPI and ICMS of the
/// latest order, plus a note with every rate seen (ICMS depends on the destination state, IPI changed over the years). Customers are found by CNPJ first, then by
/// name; an ambiguous name is never guessed.
/// </summary>
public sealed class CustomerTaxImporter(EbtDbContext db)
{
    private sealed record Known(int Id, string Name, string NameKey, string TradeKey, HashSet<string> Documents);

    private static readonly Regex Reference = new(@"(\d+)\s*-\s*(\d{2})", RegexOptions.Compiled);

    public async Task<CustomerTaxResult> ImportAsync(IReadOnlyList<TaxOrderRow> rows, bool apply, bool overwrite, bool createMissing = false, CancellationToken ct = default)
    {
        var (created, ambiguous) = createMissing ? await CreateMissingAsync(rows, apply, ct) : ([], []);
        var customers = await db.Customers.Include(c => c.Addresses).ToListAsync(ct);
        var known = customers.Select(c => new Known(c.Id, c.Name, KeyOf(c.Name), KeyOf(c.TradeName ?? ""),
            new[] { Digits(c.Document) }.Concat(c.Addresses.Select(a => Digits(a.Document))).Where(d => d.Length >= 11).ToHashSet())).ToList();

        var thisYear = DateTime.Now.Year;
        var byCustomer = new Dictionary<int, (string By, List<Order> Orders)>();
        var unmatched = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var skipped = 0;
        foreach (var r in rows)
        {
            if (r.Icms is null && r.Ipi is null) { skipped++; continue; }
            var (year, seq) = Parse(r);
            if (year > thisYear) { skipped++; continue; } // a year typed wrong in the file name
            var (id, by) = Find(known, r);
            if (id is null) { unmatched.Add(string.IsNullOrWhiteSpace(r.Customer) ? "(sem nome)" : r.Customer.Trim()); continue; }
            if (!byCustomer.TryGetValue(id.Value, out var entry)) byCustomer[id.Value] = entry = (by, []);
            entry.Orders.Add(new Order(r.Date ?? new DateOnly(year, 1, 1), seq, r.Reference?.Trim(), NormalizeUf(r.Uf), r.Icms, r.Ipi, r));
        }

        var matches = new List<CustomerTaxMatch>();
        var contactsFilled = 0;
        // The sheets are copied from one customer to the next, so an IE is only trusted when two or more orders of the customer carry it and no other customer's order does.
        var ieOwners = rows.Where(r => Digits(r.StateRegistration).Length >= 8)
            .GroupBy(r => Digits(r.StateRegistration)).ToDictionary(g => g.Key, g => g.Select(r => Digits(r.Document).Length >= 11 ? Digits(r.Document) : KeyOf(r.Customer ?? "")).Distinct().Count());
        var ieCorrected = new List<string>();
        var deliveries = new List<string>();
        foreach (var (id, (by, orders)) in byCustomer.OrderBy(e => e.Key))
        {
            orders.Sort((a, b) => a.Date != b.Date ? a.Date.CompareTo(b.Date) : a.Seq.CompareTo(b.Seq));
            var ipi = orders.LastOrDefault(o => o.Ipi is not null)?.Ipi;
            var icms = orders.LastOrDefault(o => o.Icms is not null)?.Icms;
            var note = Note(orders);
            var c = customers.First(x => x.Id == id);
            var take = overwrite || (c.IpiPercent is null && c.IcmsPercent is null);
            if (apply && take)
            {
                c.IpiPercent = ipi;
                c.IcmsPercent = icms;
                c.TaxNote = note;
            }
            // Contact data the cadastro lacks is completed from the latest order that has it; what is already there is never replaced.
            string? Latest(Func<TaxOrderRow, string?> pick) => orders.Select(o => Clean(pick(o.Row))).LastOrDefault(v => v is not null);
            var filled = false;
            void Fill(string? current, string? value, Action<string> set) { if (string.IsNullOrWhiteSpace(current) && value is not null) { filled = true; if (apply) set(value); } }
            Fill(c.Contact, Smart(Latest(r => r.Contact)), v => c.Contact = v);
            Fill(c.Email, Latest(r => r.Email)?.ToLowerInvariant(), v => c.Email = v);
            Fill(c.Phone, Latest(r => r.Phone), v => c.Phone = v);
            var ie = Latest(r => r.StateRegistration);
            if (Digits(ie).Length >= 5 && string.IsNullOrWhiteSpace(c.StateRegistration)) { filled = true; if (apply) { c.StateRegistration = ie; c.IcmsContributor = true; } }
            // The latest order is what the customer says today: a different IE on an order that carries the customer's own CNPJ replaces the cadastro one.
            else if (by == "CNPJ" && Digits(ie).Length >= 8 && Digits(ie) != Digits(c.StateRegistration)
                && (Digits(c.StateRegistration).Length == 0 || Digits(c.StateRegistration).Length == Digits(ie).Length)
                && orders.Count(o => Digits(o.Row.StateRegistration) == Digits(ie)) >= 2 && ieOwners.GetValueOrDefault(Digits(ie)) == 1)
            {
                ieCorrected.Add($"{c.Name}: {c.StateRegistration} -> {ie}");
                if (apply) { c.StateRegistration = ie; c.IcmsContributor = true; }
            }
            // Where the order says to deliver elsewhere than the customer's own address, that place becomes a delivery address of the customer.
            // Every distinct place named on the orders counts (the newest three), not only the one of the latest order.
            var places = orders.AsEnumerable().Reverse().Select(o => Clean(o.Row.DeliveryAddress)).Where(t => t is not null).GroupBy(t => Letters(t)).Select(g => g.First()!).Take(3).ToList();
            foreach (var deliveryText in places)
                if (NewDeliveryAddress(c, deliveryText) is { } address)
                {
                    deliveries.Add($"{c.Name}: {deliveryText}");
                    if (apply) c.Addresses.Add(address);
                }
            if (filled) contactsFilled++;
            matches.Add(new CustomerTaxMatch(id, c.Name, by, orders.Count, ipi, icms, note, apply && take));
        }
        var materials = await LearnMaterialsAsync(rows, known, apply, ct);
        if (apply) await db.SaveChangesAsync(ct);
        var notes = await LearnNotesAsync(rows, known, apply, ct);
        if (apply) await db.SaveChangesAsync(ct);
        return new CustomerTaxResult(rows.Count, matches.Sum(m => m.Orders), skipped, matches, unmatched.ToList(), created, ambiguous, contactsFilled, materials, ieCorrected, deliveries, notes);
    }

    /// <summary>The material of each customer + product code, as the old orders wrote it (the latest order wins, with how many said it).</summary>
    private async Task<int> LearnMaterialsAsync(IReadOnlyList<TaxOrderRow> rows, List<Known> known, bool apply, CancellationToken ct)
    {
        var found = new Dictionary<(int Customer, string Product), (DateOnly Date, int Seq, string? Material, int Count)>();
        foreach (var r in rows)
        {
            var material = Clean(r.Material);
            if (material is not null && (material.Length > 200 || material.StartsWith("TUBO", StringComparison.OrdinalIgnoreCase))) material = null;
            // A row without a product code still says the customer bought before: it is kept under "-".
            var product = Clean(r.ProductCode) ?? "-";
            if (product.Length > 40) continue;
            var (id, _, _) = Lookup(known, r);
            if (id is null) continue;
            var (year, seq) = Parse(r);
            if (year > DateTime.Now.Year) continue;
            var date = r.Date ?? new DateOnly(year, 1, 1);
            var key = (id.Value, product);
            found.TryGetValue(key, out var old);
            var newer = old.Count == 0 || (date, seq).CompareTo((old.Date, old.Seq)) >= 0;
            found[key] = (newer ? date : old.Date, newer ? seq : old.Seq, newer ? (material ?? old.Material) : (old.Material ?? material), old.Count + 1);
        }
        if (!apply) return found.Count;
        var existing = await db.OrderMaterials.ToListAsync(ct);
        foreach (var ((customer, product), v) in found)
        {
            var row = existing.FirstOrDefault(e => e.CustomerId == customer && e.ProductCode == product);
            if (row is null) db.OrderMaterials.Add(new Entities.OrderMaterial { CustomerId = customer, ProductCode = product, Material = v.Material, Orders = v.Count, LastDate = v.Date });
            else { row.Material = v.Material ?? row.Material; row.Orders = v.Count; row.LastDate = v.Date; }
        }
        return found.Count;
    }

    private static readonly Regex NoteWords = new("isent|tratamento|dureza|hrb|costura|solda|rebarba|cortereto|zincagem|recozido|carbono|espessura|filmar|fardo|naopassar|fieira|chapa|oleo|graxa|escovar|amarrad", RegexOptions.Compiled);
    private static readonly Regex PoPrefix = new(@"^\s*(PEDIDO(\s+DE\s+COMPRAS?)?|ORDEM\s+DE\s+COMPRA|O\.?\s?C\.?)\s*(N[º°O]?\.?)?\s*:?\s*[\d.\-/]*\s*", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex ProductCodeShape = new(@"^\d{3}\.\d{3}\.\d{2}$", RegexOptions.Compiled);

    /// <summary>
    /// What the "OBS." cells of an order sheet ask of the product ("ISENTO DE OLEO E GRAXA", "Tratamento termico 30 HRB"): the purchase-order number, the quantities and the logistics notes
    /// are dropped, only the pieces that talk about the tube itself stay. Null when there are none.
    /// </summary>
    internal static string? TechnicalNote(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var kept = new Dictionary<string, string>();
        foreach (var piece in raw.Split(" || ", StringSplitOptions.RemoveEmptyEntries))
        {
            if (Regex.IsMatch(piece, @"\bCOD\.", RegexOptions.IgnoreCase)) continue;
            var t = PoPrefix.Replace(piece, "");
            t = Regex.Replace(t, @"^[\d.]+\s+", "");
            t = Regex.Replace(t.Trim(' ', '-'), @"\s+", " ");
            if (t.Length is 0 or > 160 || !NoteWords.IsMatch(Letters(t))) continue;
            kept.TryAdd(Letters(t), t);
        }
        return kept.Count == 0 ? null : string.Join("; ", kept.Values);
    }

    private sealed class NoteTally
    {
        public int Orders;
        public DateOnly Last;
        public readonly Dictionary<string, (string Text, int N, DateOnly Last)> Notes = new();
        public void Add(string? note, DateOnly date)
        {
            Orders++;
            if (date > Last) Last = date;
            if (note is null) return;
            var key = Letters(note);
            Notes.TryGetValue(key, out var old);
            Notes[key] = (old.N == 0 || date >= old.Last ? note : old.Text, old.N + 1, date > old.Last ? date : old.Last);
        }
        public (string Text, int N)? Top => Notes.Count == 0 ? null : Notes.Values.OrderByDescending(v => v.N).ThenByDescending(v => v.Last).Select(v => (v.Text, v.N)).First();
    }

    /// <summary>
    /// The observation each customer usually puts on its orders. A note that goes on at least 70% of the customer's orders (5 or more) becomes the customer's note (product "*");
    /// otherwise a note that goes on at least half of the orders of one product (2 or more) becomes that product's note. The product's note wins over the customer's.
    /// </summary>
    private async Task<int> LearnNotesAsync(IReadOnlyList<TaxOrderRow> rows, List<Known> known, bool apply, CancellationToken ct)
    {
        var tallies = new Dictionary<int, (NoteTally All, Dictionary<string, NoteTally> Products)>();
        foreach (var r in rows)
        {
            var (id, _, _) = Lookup(known, r);
            if (id is null) continue;
            var (year, _) = Parse(r);
            if (year > DateTime.Now.Year) continue;
            var date = r.Date ?? new DateOnly(year, 1, 1);
            var note = TechnicalNote(r.Notes);
            if (!tallies.TryGetValue(id.Value, out var t)) tallies[id.Value] = t = (new NoteTally(), []);
            t.All.Add(note, date);
            var code = Clean(r.ProductCode);
            if (code is null || !ProductCodeShape.IsMatch(code)) continue;
            if (!t.Products.TryGetValue(code, out var p)) t.Products[code] = p = new NoteTally();
            p.Add(note, date);
        }
        var wanted = new Dictionary<(int Customer, string Product), (string Note, int Orders, DateOnly Last)>();
        foreach (var (customer, (all, products)) in tallies)
        {
            string? wide = null;
            if (all.Top is { } top && all.Orders >= 5 && top.N * 10 >= all.Orders * 7) { wide = top.Text; wanted[(customer, "*")] = (wide, all.Orders, all.Last); }
            foreach (var (code, tally) in products)
                if (tally.Top is { } p && tally.Orders >= 2 && p.N * 2 >= tally.Orders && (wide is null || Letters(wide) != Letters(p.Text)))
                    wanted[(customer, code)] = (p.Text, tally.Orders, tally.Last);
        }
        if (!apply) return wanted.Count;
        var existing = await db.OrderMaterials.ToListAsync(ct);
        foreach (var row in existing.Where(e => e.Note is not null && !wanted.ContainsKey((e.CustomerId, e.ProductCode)))) row.Note = null;
        foreach (var ((customer, product), v) in wanted)
        {
            var row = existing.FirstOrDefault(e => e.CustomerId == customer && e.ProductCode == product);
            if (row is null) db.OrderMaterials.Add(new Entities.OrderMaterial { CustomerId = customer, ProductCode = product, Orders = v.Orders, LastDate = v.Last, Note = v.Note });
            else row.Note = v.Note;
        }
        return wanted.Count;
    }

    /// <summary>The observation the customer usually puts on this product (its own, else the customer-wide one), or null.</summary>
    public async Task<string?> SuggestNoteAsync(int customerId, int productId, CancellationToken ct = default)
    {
        var code = await db.Products.AsNoTracking().Where(p => p.Id == productId).Select(p => p.Code).FirstOrDefaultAsync(ct);
        var codes = code is null ? new[] { "*" } : new[] { code, "*" };
        var rows = await db.OrderMaterials.AsNoTracking().Where(m => m.CustomerId == customerId && codes.Contains(m.ProductCode) && m.Note != null).Select(m => new { m.ProductCode, m.Note }).ToListAsync(ct);
        return (rows.FirstOrDefault(r => r.ProductCode == code) ?? rows.FirstOrDefault(r => r.ProductCode == "*"))?.Note;
    }

    /// <summary>The material to print on an order line that has none: what this customer's latest order for the product said, else what most orders of any customer said.</summary>
    public async Task<string?> SuggestMaterialAsync(int customerId, int productId, CancellationToken ct = default)
    {
        var line = await db.SalesOrderLines.AsNoTracking()
            .Where(l => l.ProductId == productId && l.Order!.CustomerId == customerId && l.Standard != null && l.Standard != "")
            .OrderByDescending(l => l.Order!.CreatedAt).Select(l => l.Standard).FirstOrDefaultAsync(ct);
        if (line is not null) return line;
        var code = await db.Products.AsNoTracking().Where(p => p.Id == productId).Select(p => p.Code).FirstOrDefaultAsync(ct);
        if (code is null) return null;
        var own = await db.OrderMaterials.AsNoTracking().Where(m => m.CustomerId == customerId && m.ProductCode == code && m.Material != null).Select(m => m.Material).FirstOrDefaultAsync(ct);
        if (own is not null) return own;
        return await db.OrderMaterials.AsNoTracking().Where(m => m.ProductCode == code && m.Material != null).GroupBy(m => m.Material)
            .OrderByDescending(g => g.Sum(m => m.Orders)).ThenByDescending(g => g.Max(m => m.LastDate)).Select(g => g.Key).FirstOrDefaultAsync(ct);
    }

    /// <summary>
    /// Registers the customers that appear on orders but not in the cadastro, with what the orders say (address, CNPJ, IE, contact, phone, e-mail, prazo). One customer per CNPJ
    /// (or per full name when the order has none); the latest order wins for every field. A name that could be two cadastro customers is never created.
    /// </summary>
    private async Task<(List<string> Created, List<string> Ambiguous)> CreateMissingAsync(IReadOnlyList<TaxOrderRow> rows, bool apply, CancellationToken ct)
    {
        var customers = await db.Customers.Include(c => c.Addresses).ToListAsync(ct);
        var known = customers.Select(c => new Known(c.Id, c.Name, KeyOf(c.Name), KeyOf(c.TradeName ?? ""),
            new[] { Digits(c.Document) }.Concat(c.Addresses.Select(a => Digits(a.Document))).Where(d => d.Length >= 11).ToHashSet())).ToList();
        var terms = await db.PaymentTerms.Where(p => p.Active).ToListAsync(ct);
        var thisYear = DateTime.Now.Year;

        var groups = new Dictionary<string, List<(TaxOrderRow Row, DateOnly Date, int Seq)>>();
        var ambiguous = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows)
        {
            var name = Regex.Replace(r.Customer ?? "", @"\s+", " ").Trim();
            if (KeyOf(name).Length < 4) continue;
            var (year, seq) = Parse(r);
            if (year > thisYear) continue;
            var (id, _, isAmbiguous) = Lookup(known, r);
            if (id is not null) continue;
            if (isAmbiguous) { ambiguous.Add(name); continue; }
            var doc = Digits(r.Document);
            var key = doc.Length is 11 or 14 ? doc : "n:" + PriceHistoryImporter.Fold(name).ToLowerInvariant();
            if (!groups.TryGetValue(key, out var list)) groups[key] = list = [];
            list.Add((r, r.Date ?? new DateOnly(year, 1, 1), seq));
        }

        var created = new List<string>();
        foreach (var (_, list) in groups.OrderBy(g => g.Key))
        {
            list.Sort((a, b) => a.Date != b.Date ? a.Date.CompareTo(b.Date) : a.Seq.CompareTo(b.Seq));
            string? Latest(Func<TaxOrderRow, string?> pick) => list.Select(x => Clean(pick(x.Row))).LastOrDefault(v => v is not null);
            var name = Smart(Latest(r => r.Customer))!;
            var doc = list.Select(x => Digits(x.Row.Document)).LastOrDefault(d => d.Length is 11 or 14);
            var ie = Latest(r => r.StateRegistration);
            var ieDigits = Digits(ie);
            var street = Latest(r => r.Street);
            string? number = null;
            if (street is not null)
            {
                var m = StreetNumber.Match(street);
                if (m.Success) { street = m.Groups["s"].Value.Trim(); number = m.Groups["n"].Value.Trim(); }
            }
            var zip = Digits(Latest(r => r.ZipCode));
            var term = FindTerm(terms, Latest(r => r.PaymentTerm));
            var uf = NormalizeUf(Latest(r => r.Uf));
            var c = new Entities.Customer
            {
                Name = name, Source = Entities.DataSource.Imported, ConsumerType = Entities.ConsumerType.Normal, Active = true,
                Document = doc, StateRegistration = ieDigits.Length >= 5 ? ie : null, IcmsContributor = ieDigits.Length >= 5,
                Street = Smart(street), Number = number, District = Smart(Latest(r => r.District)), City = Smart(Latest(r => r.City)),
                Uf = uf.Length == 2 ? uf : null,
                ZipCode = zip.Length == 8 ? zip : null, Contact = Smart(Latest(r => r.Contact)),
                Email = Latest(r => r.Email)?.ToLowerInvariant(), Phone = Latest(r => r.Phone), DefaultPaymentTermId = term?.Id
            };
            created.Add(name);
            if (apply) db.Customers.Add(c);
        }
        if (apply) await db.SaveChangesAsync(ct);
        return (created.Order(StringComparer.OrdinalIgnoreCase).ToList(), ambiguous.ToList());
    }

    private static string Letters(string? s) => new(PriceHistoryImporter.Fold(s ?? "").ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    /// <summary>
    /// The delivery address written on an order ("Rua Lateral,810 Vila Nova York São Paulo-SP 03479-020") as a new address of the customer, or null when it is the customer's own
    /// address (same CEP, or the same street and number) or the customer already has it.
    /// </summary>
    private static Entities.CustomerAddress? NewDeliveryAddress(Entities.Customer c, string text)
    {
        var folded = Letters(text);
        if (folded.Length < 8) return null;
        var zipMatch = Regex.Match(text, @"(\d{5})\s*-?\s*(\d{3})\b");
        var zip = zipMatch.Success ? zipMatch.Groups[1].Value + zipMatch.Groups[2].Value : null;
        var street = text;
        string? number = null;
        var sm = Regex.Match(text, @"^(?<s>[^,]+?)\s*,\s*(?<n>\d[\w\-./]*)\s*(?<rest>.*)$");
        if (sm.Success) { street = sm.Groups["s"].Value.Trim(); number = sm.Groups["n"].Value.Trim(); }
        bool Same(string? zipCode, string? st, string? no) =>
            (zip is not null && zip == Digits(zipCode) && (number is null || no is null || Letters(number) == Letters(no)))
            || (Letters(st).Length >= 4 && Letters(street) == Letters(st) && (number is null || no is null || Letters(number) == Letters(no)));
        if (Same(c.ZipCode, c.Street, c.Number)) return null;
        if (c.Addresses.Any(a => Same(a.ZipCode, a.Street, a.Number))) return null;

        string? district = null, city = null, uf = null;
        if (sm.Success)
        {
            var rest = sm.Groups["rest"].Value;
            rest = zipMatch.Success ? rest.Replace(zipMatch.Value, "") : rest;
            var um = Regex.Match(rest, @"[-/,]\s*([A-Za-z]{2})\s*$");
            if (um.Success) { uf = um.Groups[1].Value.ToUpperInvariant(); rest = rest[..um.Index]; }
            rest = rest.Trim(' ', ',', '-');
            if (!string.IsNullOrWhiteSpace(c.City))
            {
                // The customer's own city closes the text ("Vila Nova York São Paulo"): its words, compared without accents or case, are the city and the rest is the district.
                var words = rest.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var n = c.City.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
                if (words.Length >= n && Letters(string.Concat(words[^n..])) == Letters(c.City))
                {
                    city = string.Join(' ', words[^n..]);
                    district = string.Join(' ', words[..^n]).Trim(' ', ',', '-');
                }
            }
            if (city is null && rest.Length > 0) district = rest;
        }
        return new Entities.CustomerAddress
        {
            Document = c.Document ?? "", StateRegistration = c.StateRegistration, IcmsContributor = c.IcmsContributor,
            Street = Smart(street), Number = number, District = Smart(district), City = Smart(city) ?? c.City, Uf = uf ?? c.Uf ?? "", ZipCode = zip,
            Buyer = c.Contact, Email = c.Email, Phone = c.Phone
        };
    }

    private static readonly Regex StreetNumber = new(@"^(?<s>.+?)\s*[,]\s*(?<n>(?:S\s*/\s*N|\d[\w\-./]*))\s*$", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : Regex.Replace(s, @"\s+", " ").Trim();

    /// <summary>The old orders were typed in capitals: "RUA ARISUGAWA" becomes "Rua Arisugawa". Text that already has lower case is kept as typed.</summary>
    private static string? Smart(string? s)
    {
        s = Clean(s);
        if (s is null || s.Any(char.IsLower)) return s;
        var small = new HashSet<string> { "DE", "DA", "DO", "DAS", "DOS", "E" };
        var upper = new HashSet<string> { "SP", "RJ", "MG", "RS", "SC", "PR", "ME", "EPP", "SA", "S/A" };
        return string.Join(' ', s.Split(' ').Select(w => w.Length == 0 ? w : small.Contains(w) ? w.ToLowerInvariant() : upper.Contains(w) ? w : char.ToUpperInvariant(w[0]) + w[1..].ToLowerInvariant()));
    }

    private static Entities.PaymentTerm? FindTerm(List<Entities.PaymentTerm> terms, string? text)
    {
        static string Nums(string? s) => string.Join('/', Regex.Matches(s ?? "", @"\d+").Select(m => m.Value));
        var want = Nums(text);
        if (want.Length == 0) return null;
        var hit = terms.Where(t => Nums(t.Days) == want || Nums(t.Name) == want).ToList();
        return hit.Count == 1 ? hit[0] : null;
    }

    private sealed record Order(DateOnly Date, int Seq, string? Reference, string Uf, decimal? Icms, decimal? Ipi, TaxOrderRow Row);

    private static (int? Id, string By) Find(List<Known> known, TaxOrderRow r)
    {
        var (id, by, _) = Lookup(known, r);
        return (id, by);
    }

    private static (int? Id, string By, bool Ambiguous) Lookup(List<Known> known, TaxOrderRow r)
    {
        var doc = Digits(r.Document);
        if (doc.Length >= 11)
        {
            var byDoc = known.Where(k => k.Documents.Contains(doc)).Select(k => k.Id).Distinct().ToList();
            if (byDoc.Count == 1) return (byDoc[0], "CNPJ", false);
            if (byDoc.Count > 1) return (null, "", true);
        }
        var key = KeyOf(r.Customer ?? "");
        if (key.Length < 4) return (null, "", false);
        // Same 6-letter key, or the customer's short trade name (4+ letters) opens the name on the order ("JAVA" -> "Java Peças Diesel").
        var byName = known.Where(k => k.NameKey == key || k.TradeKey == key || (k.TradeKey.Length >= 4 && key.StartsWith(k.TradeKey, StringComparison.Ordinal))).Select(k => k.Id).Distinct().ToList();
        return byName.Count == 1 ? (byName[0], "nome", false) : (null, "", byName.Count > 1);
    }

    private static string Note(List<Order> orders)
    {
        static string Pct(decimal v) => v.ToString("0.##", CultureInfo.GetCultureInfo("pt-BR")) + "%";
        var icms = orders.Where(o => o.Icms is not null).GroupBy(o => (o.Uf, Rate: o.Icms!.Value)).OrderByDescending(g => g.Count())
            .Select(g => g.Key.Uf.Length > 0 ? $"{Pct(g.Key.Rate)} ({g.Key.Uf}, {g.Count()} ped.)" : $"{Pct(g.Key.Rate)} ({g.Count()} ped.)");
        var ipi = orders.Where(o => o.Ipi is not null).GroupBy(o => o.Ipi!.Value).OrderByDescending(g => g.Count()).Select(g => $"{Pct(g.Key)} ({g.Count()})");
        var last = orders[^1];
        var parts = new List<string>();
        if (orders.Any(o => o.Icms is not null)) parts.Add("ICMS: " + string.Join("; ", icms));
        if (orders.Any(o => o.Ipi is not null)) parts.Add("IPI: " + string.Join("; ", ipi));
        return $"Pedidos internos {orders[0].Date.Year}-{last.Date.Year}. {string.Join(". ", parts)}. Valores do cadastro: os do último pedido{(string.IsNullOrEmpty(last.Reference) ? "" : $" ({last.Reference})")}.";
    }

    private static (int Year, int Seq) Parse(TaxOrderRow r)
    {
        var m = Reference.Match(r.Reference ?? "");
        var seq = m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
        var year = r.Date?.Year ?? (m.Success ? 2000 + int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) : 2000);
        return (year, seq);
    }

    private static string NormalizeUf(string? uf)
    {
        var f = PriceHistoryImporter.Fold(uf ?? "").ToUpperInvariant().Replace(".", "").Trim();
        return f switch { "SAO PAULO" => "SP", "SANTA CATARINA" => "SC", "RIO GRANDE DO SUL" => "RS", "PARANA" => "PR", "MINAS GERAIS" => "MG", "RIO DE JANEIRO" => "RJ", "ESPIRITO SANTO" => "ES", _ => f.Length == 2 ? f : "" };
    }

    private static string KeyOf(string name) => PriceHistoryImporter.CustomerKey(name);

    private static string Digits(string? s) => new((s ?? "").Where(char.IsDigit).ToArray());
}
