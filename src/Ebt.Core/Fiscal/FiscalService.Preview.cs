using Ebt.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Fiscal;

/// <summary>Something that would stop (Blocking) or only deserves a look before the NF of an order is emitted. <paramref name="Fix"/> says where to fix it.</summary>
public sealed record NfProblem(string Area, string Message, string Fix, bool Blocking = true);

public sealed record NfPreviewParty(string Name, string? Document, string? StateRegistration, string? Address, string? City, string? Uf, string? ZipCode, string? CityIbgeCode);

public sealed record NfPreviewLine(int Sequence, string Code, string Description, string? Ncm, string Unit, decimal Quantity, decimal UnitPrice, decimal Total, string PriceSource,
    string IcmsCst, decimal IcmsPercent, decimal IcmsValue, string IpiCst, decimal IpiPercent, decimal IpiValue, decimal PisValue, decimal CofinsValue, string TaxSource);

public sealed record NfPreviewInstallment(int Sequence, DateOnly DueDate, decimal Amount);

public sealed record NfPreviewTransport(string Mode, string? Carrier, decimal? NetWeightKg);

/// <summary>What the NF of an order would look like today, with nothing reserved, saved or sent. <see cref="Problems"/> is the checklist of what is still missing.</summary>
public sealed record NfPreview(bool FiscalEnabled, bool Simulated, string Environment, int Series, int NextNumber, string Cfop, string? CfopDescription, NfPreviewParty Issuer, NfPreviewParty Recipient,
    IReadOnlyList<NfPreviewLine> Lines, decimal ProductsTotal, decimal FreightTotal, decimal IcmsBase, decimal IcmsTotal, decimal IpiTotal, decimal PisTotal, decimal CofinsTotal, decimal InvoiceTotal,
    IReadOnlyList<NfPreviewInstallment> Installments, NfPreviewTransport Transport, string? AdditionalInfo, IReadOnlyList<NfProblem> Problems, bool Ready);

