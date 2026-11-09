using System.Text.Json;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Fiscal;

public sealed record BundleIssuer(string? CompanyName, string? TradeName, string? Cnpj, string? StateRegistration, int? TaxRegime, string? Street, string? Number, string? Complement, string? District, string? City,
    string? CityIbgeCode, string? Uf, string? ZipCode, string? Phone, int? NextNumber);

public sealed record BundleCarrier(string Name, string? Document, string? StateRegistration, string? Address, string? City, string? Uf);

public sealed record BundleTaxRule(string ProductCode, string CustomerCode, string Cfop, string? IcmsCst, decimal IcmsPercent, string? IpiCst, decimal IpiPercent, decimal? PisPercent, decimal? CofinsPercent);

public sealed record BundlePrice(string ProductCode, string CustomerCode, string Cfop, int Year, int Month, decimal UnitPrice);

public sealed record BundleCfop(string Code, string Description, bool Taxed, string IcmsCst, string IpiCst, string PisCst, string CofinsCst, decimal DefaultPisPercent, decimal DefaultCofinsPercent,
    string? IpiFramingCode, bool GeneratesInstallments);

/// <summary>The file built by <c>scripts/export-fiscal-data.ps1</c> from the legacy DBFs: everything the NF needs that MetaGest did not import with the registers.</summary>
public sealed record FiscalBundle(string? Source, BundleIssuer? Issuer, List<BundleCarrier>? Carriers, List<BundleTaxRule>? TaxRules, List<BundlePrice>? MonthlyPrices, List<BundleCfop>? Cfops);

/// <param name="Section">issuer, cfops, carriers, taxRules or monthlyPrices.</param>
/// <param name="Notes">Why rows were left out or what deserves a look.</param>
public sealed record FiscalImportSection(string Section, string Title, int Read, int Added, int Updated, int Unchanged, int Skipped, IReadOnlyList<string> Notes);

public sealed record FiscalImportResult(bool Applied, string? Source, IReadOnlyList<FiscalImportSection> Sections);

public sealed record FiscalDataSummary(bool IssuerFilled, int Cfops, int Carriers, int TaxRules, int MonthlyPrices, int NextNumber);

