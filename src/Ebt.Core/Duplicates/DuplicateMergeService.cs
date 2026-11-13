using System.Globalization;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Duplicates;

/// <summary>One field of the comparison: the value each record holds (by record id, null when empty).</summary>
public sealed record CompareField(string Key, string Label, IReadOnlyDictionary<int, string?> Values, bool Differs);

/// <summary>What points at a record (orders, quotes...), so the user can tell which one is in use.</summary>
public sealed record CompareUsage(string Label, int Count);

public sealed record CompareRecord(int Id, string Label, bool Active, IReadOnlyList<CompareUsage> Usage, int Addresses);

public sealed record CompareOut(IReadOnlyList<CompareRecord> Records, IReadOnlyList<CompareField> Fields);

/// <param name="KeepId">The record that stays.</param>
/// <param name="OtherIds">The duplicates that are deactivated.</param>
/// <param name="Fields">Field key -> id of the record whose value goes into the kept one. A field not listed keeps its value.</param>
/// <param name="MoveAddresses">Customers and suppliers: addresses of the duplicates move to the kept record.</param>
public sealed record ResolveIn(int KeepId, IReadOnlyList<int> OtherIds, Dictionary<string, int>? Fields, bool MoveAddresses);

public sealed record ResolveOut(int KeepId, int FieldsChanged, int AddressesMoved, int Deactivated);

/// <summary>
/// Compares duplicate records field by field and settles them: the chosen values go into the record that stays and the others are deactivated
/// (customers and suppliers: Active = false; products: Blocked = true). Nothing is deleted and orders, quotes and history keep pointing at the
/// record they always pointed at. The pair is then marked "not a duplicate" so it is not flagged again.
/// </summary>
public sealed class DuplicateMergeService(EbtDbContext db, DuplicateService duplicates)
{
    private sealed record Spec<T>(string Key, string Label, Func<T, string?> Get, Action<T, string?> Set);