public sealed partial class FiscalService
{
    /// <summary>
    /// Dry run of the sale NF of a whole order: same CFOP, price, tax and duplicata rules as the real emission, but nothing is reserved, saved or sent to SEFAZ.
    /// Every gap in the registrations comes back as a <see cref="NfProblem"/> instead of an exception, so the screen can show the full checklist at once.
    /// </summary>
    public async Task<NfPreview> PreviewSaleAsync(int orderId, CancellationToken ct = default)
    {
        var order = await db.SalesOrders.AsNoTracking().Include(o => o.Lines).FirstOrDefaultAsync(o => o.Id == orderId, ct) ?? throw FiscalException.NotFound("Sales order");
        var s = await ReadSettingsAsync(ct);
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
        var recipient = new NfPreviewParty(customer.Name, address?.Document, address?.StateRegistration, address is null ? null : $"{address.Street}, {address.Number} - {address.District}", address?.City, address?.Uf, address?.ZipCode, address?.CityIbgeCode);
        if (address is null) Add("Destinatário", "O pedido não tem endereço de entrega.", "Cadastro do cliente > Endereços");
        else
        {
            var gaps = new List<string>();
            if (Digits(address.Document).Length is not (11 or 14)) gaps.Add("CNPJ/CPF");
            if (string.IsNullOrWhiteSpace(address.Street) || string.IsNullOrWhiteSpace(address.District) || string.IsNullOrWhiteSpace(address.City)) gaps.Add("endereço");
            if (Digits(address.CityIbgeCode).Length != 7) gaps.Add("código IBGE do município");
            if (Digits(address.ZipCode).Length != 8) gaps.Add("CEP");
            if (!NfeKey.UfCodes.ContainsKey(address.Uf.ToUpperInvariant())) gaps.Add("UF");
            if (address.IcmsContributor && string.IsNullOrWhiteSpace(address.StateRegistration)) gaps.Add("inscrição estadual (contribuinte do ICMS)");
            if (gaps.Count > 0) Add("Destinatário", $"Cadastro de {customer.Name} incompleto para a NF: {string.Join(", ", gaps)}.", "Cadastro do cliente > Endereços");
        }

        // Operation
        var interstate = recipientUf is not null && !string.Equals(recipientUf, s.Uf, StringComparison.OrdinalIgnoreCase);
        var cfopCode = Clean(address?.DefaultCfop) ?? (interstate ? "6101" : "5101");
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
        var rules = await db.TaxRules.AsNoTracking().Where(r => r.CfopCode == cfop.Code && productIds.Contains(r.ProductId) && (r.CustomerId == customer.Id || r.CustomerId == null)).ToListAsync(ct);
        var local = DateTimeOffset.UtcNow.ToOffset(BrazilOffset);
        var ufIcms = await UfIcmsAsync(recipientUf, ct);
        var doc = new FiscalDocument
        {
            Kind = FiscalKind.Sale, Status = FiscalStatus.Pending, CfopCode = cfop.Code, Series = s.Series, Number = s.NextNumber, AccessKey = "", Environment = s.Environment, Protocol = "", IssuedAt = local,
            RecipientName = customer.Name, RecipientDocument = Digits(address?.Document), RecipientUf = recipientUf ?? "", Xml = ""
        };
        var sources = new List<(string Price, string Tax)>();
        var noNcm = new List<string>();
        var noPrice = new List<string>();
        var noRule = new List<string>();
        foreach (var (ol, n) in order.Lines.OrderBy(l => l.Sequence).Select((l, n) => (l, n)))
        {
            var p = products[ol.ProductId];
            var monthly = await MonthlyPriceAsync(p.Id, customer.Id, cfop.Code, local.Year, local.Month, ct);
            var price = monthly ?? ol.UnitPrice;
            if (price <= 0) noPrice.Add(p.Code);
            if (Digits(p.Ncm).Length != 8) noNcm.Add(p.Code);
            var rule = rules.Where(r => r.ProductId == p.Id).OrderBy(r => r.CustomerId == null).FirstOrDefault();
            if (rule is null && cfop.Taxed) noRule.Add(p.Code);
            doc.Lines.Add(new FiscalDocumentLine
            {
                Sequence = (n + 1) * 10, ProductId = p.Id, ProductionOrderId = ol.ProductionOrderId, Code = p.Code, Description = ol.Description, Ncm = Digits(p.Ncm), Unit = p.StockUnit,
                Quantity = ol.Quantity, UnitPrice = price, Total = Money(ol.Quantity * price), IcmsCst = "", IpiCst = "", PisCst = "", CofinsCst = ""
            }.WithRates(cfop, rule, ol.IcmsPercent, ol.IpiPercent, ufIcms));
            sources.Add((monthly is not null ? "Tabela mensal" : "Pedido", rule is not null ? (rule.CustomerId is null ? "Regra do produto" : "Regra do cliente") : ol.IcmsPercent > 0 ? $"Alíquota do pedido, CST do CFOP {cfop.Code}" : ufIcms is not null ? $"ICMS de {recipientUf}, CST do CFOP {cfop.Code}" : $"Padrão do CFOP {cfop.Code}"));
        }
        if (noNcm.Count > 0) Add("Produtos", $"Sem NCM válido (8 dígitos): {string.Join(", ", noNcm)}.", "Engenharia > Produtos > NCM");
        if (noPrice.Count > 0) Add("Preço", $"Sem preço: {string.Join(", ", noPrice)}.", "Pedido de venda ou tabela mensal de preços");
        if (noRule.Count > 0) Add("Impostos", $"Sem regra de imposto (usa o padrão do CFOP, a confirmar com o contador): {string.Join(", ", noRule)}.", "Fiscal > Parâmetros fiscais > Regras de imposto", blocking: false);

        doc.ProductsTotal = doc.Lines.Sum(l => l.Total);
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
        var transport = await TransportAsync(order.Freight == FreightTerms.Cif ? 0 : 1, null, null, 0, null, doc.Lines.Select(l => (products[l.ProductId!.Value].NetWeightKg, l.Quantity)).ToList(), ct);
        if (transport.NetWeightKg is null) Add("Transporte", "Algum produto sem peso líquido: a NF sai sem o peso (pesoL).", "Engenharia > Produtos > Peso líquido", blocking: false);

        var ofIds = order.Lines.Where(l => l.ProductionOrderId != null).Select(l => l.ProductionOrderId!.Value).ToList();
        var ofs = await db.ProductionOrders.AsNoTracking().Where(o => ofIds.Contains(o.Id)).Select(o => o.Reference).ToListAsync(ct);
        var info = Join(order.Reference, ofs.Count > 0 ? string.Join(", ", ofs) : null, order.CustomerPo is { } po ? $"Pedido cliente {po}" : null, cfop.LegalText);
        doc.AdditionalInfo = info;

        // The real check: build the NF-e XML and validate it against the official schema, so a layout problem shows here and not at the shipment.
        if (problems.All(p => !p.Blocking) && address is not null)
        {
            try
            {
                doc.AccessKey = NfeKey.Build(NfeKey.UfCodes[s.Uf], local, s.Cnpj!, s.Series, s.NextNumber, NfeKey.NewCodeNumber(s.NextNumber));
                var party = new NfeParty(customer.Name, address.Document, address.StateRegistration, address.IcmsContributor, address.Street, address.Number, address.Complement, address.District, address.City, address.CityIbgeCode, address.Uf, address.ZipCode, address.Email ?? customer.Email, address.Phone);
                NfeSchema.ValidateNfe(NfeXml.Build(s, doc, cfop, party, transport, interstate));
            }
            catch (FiscalException e) { Add("Layout da NF-e", e.Message, "Cadastros indicados na mensagem (o XML não passou na validação do layout 4.00)"); }
        }
        var issuer = new NfPreviewParty(s.CompanyName ?? "", s.Cnpj, s.StateRegistration, $"{s.Street}, {s.Number} - {s.District}", s.City, s.Uf, s.ZipCode, s.CityIbgeCode);
        var lines = doc.Lines.Select((l, i) => new NfPreviewLine(l.Sequence, l.Code, l.Description, l.Ncm, l.Unit, l.Quantity, l.UnitPrice, l.Total, sources[i].Price, l.IcmsCst, l.IcmsPercent, l.IcmsValue, l.IpiCst, l.IpiPercent, l.IpiValue, l.PisValue, l.CofinsValue, sources[i].Tax)).ToList();
        return new NfPreview(s.Enabled, sefaz.IsSimulated, s.Environment.ToString(), s.Series, s.NextNumber, cfop.Code, cfop.Description, issuer, recipient, lines, doc.ProductsTotal, doc.FreightTotal, doc.IcmsBase, doc.IcmsTotal,
            doc.IpiTotal, doc.PisTotal, doc.CofinsTotal, doc.InvoiceTotal, installments, new NfPreviewTransport(transport.FreightMode == 0 ? "Por conta do emitente (CIF)" : "Por conta do destinatário (FOB)", transport.Carrier, transport.NetWeightKg), info,
            problems, problems.All(p => !p.Blocking));
    }
}
