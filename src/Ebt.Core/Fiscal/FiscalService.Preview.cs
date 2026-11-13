using Ebt.Core.Sales;
using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Fiscal;

/// <summary>Something that would stop (Blocking) or only deserves a look before the NF of an order is emitted. <paramref name="Fix"/> says where to fix it.</summary>
public sealed record NfProblem(string Area, string Message, string Fix, bool Blocking = true);

/// <summary>A customer whose register would keep an NF from being issued: which address and what it lacks. OpenOrders = orders not yet shipped, to say where it hurts first.</summary>
public sealed record CustomerFiscalProblem(int CustomerId, string Name, int OpenOrders, IReadOnlyList<CustomerAddressProblem> Addresses);

public sealed record CustomerAddressProblem(int AddressId, string Label, IReadOnlyList<string> Gaps);

/// <summary>A party of the NF preview: the address joined for reading, and its parts for the printed paper.</summary>
public sealed record NfPreviewParty(string Name, string? Document, string? StateRegistration, string? Address, string? City, string? Uf, string? ZipCode, string? CityIbgeCode, string? Street = null, string? Number = null, string? District = null, string? Phone = null);

public sealed record NfPreviewLine(int Sequence, string Code, string Description, string? Ncm, string Unit, decimal Quantity, decimal UnitPrice, decimal Total, string PriceSource,
    string IcmsCst, decimal IcmsPercent, decimal IcmsValue, string IpiCst, decimal IpiPercent, decimal IpiValue, decimal PisValue, decimal CofinsValue, string TaxSource);

/// <summary>One line of the order as the preview sees it: what was ordered, what is still to ship and the quantity this NF uses (0 = left out of this NF).</summary>
public sealed record NfPreviewOrderLine(int OrderLineId, int Sequence, string Code, string Description, string Unit, decimal Ordered, decimal Remaining, decimal Quantity);

public sealed record NfPreviewInstallment(int Sequence, DateOnly DueDate, decimal Amount);

public sealed record NfPreviewTransport(string Mode, string? Carrier, decimal? NetWeightKg, decimal? GrossWeightKg = null, int Packages = 0, string Species = "VOLUME", string? VehiclePlate = null, int FreightMode = 0, string? CarrierDocument = null, string? CarrierIe = null, string? CarrierAddress = null, string? CarrierCity = null, string? CarrierUf = null);

/// <summary>What the person typed in "Saída da carga" that changes the NF: the preview follows it live (empty = the default).</summary>
public sealed record PreviewOverrides(string? Cfop = null, decimal? Freight = null, string? Carrier = null, string? VehiclePlate = null, decimal? GrossWeightKg = null, int? Packages = null, string? Notes = null, string? PackageSpecies = null, string? PackageNumber = null, string? PackageBrand = null);

/// <summary>What the NF of an order would look like today, with nothing reserved, saved or sent. <see cref="Problems"/> is the checklist of what is still missing.</summary>
public sealed record NfPreview(bool FiscalEnabled, bool Simulated, string Environment, int Series, int NextNumber, string Cfop, string? CfopDescription, NfPreviewParty Issuer, NfPreviewParty Recipient,
    IReadOnlyList<NfPreviewLine> Lines, decimal ProductsTotal, decimal FreightTotal, decimal IcmsBase, decimal IcmsTotal, decimal IpiTotal, decimal PisTotal, decimal CofinsTotal, decimal InvoiceTotal,
    IReadOnlyList<NfPreviewInstallment> Installments, NfPreviewTransport Transport, string? AdditionalInfo, IReadOnlyList<NfProblem> Problems, bool Ready, string Company = "EBT", IReadOnlyList<NfPreviewOrderLine>? OrderLines = null);