    private static string? S(string? v) => string.IsNullOrWhiteSpace(v) ? null : v.Trim();
    private static string? N(decimal? v) => v?.ToString("0.####", CultureInfo.InvariantCulture);
    private static string? N(int? v) => v?.ToString(CultureInfo.InvariantCulture);
    private static decimal? D(string? v) => decimal.TryParse(v, NumberStyles.Any, CultureInfo.InvariantCulture, out var d) ? d : null;
    private static int? I(string? v) => int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var d) ? d : null;

    private static readonly Spec<Customer>[] CustomerSpecs =
    [
        new("name", "Nome", c => c.Name, (c, v) => c.Name = S(v) ?? c.Name),
        new("tradeName", "Nome fantasia", c => c.TradeName, (c, v) => c.TradeName = S(v)),
        new("legalName", "Razão social (NF)", c => c.LegalName, (c, v) => c.LegalName = S(v)),
        new("document", "CNPJ/CPF", c => c.Document, (c, v) => c.Document = S(v)),
        new("stateRegistration", "Inscrição estadual", c => c.StateRegistration, (c, v) => c.StateRegistration = S(v)),
        new("street", "Rua", c => c.Street, (c, v) => c.Street = S(v)),
        new("number", "Número", c => c.Number, (c, v) => c.Number = S(v)),
        new("complement", "Complemento", c => c.Complement, (c, v) => c.Complement = S(v)),
        new("district", "Bairro", c => c.District, (c, v) => c.District = S(v)),
        new("city", "Cidade", c => c.City, (c, v) => c.City = S(v)),
        new("uf", "UF", c => c.Uf, (c, v) => c.Uf = S(v)),
        new("zipCode", "CEP", c => c.ZipCode, (c, v) => c.ZipCode = S(v)),
        new("contact", "Contato", c => c.Contact, (c, v) => c.Contact = S(v)),
        new("email", "E-mail", c => c.Email, (c, v) => c.Email = S(v)),
        new("phone", "Telefone", c => c.Phone, (c, v) => c.Phone = S(v)),
        new("legacyCode", "Código antigo", c => c.LegacyCode, (c, v) => c.LegacyCode = S(v)),
        new("clientCode", "Código do cliente (papéis)", c => c.ClientCode, (c, v) => c.ClientCode = S(v)),
        new("creditLimit", "Limite de crédito", c => N(c.CreditLimit), (c, v) => c.CreditLimit = D(v)),
        new("ipiPercent", "IPI usual (%)", c => N(c.IpiPercent), (c, v) => c.IpiPercent = D(v)),
        new("icmsPercent", "ICMS usual (%)", c => N(c.IcmsPercent), (c, v) => c.IcmsPercent = D(v)),
        new("poPhrase", "Frase do pedido na NF", c => c.PoPhrase, (c, v) => c.PoPhrase = S(v)),
    ];

    private static readonly Spec<Supplier>[] SupplierSpecs =
    [
        new("name", "Nome", s => s.Name, (s, v) => s.Name = S(v) ?? s.Name),
        new("tradeName", "Nome fantasia", s => s.TradeName, (s, v) => s.TradeName = S(v)),
        new("groupCode", "Grupo", s => s.GroupCode, (s, v) => s.GroupCode = S(v)),
        new("legacyCode", "Código antigo", s => s.LegacyCode, (s, v) => s.LegacyCode = S(v)),
    ];

    private static readonly Spec<Product>[] ProductSpecs =
    [
        new("name", "Nome", p => p.Name, (p, v) => p.Name = S(v) ?? p.Name),
        new("ncm", "NCM", p => p.Ncm, (p, v) => p.Ncm = S(v) ?? p.Ncm),
        new("stockUnit", "Unidade de estoque", p => p.StockUnit, (p, v) => p.StockUnit = S(v) ?? p.StockUnit),
        new("diameterMm", "Diâmetro (mm)", p => N(p.DiameterMm), (p, v) => p.DiameterMm = D(v)),
        new("widthMm", "Largura (mm)", p => N(p.WidthMm), (p, v) => p.WidthMm = D(v)),
        new("heightMm", "Altura (mm)", p => N(p.HeightMm), (p, v) => p.HeightMm = D(v)),
        new("thicknessMm", "Parede (mm)", p => N(p.ThicknessMm), (p, v) => p.ThicknessMm = D(v)),
        new("lengthMm", "Comprimento (mm)", p => N(p.LengthMm), (p, v) => p.LengthMm = D(v)),
        new("netWeightKg", "Peso líquido (kg)", p => N(p.NetWeightKg), (p, v) => p.NetWeightKg = D(v)),
        new("lossPercent", "Perda (%)", p => N(p.LossPercent), (p, v) => p.LossPercent = D(v)),
        new("piecesPerPackage", "Peças por embalagem", p => N(p.PiecesPerPackage), (p, v) => p.PiecesPerPackage = I(v)),
        new("drawingRevision", "Revisão do desenho", p => p.DrawingRevision, (p, v) => p.DrawingRevision = S(v)),
        new("processRevision", "Revisão do processo", p => p.ProcessRevision, (p, v) => p.ProcessRevision = S(v)),
    ];

    private static CompareField Build<T>(Spec<T> spec, Dictionary<int, T> rows)
    {
        var values = rows.ToDictionary(r => r.Key, r => S(spec.Get(r.Value)));
        var differs = values.Values.Select(v => v?.ToUpperInvariant()).Distinct().Count() > 1;
        return new CompareField(spec.Key, spec.Label, values, differs);
    }

    private static Task<Dictionary<int, int>> CountAsync<T>(IQueryable<T> q, System.Linq.Expressions.Expression<Func<T, int>> key, IReadOnlyList<int> ids, CancellationToken ct)
        => q.GroupBy(key).Select(g => new { g.Key, N = g.Count() }).ToDictionaryAsync(x => x.Key, x => x.N, ct);

    public async Task<CompareOut?> CompareAsync(DuplicateKind kind, IReadOnlyList<int> ids, CancellationToken ct = default)
    {
        ids = ids.Distinct().ToList();
        if (ids.Count < 2) return null;
        switch (kind)
        {
            case DuplicateKind.Customer:
            {
                var rows = await db.Customers.AsNoTracking().Where(c => ids.Contains(c.Id)).ToDictionaryAsync(c => c.Id, ct);
                if (rows.Count != ids.Count) return null;
                var addr = await CountAsync(db.CustomerAddresses.Where(a => ids.Contains(a.CustomerId)), a => a.CustomerId, ids, ct);
                var quotes = await CountAsync(db.Quotes.Where(q => ids.Contains(q.CustomerId)), q => q.CustomerId, ids, ct);
                var orders = await CountAsync(db.SalesOrders.Where(o => ids.Contains(o.CustomerId)), o => o.CustomerId, ids, ct);
                var products = await CountAsync(db.Set<ProductCustomer>().Where(p => ids.Contains(p.CustomerId)), p => p.CustomerId, ids, ct);
                var records = ids.Select(i => new CompareRecord(i, rows[i].Name, rows[i].Active,
                    [new("Orçamentos", quotes.GetValueOrDefault(i)), new("Pedidos de venda", orders.GetValueOrDefault(i)), new("Produtos do cliente", products.GetValueOrDefault(i))], addr.GetValueOrDefault(i))).ToList();
                return new CompareOut(records, CustomerSpecs.Select(s => Build(s, rows)).ToList());
            }
            case DuplicateKind.Supplier:
            {
                var rows = await db.Suppliers.AsNoTracking().Where(s => ids.Contains(s.Id)).ToDictionaryAsync(s => s.Id, ct);
                if (rows.Count != ids.Count) return null;
                var addr = await CountAsync(db.SupplierAddresses.Where(a => ids.Contains(a.SupplierId)), a => a.SupplierId, ids, ct);
                var orders = await CountAsync(db.PurchaseOrders.Where(o => ids.Contains(o.SupplierId)), o => o.SupplierId, ids, ct);
                var records = ids.Select(i => new CompareRecord(i, rows[i].Name, rows[i].Active, [new("Pedidos de compra", orders.GetValueOrDefault(i))], addr.GetValueOrDefault(i))).ToList();
                return new CompareOut(records, SupplierSpecs.Select(s => Build(s, rows)).ToList());
            }
            default:
            {
                var rows = await db.Products.AsNoTracking().Where(p => ids.Contains(p.Id)).ToDictionaryAsync(p => p.Id, ct);
                if (rows.Count != ids.Count) return null;
                var lines = await CountAsync(db.SalesOrderLines.Where(l => ids.Contains(l.ProductId)), l => l.ProductId, ids, ct);
                var qlines = await CountAsync(db.QuoteLines.Where(l => ids.Contains(l.ProductId)), l => l.ProductId, ids, ct);
                var ofs = await CountAsync(db.ProductionOrders.Where(o => ids.Contains(o.ProductId)), o => o.ProductId, ids, ct);
                var records = ids.Select(i => new CompareRecord(i, $"{rows[i].Code} · {rows[i].Name}", !rows[i].Blocked,
                    [new("Linhas de orçamento", qlines.GetValueOrDefault(i)), new("Linhas de pedido", lines.GetValueOrDefault(i)), new("Ordens de produção", ofs.GetValueOrDefault(i))], 0)).ToList();
                return new CompareOut(records, ProductSpecs.Select(s => Build(s, rows)).ToList());
            }
        }
    }

    public enum ResolveStatus { Done, Invalid, NotFound, Conflict }

    public async Task<(ResolveStatus Status, ResolveOut? Result, string? Message)> ResolveAsync(DuplicateKind kind, ResolveIn input, string? user, CancellationToken ct = default)
    {
        var others = input.OtherIds.Distinct().Where(i => i != input.KeepId).ToList();
        if (others.Count == 0) return (ResolveStatus.Invalid, null, "Escolha ao menos um cadastro duplicado para desativar");
        var all = others.Append(input.KeepId).ToList();
        var fields = input.Fields ?? [];
        if (fields.Values.Any(v => !all.Contains(v))) return (ResolveStatus.Invalid, null, "A informação escolhida vem de um cadastro fora do grupo");

        int changed = 0, moved = 0;
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        try
        {
            switch (kind)
            {
                case DuplicateKind.Customer:
                {
                    var rows = await db.Customers.Where(c => all.Contains(c.Id)).ToDictionaryAsync(c => c.Id, ct);
                    if (rows.Count != all.Count) return (ResolveStatus.NotFound, null, null);
                    changed = Apply(CustomerSpecs, rows, input.KeepId, fields);
                    foreach (var o in others) rows[o].Active = false;
                    if (input.MoveAddresses)
                    {
                        var keepCodes = await db.CustomerAddresses.Where(a => a.CustomerId == input.KeepId).Select(a => a.LegacyCode).ToListAsync(ct);
                        foreach (var a in await db.CustomerAddresses.Where(a => others.Contains(a.CustomerId)).ToListAsync(ct))
                        {
                            if (a.LegacyCode is not null && keepCodes.Contains(a.LegacyCode)) a.LegacyCode = null;
                            a.CustomerId = input.KeepId;
                            moved++;
                        }
                    }
                    break;
                }
                case DuplicateKind.Supplier:
                {
                    var rows = await db.Suppliers.Where(s => all.Contains(s.Id)).ToDictionaryAsync(s => s.Id, ct);
                    if (rows.Count != all.Count) return (ResolveStatus.NotFound, null, null);
                    changed = Apply(SupplierSpecs, rows, input.KeepId, fields);
                    foreach (var o in others) rows[o].Active = false;
                    if (input.MoveAddresses)
                    {
                        var keepCodes = await db.SupplierAddresses.Where(a => a.SupplierId == input.KeepId).Select(a => a.LegacyCode).ToListAsync(ct);
                        foreach (var a in await db.SupplierAddresses.Where(a => others.Contains(a.SupplierId)).ToListAsync(ct))
                        {
                            if (a.LegacyCode is not null && keepCodes.Contains(a.LegacyCode)) a.LegacyCode = null;
                            a.SupplierId = input.KeepId;
                            moved++;
                        }
                    }
                    break;
                }
                default:
                {
                    var rows = await db.Products.Where(p => all.Contains(p.Id)).ToDictionaryAsync(p => p.Id, ct);
                    if (rows.Count != all.Count) return (ResolveStatus.NotFound, null, null);
                    changed = Apply(ProductSpecs, rows, input.KeepId, fields);
                    foreach (var o in others) rows[o].Blocked = true;
                    break;
                }
            }
            await db.SaveChangesAsync(ct);
            foreach (var o in others) await duplicates.DismissAsync(kind, input.KeepId, o, "Unificado: o cadastro duplicado foi desativado", user, ct);
            await tx.CommitAsync(ct);
        }
        catch (DbUpdateException e)
        {
            await tx.RollbackAsync(ct);
            return (ResolveStatus.Conflict, null, "Não foi possível unificar: " + (e.InnerException?.Message ?? e.Message));
        }
        return (ResolveStatus.Done, new ResolveOut(input.KeepId, changed, moved, others.Count), null);
    }

    private static int Apply<T>(Spec<T>[] specs, Dictionary<int, T> rows, int keepId, Dictionary<string, int> fields)
    {
        var changed = 0;
        foreach (var (key, source) in fields)
        {
            var spec = specs.FirstOrDefault(s => s.Key == key);
            if (spec is null || source == keepId) continue;
            var value = S(spec.Get(rows[source]));
            if (value == S(spec.Get(rows[keepId]))) continue;
            spec.Set(rows[keepId], value);
            changed++;
        }
        return changed;
    }
}
