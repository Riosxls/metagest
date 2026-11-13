using System.Text.Json;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Fiscal;

public sealed record BundleIssuer(string? CompanyName, string? TradeName, string? Cnpj, string? StateRegistration, int? TaxRegime, string? Street, string? Number, string? Complement, string? District, string? City,
    string? CityIbgeCode, string? Uf, string? ZipCode, string? Phone, int? NextNumber);

public sealed record BundleCarrier(string Name, string? Document, string? StateRegistration, string? Address, string? City, string? Uf);

public sealed record BundleTaxRule(string ProductCode, string CustomerCode, string Cfop, string? IcmsCst, decimal IcmsPercent, string? IpiCst, decimal IpiPercent, decimal? PisPercent, decimal? CofinsPercent);

public sealed record BundleUfRate(string Uf, decimal Percent);

/// <summary>A customer of the old system the file refers to by <c>customerCode</c>, with the CNPJ/CPF of its addresses: how another company's codes are matched to MetaGest customers.</summary>
public sealed record BundleCustomer(string Code, string? Name, List<string>? Documents);

/// <summary>A customer of the old register by CNPJ/CPF: its razão social and each address with the parts the NF needs (district, IBGE code...).</summary>
public sealed record BundleCustomerData(string Document, string? LegalName, string? TradeName, List<BundleAddressData>? Addresses);

public sealed record BundleAddressData(string? Street, string? Number, string? District, string? City, string? Uf, string? Zip, string? Ibge, string? StateRegistration, string? Phone);

public sealed record BundleCity(string City, string Uf, string Ibge);

public sealed record BundleProductNcm(string Code, string Ncm);

public sealed record BundlePrice(string ProductCode, string CustomerCode, string Cfop, int Year, int Month, decimal UnitPrice);

public sealed record BundleCfop(string Code, string Description, bool Taxed, string IcmsCst, string IpiCst, string PisCst, string CofinsCst, decimal DefaultPisPercent, decimal DefaultCofinsPercent,
    string? IpiFramingCode, bool GeneratesInstallments);

/// <summary>The file built by <c>scripts/export-fiscal-data.ps1</c> from the legacy DBFs: everything the NF needs that MetaGest did not import with the registers.</summary>
public sealed record FiscalBundle(string? Source, BundleIssuer? Issuer, List<BundleCarrier>? Carriers, List<BundleTaxRule>? TaxRules, List<BundlePrice>? MonthlyPrices, List<BundleCfop>? Cfops, List<BundleUfRate>? UfRates = null, List<BundleCustomer>? Customers = null,
    List<BundleCustomerData>? CustomerData = null, List<BundleCity>? Cities = null, List<BundleProductNcm>? ProductNcms = null);

/// <param name="Section">issuer, cfops, carriers, taxRules or monthlyPrices.</param>
/// <param name="Notes">Why rows were left out or what deserves a look.</param>
public sealed record FiscalImportSection(string Section, string Title, int Read, int Added, int Updated, int Unchanged, int Skipped, IReadOnlyList<string> Notes);

public sealed record FiscalImportResult(bool Applied, string? Source, IReadOnlyList<FiscalImportSection> Sections);

