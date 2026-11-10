using System.Globalization;
using System.Text.RegularExpressions;
using Ebt.Core.Data;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Sales;

/// <summary>One internal sales order ("Pedido Interno de Venda") as read from the legacy workbooks: its number (<c>04183-25</c>), the customer as typed on it and the taxes it charged.</summary>
public sealed record TaxOrderRow(string? Reference, DateOnly? Date, string? Customer, string? Document, string? Uf, decimal? Icms, decimal? Ipi);

public sealed record CustomerTaxMatch(int CustomerId, string CustomerName, string MatchedBy, int Orders, decimal? Ipi, decimal? Icms, string Note, bool Applied);

public sealed record CustomerTaxResult(int Read, int Used, int Skipped, IReadOnlyList<CustomerTaxMatch> Matches, IReadOnlyList<string> Unmatched);

/// <summary>
/// Learns each customer's usual IPI and ICMS from the old internal sales orders and stores them on the customer (company data): the IPI and ICMS of the
/// latest order, plus a note with every rate seen (ICMS depends on the destination state, IPI changed over the years). Customers are found by CNPJ first, then by
/// name; an ambiguous name is never guessed.
/// </summary>
public sealed class CustomerTaxImporter(EbtDbContext db)
{
    private sealed record Known(int Id, string Name, string NameKey, string TradeKey, HashSet<string> Documents);

    private static readonly Regex Reference = new(@"(\d+)\s*-\s*(\d{2})", RegexOptions.Compiled);

    public async Task<CustomerTaxResult> ImportAsync(IReadOnlyList<TaxOrderRow> rows, bool apply, bool overwrite, CancellationToken ct = default)
    {
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
            entry.Orders.Add(new Order(r.Date ?? new DateOnly(year, 1, 1), seq, r.Reference?.Trim(), NormalizeUf(r.Uf), r.Icms, r.Ipi));
        }

        var matches = new List<CustomerTaxMatch>();
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
            matches.Add(new CustomerTaxMatch(id, c.Name, by, orders.Count, ipi, icms, note, apply && take));
        }
        if (apply) await db.SaveChangesAsync(ct);
        return new CustomerTaxResult(rows.Count, matches.Sum(m => m.Orders), skipped, matches, unmatched.ToList());
    }

    private sealed record Order(DateOnly Date, int Seq, string? Reference, string Uf, decimal? Icms, decimal? Ipi);

    private static (int? Id, string By) Find(List<Known> known, TaxOrderRow r)
    {
        var doc = Digits(r.Document);
        if (doc.Length >= 11)
        {
            var byDoc = known.Where(k => k.Documents.Contains(doc)).Select(k => k.Id).Distinct().ToList();
            if (byDoc.Count == 1) return (byDoc[0], "CNPJ");
        }
        var key = KeyOf(r.Customer ?? "");
        if (key.Length < 4) return (null, "");
        // Same 6-letter key, or the customer's short trade name (4+ letters) opens the name on the order ("JAVA" -> "Java Peças Diesel").
        var byName = known.Where(k => k.NameKey == key || k.TradeKey == key || (k.TradeKey.Length >= 4 && key.StartsWith(k.TradeKey, StringComparison.Ordinal))).Select(k => k.Id).Distinct().ToList();
        return byName.Count == 1 ? (byName[0], "nome") : (null, "");
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