/// <summary>
/// Loads the fiscal data of the old system (issuer, missing CFOPs, carriers, tax rules by product x customer, monthly prices) from the JSON built by the export script.
/// Every call can be a preview (<c>apply = false</c>, nothing saved). Existing values are never wiped: an issuer field already filled is kept, the next NF number only goes up,
/// emission is never switched on, and rows that point to an unknown product, customer or CFOP are left out and counted.
/// </summary>
public sealed class FiscalDataImporter(EbtDbContext db)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>CFOPs created by this same run: not saved yet in a preview, but the rules and prices that use them must count.</summary>
    private readonly HashSet<string> newCfops = [];

    public async Task<FiscalDataSummary> SummaryAsync(CancellationToken ct)
    {
        var s = await db.FiscalSettings.AsNoTracking().FirstAsync(ct);
        return new FiscalDataSummary(!string.IsNullOrWhiteSpace(s.Cnpj) && !string.IsNullOrWhiteSpace(s.StateRegistration) && !string.IsNullOrWhiteSpace(s.CityIbgeCode), await db.Cfops.CountAsync(ct), await db.FiscalCarriers.CountAsync(ct),
            await db.TaxRules.CountAsync(ct), await db.MonthlyPrices.CountAsync(ct), s.NextNumber);
    }

    public async Task<FiscalImportResult> ImportAsync(byte[] file, bool apply, CancellationToken ct)
    {
        FiscalBundle? bundle;
        try { bundle = JsonSerializer.Deserialize<FiscalBundle>(file, Json); }
        catch (JsonException) { throw FiscalException.Invalid("file", "O arquivo não é o JSON gerado por scripts/export-fiscal-data.ps1"); }
        if (bundle is null) throw FiscalException.Invalid("file", "Arquivo vazio");

        var sections = new List<FiscalImportSection>
        {
            await IssuerAsync(bundle.Issuer, ct),
            await CfopsAsync(bundle.Cfops ?? [], ct),
            await CarriersAsync(bundle.Carriers ?? [], ct),
            await TaxRulesAsync(bundle.TaxRules ?? [], ct),
            await PricesAsync(bundle.MonthlyPrices ?? [], ct)
        };
        if (apply) await db.SaveChangesAsync(ct);
        else db.ChangeTracker.Clear();
        return new FiscalImportResult(apply, bundle.Source, sections);
    }

    private async Task<FiscalImportSection> IssuerAsync(BundleIssuer? i, CancellationToken ct)
    {
        var notes = new List<string>();
        if (i is null) return new("issuer", "Dados do emitente", 0, 0, 0, 0, 0, ["O arquivo não traz os dados do emitente."]);
        var s = await db.FiscalSettings.FirstAsync(ct);
        var changed = 0;
        void Fill(string label, string? current, string? incoming, Action<string> set)
        {
            if (string.IsNullOrWhiteSpace(incoming)) return;
            if (string.IsNullOrWhiteSpace(current)) { set(incoming.Trim()); changed++; }
            else if (!string.Equals(Digits(current), Digits(incoming), StringComparison.Ordinal) && !string.Equals(current.Trim(), incoming.Trim(), StringComparison.OrdinalIgnoreCase)) notes.Add($"{label} já preenchido ({current.Trim()}) e diferente do arquivo ({incoming.Trim()}): mantido o atual.");
        }
        Fill("Razão social", s.CompanyName, i.CompanyName, v => s.CompanyName = v);
        Fill("Nome fantasia", s.TradeName, i.TradeName, v => s.TradeName = v);
        Fill("CNPJ", s.Cnpj, Digits(i.Cnpj), v => s.Cnpj = v);
        Fill("Inscrição estadual", s.StateRegistration, Digits(i.StateRegistration), v => s.StateRegistration = v);
        Fill("Rua", s.Street, i.Street, v => s.Street = v);
        Fill("Número", s.Number, i.Number, v => s.Number = v);
        Fill("Complemento", s.Complement, i.Complement, v => s.Complement = v);
        Fill("Bairro", s.District, i.District, v => s.District = v);
        Fill("Cidade", s.City, i.City, v => s.City = v);
        Fill("Código IBGE", s.CityIbgeCode, Digits(i.CityIbgeCode), v => s.CityIbgeCode = v);
        Fill("CEP", s.ZipCode, Digits(i.ZipCode), v => s.ZipCode = v);
        Fill("Telefone", s.Phone, Digits(i.Phone), v => s.Phone = v);
        if (!string.IsNullOrWhiteSpace(i.Uf) && NfeKey.UfCodes.ContainsKey(i.Uf.Trim().ToUpperInvariant()) && !string.Equals(s.Uf, i.Uf.Trim(), StringComparison.OrdinalIgnoreCase)) { s.Uf = i.Uf.Trim().ToUpperInvariant(); changed++; }
        if (i.TaxRegime is >= 1 and <= 3 && s.TaxRegime != i.TaxRegime) { notes.Add($"Regime tributário do arquivo ({i.TaxRegime}) difere do atual ({s.TaxRegime}): mantido o atual."); }
        if (i.NextNumber is { } next)
        {
            var maxIssued = await db.FiscalDocuments.Where(d => d.Series == s.Series).Select(d => (int?)d.Number).MaxAsync(ct) ?? 0;
            if (next > s.NextNumber && next > maxIssued) { s.NextNumber = next; changed++; notes.Add($"Próximo número da NF subiu para {next}."); }
            else if (next < s.NextNumber) notes.Add($"Próximo número do sistema antigo ({next}) é menor que o atual ({s.NextNumber}): mantido o atual.");
        }
        if (!s.Enabled) notes.Add("A emissão continua desligada: ligue em Configurações > Fiscal quando o certificado A1 estiver pronto.");
        return new("issuer", "Dados do emitente", 1, 0, changed > 0 ? 1 : 0, changed > 0 ? 0 : 1, 0, notes);
    }

    private async Task<FiscalImportSection> CfopsAsync(List<BundleCfop> rows, CancellationToken ct)
    {
        var existing = await db.Cfops.Select(c => c.Code).ToListAsync(ct);
        int added = 0, unchanged = 0, skipped = 0;
        var notes = new List<string>();
        foreach (var r in rows)
        {
            var code = new string((r.Code ?? "").Where(char.IsDigit).ToArray());
            if (code.Length != 4) { skipped++; continue; }
            if (existing.Contains(code)) { unchanged++; continue; }
            // Only sale CFOPs (5xxx/6xxx) come in; the type of the operation is decided here, not by the file.
            var kind = code[0] is '5' or '6' ? FiscalKind.Sale : (FiscalKind?)null;
            if (kind is null) { skipped++; continue; }
            db.Cfops.Add(new Cfop
            {
                Code = code, Description = r.Description, Kind = kind.Value, Taxed = r.Taxed, IcmsCst = r.IcmsCst, IpiCst = r.IpiCst, PisCst = r.PisCst, CofinsCst = r.CofinsCst, DefaultPisPercent = r.DefaultPisPercent,
                DefaultCofinsPercent = r.DefaultCofinsPercent, IpiFramingCode = r.IpiFramingCode ?? "999", GeneratesInstallments = r.GeneratesInstallments
            });
            existing.Add(code);
            newCfops.Add(code);
            added++;
            notes.Add($"CFOP {code} criado (venda): confira os CSTs com o contador.");
        }
        return new("cfops", "CFOPs que faltavam", rows.Count, added, 0, unchanged, skipped, notes);
    }

    private async Task<FiscalImportSection> CarriersAsync(List<BundleCarrier> rows, CancellationToken ct)
    {
        var existing = await db.FiscalCarriers.ToListAsync(ct);
        int added = 0, updated = 0, unchanged = 0, skipped = 0;
        foreach (var r in rows)
        {
            if (string.IsNullOrWhiteSpace(r.Name)) { skipped++; continue; }
            var name = r.Name.Trim();
            var doc = Digits(r.Document);
            var carrier = existing.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));
            if (carrier is null)
            {
                carrier = new FiscalCarrier { Name = name, Document = doc, StateRegistration = Digits(r.StateRegistration), Address = Clean(r.Address), City = Clean(r.City), Uf = Clean(r.Uf)?.ToUpperInvariant() };
                db.FiscalCarriers.Add(carrier);
                existing.Add(carrier);
                added++;
                continue;
            }
            var before = (carrier.Document, carrier.StateRegistration, carrier.Address, carrier.City, carrier.Uf);
            carrier.Document ??= doc;
            carrier.StateRegistration ??= Digits(r.StateRegistration);
            carrier.Address ??= Clean(r.Address);
            carrier.City ??= Clean(r.City);
            carrier.Uf ??= Clean(r.Uf)?.ToUpperInvariant();
            if (before == (carrier.Document, carrier.StateRegistration, carrier.Address, carrier.City, carrier.Uf)) unchanged++; else updated++;
        }
        return new("carriers", "Transportadoras", rows.Count, added, updated, unchanged, skipped, []);
    }

    private async Task<FiscalImportSection> TaxRulesAsync(List<BundleTaxRule> rows, CancellationToken ct)
    {
        var products = await db.Products.AsNoTracking().Select(p => new { p.Code, p.Id }).ToDictionaryAsync(p => p.Code, p => p.Id, ct);
        var customers = await db.Customers.AsNoTracking().Where(c => c.LegacyCode != null).Select(c => new { c.LegacyCode, c.Id }).ToListAsync(ct);
        var customerIds = customers.GroupBy(c => c.LegacyCode!.Trim()).ToDictionary(g => g.Key, g => g.First().Id);
        var cfops = (await db.Cfops.AsNoTracking().Select(c => c.Code).ToListAsync(ct)).Concat(newCfops).ToHashSet();
        var existing = await db.TaxRules.ToListAsync(ct);
        int added = 0, updated = 0, unchanged = 0;
        var skipped = new Dictionary<string, int>();
        void Skip(string why) => skipped[why] = skipped.GetValueOrDefault(why) + 1;
        var seen = new HashSet<(int, int, string)>();
        foreach (var r in rows)
        {
            if (!products.TryGetValue((r.ProductCode ?? "").Trim(), out var pid)) { Skip("produto não cadastrado"); continue; }
            if (!customerIds.TryGetValue((r.CustomerCode ?? "").Trim(), out var cid)) { Skip("cliente não cadastrado"); continue; }
            var cfop = new string((r.Cfop ?? "").Where(char.IsDigit).Take(4).ToArray());
            if (!cfops.Contains(cfop)) { Skip($"CFOP {(cfop.Length == 0 ? "?" : cfop)} não cadastrado"); continue; }
            if (!seen.Add((pid, cid, cfop))) { Skip("repetida no arquivo"); continue; }
            var rule = existing.FirstOrDefault(x => x.ProductId == pid && x.CustomerId == cid && x.CfopCode == cfop);
            if (rule is null)
            {
                db.TaxRules.Add(new TaxRule { ProductId = pid, CustomerId = cid, CfopCode = cfop, IcmsCst = r.IcmsCst, IcmsPercent = r.IcmsPercent, IpiCst = r.IpiCst, IpiPercent = r.IpiPercent, PisPercent = r.PisPercent, CofinsPercent = r.CofinsPercent });
                added++;
            }
            else if (rule.IcmsCst == r.IcmsCst && rule.IcmsPercent == r.IcmsPercent && rule.IpiCst == r.IpiCst && rule.IpiPercent == r.IpiPercent && rule.PisPercent == r.PisPercent && rule.CofinsPercent == r.CofinsPercent) unchanged++;
            else
            {
                rule.IcmsCst = r.IcmsCst; rule.IcmsPercent = r.IcmsPercent; rule.IpiCst = r.IpiCst; rule.IpiPercent = r.IpiPercent; rule.PisPercent = r.PisPercent; rule.CofinsPercent = r.CofinsPercent;
                updated++;
            }
        }
        var notes = skipped.Select(k => $"{k.Value} ignoradas: {k.Key}").ToList();
        return new("taxRules", "Impostos por produto e cliente", rows.Count, added, updated, unchanged, skipped.Values.Sum(), notes);
    }

    private async Task<FiscalImportSection> PricesAsync(List<BundlePrice> rows, CancellationToken ct)
    {
        var products = await db.Products.AsNoTracking().Select(p => new { p.Code, p.Id }).ToDictionaryAsync(p => p.Code, p => p.Id, ct);
        var customers = await db.Customers.AsNoTracking().Where(c => c.LegacyCode != null).Select(c => new { c.LegacyCode, c.Id }).ToListAsync(ct);
        var customerIds = customers.GroupBy(c => c.LegacyCode!.Trim()).ToDictionary(g => g.Key, g => g.First().Id);
        var cfops = (await db.Cfops.AsNoTracking().Select(c => c.Code).ToListAsync(ct)).Concat(newCfops).ToHashSet();
        var existing = (await db.MonthlyPrices.ToListAsync(ct)).ToDictionary(p => (p.ProductId, p.CustomerId, p.CfopCode, p.Year, p.Month));
        int added = 0, updated = 0, unchanged = 0;
        var skipped = new Dictionary<string, int>();
        void Skip(string why) => skipped[why] = skipped.GetValueOrDefault(why) + 1;
        foreach (var r in rows)
        {
            if (!products.TryGetValue((r.ProductCode ?? "").Trim(), out var pid)) { Skip("produto não cadastrado"); continue; }
            if (!customerIds.TryGetValue((r.CustomerCode ?? "").Trim(), out var cid)) { Skip("cliente não cadastrado"); continue; }
            var cfop = new string((r.Cfop ?? "").Where(char.IsDigit).Take(4).ToArray());
            if (!cfops.Contains(cfop)) { Skip($"CFOP {(cfop.Length == 0 ? "?" : cfop)} não cadastrado"); continue; }
            if (r.UnitPrice <= 0 || r.Month is < 1 or > 12 || r.Year < 2000) { Skip("preço ou mês inválido"); continue; }
            var key = (pid, cid, cfop, r.Year, r.Month);
            if (!existing.TryGetValue(key, out var row))
            {
                row = new MonthlyPrice { ProductId = pid, CustomerId = cid, CfopCode = cfop, Year = r.Year, Month = r.Month, UnitPrice = r.UnitPrice };
                db.MonthlyPrices.Add(row);
                existing[key] = row;
                added++;
            }
            else if (row.UnitPrice == r.UnitPrice) unchanged++;
            else { row.UnitPrice = r.UnitPrice; updated++; }
        }
        var notes = skipped.Select(k => $"{k.Value} ignorados: {k.Key}").ToList();
        return new("monthlyPrices", "Preços mensais da NF", rows.Count, added, updated, unchanged, skipped.Values.Sum(), notes);
    }

    private static string? Digits(string? s) => s is null ? null : (string.Concat(s.Where(char.IsDigit)) is { Length: > 0 } d ? d : null);
    private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