public sealed partial class FiscalService
{
    /// <summary>
    /// Dry run of the sale NF of a whole order: same CFOP, price, tax and duplicata rules as the real emission, but nothing is reserved, saved or sent to SEFAZ.
    /// Every gap in the registrations comes back as a <see cref="NfProblem"/> instead of an exception, so the screen can show the full checklist at once.
    /// </summary>
    /// <summary>What a delivery address still lacks to be the recipient of an NF (the same checks the emission makes). Empty = complete.</summary>
    public static List<string> RecipientGaps(CustomerAddress address)
    {
        var gaps = new List<string>();
        if (Digits(address.Document).Length is not (11 or 14)) gaps.Add("CNPJ/CPF");
        if (string.IsNullOrWhiteSpace(address.Street) || string.IsNullOrWhiteSpace(address.District) || string.IsNullOrWhiteSpace(address.City)) gaps.Add("endereço");
        if (Digits(address.CityIbgeCode).Length != 7) gaps.Add("código IBGE do município");
        if (Digits(address.ZipCode).Length != 8) gaps.Add("CEP");
        if (!NfeKey.UfCodes.ContainsKey((address.Uf ?? "").ToUpperInvariant())) gaps.Add("UF");
        if (address.IcmsContributor && string.IsNullOrWhiteSpace(address.StateRegistration)) gaps.Add("inscrição estadual (contribuinte do ICMS)");
        return gaps;
    }

    /// <summary>
    /// Customers (active, not test data) with a delivery address that lacks something the NF needs, with the open orders each has. A customer without any address is listed too.
    /// The checks are the ones the emission makes, so an alert here is a block there.
    /// </summary>
    public async Task<List<CustomerFiscalProblem>> CustomerProblemsAsync(CancellationToken ct = default, int? customerId = null)
    {
        var customers = await db.Customers.AsNoTracking().Where(c => c.Active && c.Source != DataSource.Test && (customerId == null || c.Id == customerId)).Include(c => c.Addresses).OrderBy(c => c.Name).ToListAsync(ct);
        var open = await db.SalesOrders.AsNoTracking().Where(o => o.Status == SalesOrderStatus.Created || o.Status == SalesOrderStatus.Released || o.Status == SalesOrderStatus.PartiallyShipped)
            .GroupBy(o => o.CustomerId).Select(g => new { g.Key, N = g.Count() }).ToDictionaryAsync(x => x.Key, x => x.N, ct);
        var result = new List<CustomerFiscalProblem>();
        foreach (var c in customers)
        {
            var problems = new List<CustomerAddressProblem>();
            if (c.Addresses.Count == 0) problems.Add(new CustomerAddressProblem(0, "Sem endereço de entrega", ["endereço de entrega"]));
            foreach (var a in c.Addresses.OrderBy(a => a.Id))
            {
                var gaps = RecipientGaps(a);
                if (gaps.Count > 0) problems.Add(new CustomerAddressProblem(a.Id, string.Join(" · ", new[] { a.Street, a.City }.Where(x => !string.IsNullOrWhiteSpace(x))) is { Length: > 0 } label ? label : "Endereço " + a.Id, gaps));
            }
            if (problems.Count > 0) result.Add(new CustomerFiscalProblem(c.Id, c.Name, open.GetValueOrDefault(c.Id), problems));
        }
        return result;
    }