/// <param name="Company">The issuer the figures about the issuer (filled, next number) belong to.</param>
public sealed record FiscalDataSummary(bool IssuerFilled, int Cfops, int Carriers, int TaxRules, int MonthlyPrices, int NextNumber, string Company = "EBT");

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

    public async Task<FiscalDataSummary> SummaryAsync(string? company, CancellationToken ct)
    {
        var code = FiscalCompany.Parse(company) ?? throw FiscalException.Invalid("company", "EBT ou BST");
        var s = await db.FiscalSettings.AsNoTracking().FirstAsync(x => x.Company == code, ct);
        return new FiscalDataSummary(!string.IsNullOrWhiteSpace(s.Cnpj) && !string.IsNullOrWhiteSpace(s.StateRegistration) && !string.IsNullOrWhiteSpace(s.CityIbgeCode), await db.Cfops.CountAsync(ct), await db.FiscalCarriers.CountAsync(ct),
            await db.TaxRules.CountAsync(ct), await db.MonthlyPrices.CountAsync(ct), s.NextNumber, code);
    }

    public async Task<FiscalImportResult> ImportAsync(byte[] file, bool apply, CancellationToken ct)
    {
        FiscalBundle? bundle;
        try { bundle = JsonSerializer.Deserialize<FiscalBundle>(file, Json); }
        catch (JsonException) { throw FiscalException.Invalid("file", "O arquivo não é o JSON gerado por scripts/export-fiscal-data.ps1"); }
        if (bundle is null) throw FiscalException.Invalid("file", "Arquivo vazio");

        var company = FiscalCompany.Parse(bundle.Source) ?? throw FiscalException.Invalid("file", "O campo \"source\" do arquivo deve ser EBT ou BST");
        // EBT's codes are the legacy codes already on the customers; another company's codes are matched by CNPJ/CPF through the customers listed in its file.
        var map = company == FiscalCompany.Ebt ? null : await MapCustomersAsync(bundle.Customers ?? [], ct);
        var sections = new List<FiscalImportSection>
        {
            await IssuerAsync(bundle.Issuer, company, ct),
            await CfopsAsync(bundle.Cfops ?? [], ct),
            await UfRatesAsync(bundle.UfRates ?? [], ct),
            await CarriersAsync(bundle.Carriers ?? [], ct),
            await TaxRulesAsync(bundle.TaxRules ?? [], map, ct),
            await PricesAsync(bundle.MonthlyPrices ?? [], map, ct),
            await CustomerRegisterAsync(bundle.CustomerData ?? [], bundle.Cities ?? [], ct),
            await ProductNcmAsync(bundle.ProductNcms ?? [], company, ct)
        };
        if (apply) await db.SaveChangesAsync(ct);
        else db.ChangeTracker.Clear();
        return new FiscalImportResult(apply, bundle.Source, sections);
    }

    private async Task<FiscalImportSection> IssuerAsync(BundleIssuer? i, string company, CancellationToken ct)
    {
        var notes = new List<string>();
        if (i is null) return new("issuer", "Dados do emitente", 0, 0, 0, 0, 0, ["O arquivo não traz os dados do emitente."]);
        var s = await db.FiscalSettings.FirstAsync(x => x.Company == company, ct);
        notes.Add($"Emitente: {company}.");
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
            var maxIssued = await db.FiscalDocuments.Where(d => d.IssuerId == s.Id && d.Series == s.Series).Select(d => (int?)d.Number).MaxAsync(ct) ?? 0;
            if (next > s.NextNumber && next > maxIssued) { s.NextNumber = next; changed++; notes.Add($"Próximo número da NF subiu para {next}."); }
            else if (next < s.NextNumber) notes.Add($"Próximo número do sistema antigo ({next}) é menor que o atual ({s.NextNumber}): mantido o atual.");
        }
        if (!s.Enabled) notes.Add("A emissão continua desligada: ligue em Fiscal > Emitente e emissão quando o certificado A1 estiver pronto.");
        return new("issuer", "Dados do emitente", 1, 0, changed > 0 ? 1 : 0, changed > 0 ? 0 : 1, 0, notes);
    }

    /// <summary>What matching another company's customer codes found: the map from code to MetaGest customer, and why the rest was left out.</summary>
    /// <summary>Digits of a text, empty (never null) when there are none.</summary>
    private static string Dg(string? s) => Digits(s) ?? "";

    private static string CityKey(string? s)
    {
        var d = (s ?? "").Normalize(System.Text.NormalizationForm.FormD).Where(c => System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) != System.Globalization.UnicodeCategory.NonSpacingMark);
        return string.Concat(d.Where(char.IsLetterOrDigit)).ToUpperInvariant();
    }

    /// <summary>
    /// Completes the customers' register from the old one, by CNPJ/CPF: razão social (the name the NF must carry), and in each address the district, CEP, IE, number and IBGE code it still lacks.
    /// An address is paired by CEP, or as the only one on both sides. Addresses that still have no IBGE code get it from the city (name + UF) when the old system knows that city.
    /// Nothing already filled is changed.
    /// </summary>
    private async Task<FiscalImportSection> CustomerRegisterAsync(List<BundleCustomerData> rows, List<BundleCity> cities, CancellationToken ct)
    {
        var notes = new List<string>();
        if (rows.Count == 0 && cities.Count == 0) return new("customerRegister", "Cadastro dos clientes (razão social, bairro, IBGE)", 0, 0, 0, 0, 0, ["O arquivo não traz o cadastro dos clientes: gere-o de novo com o script atual."]);
        var customers = await db.Customers.Include(c => c.Addresses).Where(c => c.Source != DataSource.Test).ToListAsync(ct);
        var byDoc = new Dictionary<string, List<Customer>>();
        foreach (var c in customers)
            foreach (var d in c.Addresses.Select(a => Dg(a.Document)).Append(Dg(c.Document)).Where(d => d.Length is 11 or 14).Distinct())
                (byDoc.TryGetValue(d, out var l) ? l : byDoc[d] = []).Add(c);
        int updated = 0, unchanged = 0, skipped = 0, names = 0, filled = 0;
        var touched = new HashSet<int>();
        foreach (var row in rows)
        {
            var doc = Dg(row.Document);
            if (!byDoc.TryGetValue(doc, out var found) || found.Distinct().Count() != 1) { skipped++; continue; }
            var c = found[0];
            var changed = false;
            if (string.IsNullOrWhiteSpace(c.LegalName) && !string.IsNullOrWhiteSpace(row.LegalName)) { c.LegalName = row.LegalName.Trim(); names++; changed = true; }
            var legacy = (row.Addresses ?? []).ToList();
            foreach (var a in c.Addresses)
            {
                var zip = Dg(a.ZipCode);
                var pair = legacy.FirstOrDefault(x => zip.Length == 8 && Dg(x.Zip) == zip) ?? (c.Addresses.Count == 1 && legacy.Count == 1 ? legacy[0] : null);
                if (pair is null) continue;
                if (Dg(a.CityIbgeCode).Length != 7 && Dg(pair.Ibge).Length == 7) { a.CityIbgeCode = Dg(pair.Ibge); filled++; changed = true; }
                if (string.IsNullOrWhiteSpace(a.District) && !string.IsNullOrWhiteSpace(pair.District)) { a.District = pair.District.Trim(); changed = true; }
                if (Dg(a.ZipCode).Length != 8 && Dg(pair.Zip).Length == 8) { a.ZipCode = Dg(pair.Zip); changed = true; }
                if (string.IsNullOrWhiteSpace(a.Number) && !string.IsNullOrWhiteSpace(pair.Number)) { a.Number = pair.Number.Trim(); changed = true; }
                if (string.IsNullOrWhiteSpace(a.StateRegistration) && !string.IsNullOrWhiteSpace(pair.StateRegistration)) { a.StateRegistration = Dg(pair.StateRegistration); changed = true; }
            }
            if (changed) { updated++; touched.Add(c.Id); } else unchanged++;
        }
        // IBGE by city name for what is still without a code (also customers that are not in the old register)
        var byCity = cities.Where(x => Dg(x.Ibge).Length == 7).GroupBy(x => (CityKey(x.City), x.Uf.ToUpperInvariant())).ToDictionary(g => g.Key, g => Dg(g.First().Ibge));
        int byName = 0;
        foreach (var a in customers.SelectMany(c => c.Addresses))
            if (Dg(a.CityIbgeCode).Length != 7 && byCity.TryGetValue((CityKey(a.City), (a.Uf ?? "").ToUpperInvariant()), out var ibge)) { a.CityIbgeCode = ibge; byName++; }
        notes.Add($"{names} razões sociais preenchidas, {filled} códigos IBGE pelo cadastro antigo e {byName} pelo nome da cidade.");
        if (skipped > 0) notes.Add($"{skipped} clientes do arquivo sem correspondente único pelo CNPJ/CPF (não cadastrados aqui ou repetidos).");
        return new("customerRegister", "Cadastro dos clientes (razão social, bairro, IBGE)", rows.Count, 0, updated + (byName > 0 ? 1 : 0), unchanged, skipped, notes);
    }

    /// <summary>
    /// The NCM of each product as the old register of this company holds it. EBT: fills a product that has none. BST (and any other company): where it differs from the product's NCM, it is kept as that
    /// company's own NCM (<c>product_company_ncm</c>), so the same tube goes out with 7306.30.90 on a BST NF and 7306.30.00 on an EBT one.
    /// </summary>
    private async Task<FiscalImportSection> ProductNcmAsync(List<BundleProductNcm> rows, string company, CancellationToken ct)
    {
        if (rows.Count == 0) return new("productNcm", "NCM dos produtos", 0, 0, 0, 0, 0, ["O arquivo não traz o NCM dos produtos: gere-o de novo com o script atual."]);
        var products = await db.Products.ToDictionaryAsync(p => p.Code, ct);
        var own = await db.ProductCompanyNcms.Where(x => x.Company == company).ToDictionaryAsync(x => x.ProductId, ct);
        int added = 0, updated = 0, unchanged = 0, skipped = 0, differs = 0;
        foreach (var row in rows)
        {
            var ncm = Dg(row.Ncm);
            if (ncm.Length != 8 || !products.TryGetValue(row.Code.Trim(), out var p)) { skipped++; continue; }
            if (company == FiscalCompany.Ebt)
            {
                if (Dg(p.Ncm).Length != 8) { p.Ncm = ncm; updated++; } else { unchanged++; if (Dg(p.Ncm) != ncm) differs++; }
                continue;
            }
            if (Dg(p.Ncm) == ncm) { unchanged++; if (own.Remove(p.Id, out var stale)) db.ProductCompanyNcms.Remove(stale); continue; }
            differs++;
            if (own.TryGetValue(p.Id, out var cur)) { if (cur.Ncm == ncm) unchanged++; else { cur.Ncm = ncm; updated++; } }
            else { var n = new ProductCompanyNcm { ProductId = p.Id, Company = company, Ncm = ncm }; db.ProductCompanyNcms.Add(n); own[p.Id] = n; added++; }
        }
        return new("productNcm", "NCM dos produtos", rows.Count, added, updated, unchanged, skipped, [$"{differs} produtos com NCM diferente do cadastro" + (company == FiscalCompany.Ebt ? " (mantido o do cadastro)." : $": guardados como NCM próprio da {company}.")]);
    }

    private sealed record CustomerMap(Dictionary<string, int> Ids, int NoDocument, int NotFound, int Ambiguous, int InFile);

    /// <summary>
    /// Tax rules and monthly prices point to customers by the legacy customer code. The BST system numbers its customers on its own, so its codes cannot be looked up in
    /// <c>customers.legacy_code</c> (the EBT codes): the file lists each customer with the CNPJ/CPF of its addresses, and a code is mapped only when exactly one MetaGest customer
    /// has one of those documents on an address. A customer without document, without a match or with several matches is left out and counted.
    /// </summary>
    private async Task<CustomerMap> MapCustomersAsync(List<BundleCustomer> list, CancellationToken ct)
    {
        var byDocument = (await db.CustomerAddresses.AsNoTracking().Where(a => a.Document.Length == 11 || a.Document.Length == 14).Select(a => new { a.Document, a.CustomerId }).ToListAsync(ct))
            .GroupBy(a => a.Document).ToDictionary(g => g.Key, g => g.Select(x => x.CustomerId).Distinct().ToList());
        var ids = new Dictionary<string, int>();
        int noDoc = 0, notFound = 0, ambiguous = 0;
        foreach (var c in list)
        {
            var docs = (c.Documents ?? []).Select(Digits).Where(d => d is { Length: 11 or 14 }).Distinct().ToList();
            if (docs.Count == 0) { noDoc++; continue; }
            var found = docs.SelectMany(d => byDocument.GetValueOrDefault(d!) ?? []).Distinct().ToList();
            if (found.Count == 0) notFound++;
            else if (found.Count > 1) ambiguous++;
            else ids[(c.Code ?? "").Trim()] = found[0];
        }
        return new CustomerMap(ids, noDoc, notFound, ambiguous, list.Count);
    }

    private static string MapNote(CustomerMap map) =>
        $"Clientes do arquivo ligados pelo CNPJ/CPF: {map.Ids.Count} de {map.InFile}" + (map.NotFound + map.NoDocument + map.Ambiguous == 0 ? "." : $" ({map.NotFound} sem cadastro, {map.NoDocument} sem documento, {map.Ambiguous} com mais de um cadastro).");

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

    private async Task<FiscalImportSection> UfRatesAsync(List<BundleUfRate> rows, CancellationToken ct)
    {
        var existing = await db.IcmsUfRates.ToListAsync(ct);
        int added = 0, updated = 0, unchanged = 0, skipped = 0;
        foreach (var r in rows)
        {
            var uf = (r.Uf ?? "").Trim().ToUpperInvariant();
            if (!NfeKey.UfCodes.ContainsKey(uf) || r.Percent is <= 0 or > 100) { skipped++; continue; }
            var row = existing.FirstOrDefault(x => x.Uf == uf);
            if (row is null) { row = new IcmsUfRate { Uf = uf, Percent = r.Percent }; db.IcmsUfRates.Add(row); existing.Add(row); added++; }
            else if (row.Percent == r.Percent) unchanged++;
            else { row.Percent = r.Percent; updated++; }
        }
        return new("ufRates", "ICMS padrão por estado", rows.Count, added, updated, unchanged, skipped, ["Usado quando não há regra de imposto nem alíquota no pedido. Confirme as alíquotas com o contador."]);
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

    private async Task<FiscalImportSection> TaxRulesAsync(List<BundleTaxRule> rows, CustomerMap? map, CancellationToken ct)
    {
        var products = await db.Products.AsNoTracking().Select(p => new { p.Code, p.Id }).ToDictionaryAsync(p => p.Code, p => p.Id, ct);
        var customerIds = map?.Ids ?? await LegacyCustomerIdsAsync(ct);
        // Rules and prices are shared by both companies: a file of the other company only fills what is missing and never rewrites a value that is already there.
        var gapsOnly = map is not null;
        var kept = 0;
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
            else if (gapsOnly) kept++;
            else
            {
                rule.IcmsCst = r.IcmsCst; rule.IcmsPercent = r.IcmsPercent; rule.IpiCst = r.IpiCst; rule.IpiPercent = r.IpiPercent; rule.PisPercent = r.PisPercent; rule.CofinsPercent = r.CofinsPercent;
                updated++;
            }
        }
        var notes = skipped.Select(k => $"{k.Value} ignoradas: {k.Key}").ToList();
        if (map is not null) notes.Insert(0, MapNote(map));
        if (kept > 0) notes.Add($"{kept} já existem com outros valores (do EBT): mantidos como estão.");
        return new("taxRules", "Impostos por produto e cliente", rows.Count, added, updated, unchanged, skipped.Values.Sum(), notes);
    }

    private async Task<FiscalImportSection> PricesAsync(List<BundlePrice> rows, CustomerMap? map, CancellationToken ct)
    {
        var products = await db.Products.AsNoTracking().Select(p => new { p.Code, p.Id }).ToDictionaryAsync(p => p.Code, p => p.Id, ct);
        var customerIds = map?.Ids ?? await LegacyCustomerIdsAsync(ct);
        var gapsOnly = map is not null;
        var kept = 0;
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
            else if (gapsOnly) kept++;
            else { row.UnitPrice = r.UnitPrice; updated++; }
        }
        var notes = skipped.Select(k => $"{k.Value} ignorados: {k.Key}").ToList();
        if (kept > 0) notes.Add($"{kept} já existem com outro preço (do EBT): mantidos como estão.");
        return new("monthlyPrices", "Preços mensais da NF", rows.Count, added, updated, unchanged, skipped.Values.Sum(), notes);
    }

    private async Task<Dictionary<string, int>> LegacyCustomerIdsAsync(CancellationToken ct)
    {
        var customers = await db.Customers.AsNoTracking().Where(c => c.LegacyCode != null).Select(c => new { c.LegacyCode, c.Id }).ToListAsync(ct);
        return customers.GroupBy(c => c.LegacyCode!.Trim()).ToDictionary(g => g.Key, g => g.First().Id);
    }

    private static string? Digits(string? s) => s is null ? null : (string.Concat(s.Where(char.IsDigit)) is { Length: > 0 } d ? d : null);
    private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
