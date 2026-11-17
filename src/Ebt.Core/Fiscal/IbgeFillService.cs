using Ebt.Core.Data;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Fiscal;

/// <summary>An address that still has no IBGE code after the fill: whose it is, and the city and state that matched nothing.</summary>
public sealed record IbgeUnmatched(string Kind, int OwnerId, string Owner, string? City, string? Uf);

public sealed record IbgeFillResult(bool Applied, int Checked, int AlreadyFilled, int Filled, int Unmatched, IReadOnlyList<IbgeUnmatched> Missing);

/// <summary>
/// Gives every customer, delivery address and supplier address that has no (or a malformed) IBGE code the one of its city and state, from the built-in
/// municipality table. Only empty or malformed codes are filled: a valid code is never changed. Nothing is deleted. Preview first (<c>apply: false</c>).
/// </summary>
public sealed class IbgeFillService(EbtDbContext db)
{
    private static bool Valid(string? code) => code is { Length: 7 } && code.All(char.IsDigit);

    public async Task<IbgeFillResult> FillAsync(bool apply, CancellationToken ct = default)
    {
        int total = 0, already = 0, filled = 0;
        var missing = new List<IbgeUnmatched>();

        foreach (var c in await db.Customers.Where(c => c.City != null && c.City != "").ToListAsync(ct))
        {
            total++;
            if (Valid(c.CityIbgeCode)) { already++; continue; }
            if (IbgeMunicipalities.Find(c.City, c.Uf) is { } code) { filled++; if (apply) c.CityIbgeCode = code; }
            else missing.Add(new("Cliente (cadastro)", c.Id, c.Name, c.City, c.Uf));
        }

        var addresses = await db.CustomerAddresses.Include(a => a.Customer).ToListAsync(ct);
        foreach (var a in addresses)
        {
            total++;
            if (Valid(a.CityIbgeCode)) { already++; continue; }
            if (IbgeMunicipalities.Find(a.City, a.Uf) is { } code) { filled++; if (apply) a.CityIbgeCode = code; }
            else missing.Add(new("Cliente (endereço)", a.CustomerId, a.Customer?.Name ?? $"#{a.CustomerId}", a.City, a.Uf));
        }

        var suppliers = await db.SupplierAddresses.Include(a => a.Supplier).ToListAsync(ct);
        foreach (var a in suppliers)
        {
            total++;
            if (Valid(a.CityIbgeCode)) { already++; continue; }
            if (IbgeMunicipalities.Find(a.City, a.Uf) is { } code) { filled++; if (apply) a.CityIbgeCode = code; }
            else missing.Add(new("Fornecedor (endereço)", a.SupplierId, a.Supplier?.Name ?? $"#{a.SupplierId}", a.City, a.Uf));
        }

        if (apply && filled > 0) await db.SaveChangesAsync(ct);
        return new IbgeFillResult(apply, total, already, filled, missing.Count, missing.OrderBy(m => m.Owner).ToList());
    }
}