    public async Task<NfPreview> PreviewSaleAsync(int orderId, CancellationToken ct = default, IReadOnlyDictionary<int, decimal>? quantities = null, PreviewOverrides? typed = null)
    {
        var order = await db.SalesOrders.AsNoTracking().Include(o => o.Lines).FirstOrDefaultAsync(o => o.Id == orderId, ct) ?? throw FiscalException.NotFound("Sales order");
        var s = await ReadSettingsAsync(FiscalCompany.Of(order.BillTo), ct);
        var problems = new List<NfProblem>();
        void Add(string area, string message, string fix, bool blocking = true) => problems.Add(new NfProblem(area, message, fix, blocking));

        // Issuer
        var missing = new List<string>();
        if (Digits(s.Cnpj).Length != 14) missing.Add("CNPJ");
        if (string.IsNullOrWhiteSpace(s.StateRegistration)) missing.Add("inscrição estadual");
        if (string.IsNullOrWhiteSpace(s.CompanyName)) missing.Add("razão social");
        if (string.IsNullOrWhiteSpace(s.Street) || string.IsNullOrWhiteSpace(s.District) || string.IsNullOrWhiteSpace(s.City)) missing.Add("endereço");
        if (Digits(s.CityIbgeCode).Length != 7) missing.Add("código IBGE do município");
        if (Digits(s.ZipCode).Length != 8) missing.Add("CEP");
        if (missing.Count > 0) Add("Emitente", $"Dados do emitente incompletos: {string.Join(", ", missing)}.", "Fiscal > Emitente e emissão");
        if (!s.Enabled) Add("Emissão", "A emissão fiscal está desligada: a NF seria digitada à mão na expedição.", "Fiscal > Emitente e emissão (Editar parâmetros)", blocking: false);
        if (sefaz.IsSimulated) Add("SEFAZ", "Sem certificado digital A1: a NF é só simulada, sem valor fiscal.", "Fiscal > Emitente e emissão (certificado A1 no servidor)", blocking: false);

        // Recipient
        var customer = await db.Customers.AsNoTracking().FirstAsync(c => c.Id == order.CustomerId, ct);
        var address = await db.CustomerAddresses.AsNoTracking().FirstOrDefaultAsync(a => a.Id == order.AddressId, ct);
        string? recipientUf = address?.Uf;
        var recipient = new NfPreviewParty(Clean(customer.LegalName) ?? customer.Name, address?.Document, address?.StateRegistration, address is null ? null : $"{address.Street}, {address.Number} - {address.District}", address?.City, address?.Uf, address?.ZipCode, address?.CityIbgeCode, address?.Street, address?.Number, address?.District, address?.Phone);
        if (address is null) Add("Destinatário", "O pedido não tem endereço de entrega.", "Cadastro do cliente > Endereços");
        else
        {
            var gaps = RecipientGaps(address);
            if (gaps.Count > 0) Add("Destinatário", $"Cadastro de {customer.Name} incompleto para a NF: {string.Join(", ", gaps)}.", "Cadastro do cliente > Endereços");
        }

        // Operation
        var interstate = recipientUf is not null && !string.Equals(recipientUf, s.Uf, StringComparison.OrdinalIgnoreCase);
        var cfopCode = Clean(typed?.Cfop) ?? Clean(address?.DefaultCfop) ?? (interstate ? "6101" : "5101");
        var cfop = await db.Cfops.AsNoTracking().FirstOrDefaultAsync(c => c.Code == cfopCode, ct);
        if (cfop is null || !cfop.Active || cfop.Kind != FiscalKind.Sale)
        {
            Add("CFOP", $"CFOP {cfopCode} não está cadastrado ou ativo como venda.", "Fiscal > Importar do sistema antigo");
            cfop = new Cfop { Code = cfopCode, Description = "CFOP não cadastrado", Kind = FiscalKind.Sale, Taxed = true, IcmsCst = "00", IpiCst = "50", PisCst = "01", CofinsCst = "01" };
        }
        else if (cfop.Code[0] is '5' && interstate) Add("CFOP", $"CFOP {cfop.Code} é para dentro de {s.Uf}, mas o cliente é de {recipientUf}.", "Cadastro do cliente > Endereços > CFOP padrão");
        else if (cfop.Code[0] is '6' && !interstate) Add("CFOP", $"CFOP {cfop.Code} é para fora de {s.Uf}, mas o cliente é de {recipientUf}.", "Cadastro do cliente > Endereços > CFOP padrão");

        // Items
        var productIds = order.Lines.Select(l => l.ProductId).Distinct().ToList();
        var products = await db.Products.AsNoTracking().Where(p => productIds.Contains(p.Id)).ToDictionaryAsync(p => p.Id, ct);
        var ncmOv = await NcmOverridesAsync(s.Company, productIds, ct);
        var rules = await db.TaxRules.AsNoTracking().Where(r => r.CfopCode == cfop.Code && productIds.Contains(r.ProductId) && (r.CustomerId == customer.Id || r.CustomerId == null)).ToListAsync(ct);
        var local = DateTimeOffset.UtcNow.ToOffset(BrazilOffset);
        var ufIcms = await UfIcmsAsync(recipientUf, ct);
        var doc = new FiscalDocument
        {
            Kind = FiscalKind.Sale, Status = FiscalStatus.Pending, CfopCode = cfop.Code, Series = s.Series, Number = s.NextNumber, AccessKey = "", Environment = s.Environment, Protocol = "", IssuedAt = local,
            RecipientName = Clean(customer.LegalName) ?? customer.Name, RecipientDocument = Digits(address?.Document), RecipientUf = recipientUf ?? "", Xml = ""
        };
        // The NF states what is about to leave: by default what is still to ship of each line, or the weighed quantities the screen sends (0 leaves a line out).
        var shippedByLine = await db.DeliveryLines.AsNoTracking().Where(l => l.Delivery!.OrderId == orderId && (l.Delivery.Status == DeliveryStatus.Shipped || l.Delivery.Status == DeliveryStatus.Delivered))
            .GroupBy(l => l.OrderLineId).Select(g => new { g.Key, Qty = g.Sum(x => x.Quantity) }).ToDictionaryAsync(x => x.Key, x => x.Qty, ct);
        var orderLines = new List<NfPreviewOrderLine>();
        var weights = new List<(decimal? NetWeightKg, decimal Quantity)>(); // kg per unit x quantity: a line sold by KG already is kg

        var sources = new List<(string Price, string Tax)>();
        var noNcm = new List<string>();
        var noPrice = new List<string>();
        var noRule = new List<string>();
        foreach (var (ol, n) in order.Lines.OrderBy(l => l.Sequence).Select((l, n) => (l, n)))
        {
            var p = products[ol.ProductId];
            var remaining = Math.Max(0, ol.Quantity - shippedByLine.GetValueOrDefault(ol.Id));
            var qty = quantities is null ? remaining : quantities.GetValueOrDefault(ol.Id);
            orderLines.Add(new NfPreviewOrderLine(ol.Id, ol.Sequence, p.Code, ol.Description, ol.SaleUnit ?? ol.Unit, ol.Quantity, remaining, Math.Max(0, qty)));
            if (qty <= 0) continue;
            weights.Add((SalesService.KgPerUnit(ol, p), qty));
            var monthly = await MonthlyPriceAsync(p.Id, customer.Id, cfop.Code, local.Year, local.Month, ct);
            var price = monthly ?? ol.UnitPrice;
            if (price <= 0) noPrice.Add(p.Code);
            if (Digits(ncmOv.GetValueOrDefault(p.Id) ?? p.Ncm).Length != 8) noNcm.Add(p.Code);
            var rule = rules.Where(r => r.ProductId == p.Id).OrderBy(r => r.CustomerId == null).FirstOrDefault();
            if (rule is null && cfop.Taxed) noRule.Add(p.Code);
            doc.Lines.Add(new FiscalDocumentLine
            {
                Sequence = (n + 1) * 10, ProductId = p.Id, ProductionOrderId = ol.ProductionOrderId, Code = p.Code, Description = await ItemDescriptionAsync(customer.Id, p.Id, ol.Description, ct), Ncm = Digits(ncmOv.GetValueOrDefault(p.Id) ?? p.Ncm), Unit = ol.SaleUnit ?? ol.Unit,
                Quantity = qty, UnitPrice = price, Total = Money(qty * price), IcmsCst = "", IpiCst = "", PisCst = "", CofinsCst = ""
            }.WithRates(cfop, rule, ol.IcmsPercent, ol.IpiPercent, ufIcms));
            sources.Add((monthly is not null ? "Tabela mensal" : "Pedido", rule is not null ? (rule.CustomerId is null ? "Regra do produto" : "Regra do cliente") : ol.IcmsPercent > 0 ? $"Alíquota do pedido, CST do CFOP {cfop.Code}" : ufIcms is not null ? $"ICMS de {recipientUf}, CST do CFOP {cfop.Code}" : $"Padrão do CFOP {cfop.Code}"));
        }
        if (noNcm.Count > 0) Add("Produtos", $"Sem NCM válido (8 dígitos): {string.Join(", ", noNcm)}.", "Engenharia > Produtos > NCM");
        if (noPrice.Count > 0) Add("Preço", $"Sem preço: {string.Join(", ", noPrice)}.", "Pedido de venda ou tabela mensal de preços");
        if (noRule.Count > 0) Add("Impostos", $"Sem regra de imposto (usa o padrão do CFOP, a confirmar com o contador): {string.Join(", ", noRule)}.", "Fiscal > Parâmetros fiscais > Regras de imposto", blocking: false);

        doc.ProductsTotal = doc.Lines.Sum(l => l.Total);
        doc.FreightTotal = Money(typed?.Freight ?? 0m);
        AllocateFreight(doc);
        CalculateTaxes(doc, cfop, customerIcmsContributor: address?.IcmsContributor ?? false);

        // Duplicatas and transport
        var installments = new List<NfPreviewInstallment>();
        if (cfop.GeneratesInstallments)
        {
            try
            {
                doc.Installments = await InstallmentsAsync(order, customer, doc.InvoiceTotal, local, ct);
                installments = doc.Installments.Select(i => new NfPreviewInstallment(i.Sequence, i.DueDate, i.Amount)).ToList();
            }
            catch (FiscalException) { Add("Duplicatas", "O pedido e o cliente não têm prazo de pagamento para gerar as duplicatas.", "Pedido de venda > Prazo de pagamento"); }
        }
        var volumes = doc.Lines.Sum(l => products[l.ProductId!.Value].PiecesPerPackage is > 0 ? (int)Math.Ceiling(l.Quantity / products[l.ProductId!.Value].PiecesPerPackage!.Value) : 0);
        var transport = await TransportAsync(order.Freight == FreightTerms.Cif ? 0 : 1, typed?.Carrier, typed?.VehiclePlate, typed?.Packages ?? volumes, typed?.GrossWeightKg, weights, s, ct, new PackageInfo(typed?.PackageSpecies, typed?.PackageNumber, typed?.PackageBrand));
        if (transport.NetWeightKg is null) Add("Transporte", "Algum produto sem peso líquido: a NF sai sem o peso (pesoL).", "Engenharia > Produtos > Peso líquido", blocking: false);

        var info = SaleInfoText(SaleLegalText(cfop, doc.Lines), order.CustomerPo, Clean(typed?.Notes), customer.PoPhrase);
        doc.AdditionalInfo = info;

        // The real check: build the NF-e XML and validate it against the official schema, so a layout problem shows here and not at the shipment.
        if (problems.All(p => !p.Blocking) && address is not null)
        {
            try
            {
                doc.AccessKey = NfeKey.Build(NfeKey.UfCodes[s.Uf], local, s.Cnpj!, s.Series, s.NextNumber, NfeKey.NewCodeNumber(s.NextNumber));
                var party = new NfeParty(Clean(customer.LegalName) ?? customer.Name, address.Document, address.StateRegistration, address.IcmsContributor, address.Street, address.Number, address.Complement, address.District, address.City, address.CityIbgeCode, address.Uf, address.ZipCode, address.Email ?? customer.Email, address.Phone);
                NfeSchema.ValidateNfe(NfeXml.Build(s, doc, cfop, party, transport, interstate));
            }
            catch (FiscalException e) { Add("Layout da NF-e", e.Message, "Cadastros indicados na mensagem (o XML não passou na validação do layout 4.00)"); }
        }
        var issuer = new NfPreviewParty(s.CompanyName ?? "", s.Cnpj, s.StateRegistration, $"{s.Street}, {s.Number} - {s.District}", s.City, s.Uf, s.ZipCode, s.CityIbgeCode, s.Street, s.Number, s.District, s.Phone);
        var lines = doc.Lines.Select((l, i) => new NfPreviewLine(l.Sequence, l.Code, l.Description, l.Ncm, l.Unit, l.Quantity, l.UnitPrice, l.Total, sources[i].Price, l.IcmsCst, l.IcmsPercent, l.IcmsValue, l.IpiCst, l.IpiPercent, l.IpiValue, l.PisValue, l.CofinsValue, sources[i].Tax)).ToList();
        return new NfPreview(s.Enabled, sefaz.IsSimulated, s.Environment.ToString(), s.Series, s.NextNumber, cfop.Code, cfop.Description, issuer, recipient, lines, doc.ProductsTotal, doc.FreightTotal, doc.IcmsBase, doc.IcmsTotal,
            doc.IpiTotal, doc.PisTotal, doc.CofinsTotal, doc.InvoiceTotal, installments, new NfPreviewTransport(transport.FreightMode == 0 ? "Por conta do emitente (CIF)" : "Por conta do destinatário (FOB)", transport.Carrier, transport.NetWeightKg, transport.GrossWeightKg, transport.Packages, Clean(typed?.PackageSpecies) ?? (transport.Packages > 1 ? "VOLUMES" : "VOLUME"), transport.VehiclePlate, transport.FreightMode, transport.CarrierDocument, transport.CarrierStateRegistration, transport.CarrierAddress, transport.CarrierCity, transport.CarrierUf), info,
            problems, problems.All(p => !p.Blocking), s.Company, orderLines);
    }
}
