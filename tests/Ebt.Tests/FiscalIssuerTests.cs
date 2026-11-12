using System.Net;
using System.Text;
using System.Text.Json;
using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;
using Ebt.Core.Entities;
using Ebt.Core.Fiscal;
using Ebt.Core.Inventory;
using Ebt.Core.Sales;

namespace Ebt.Tests;

/// <summary>EBT and BST each have their own issuer row (CNPJ, series, numbering, on/off); an order is issued by the company of its "Faturar para".</summary>
[Collection("api")]
public class FiscalIssuerTests(ApiFixture api)
{
    private const string EbtCnpj = "11222333000181";
    private const string BstCnpj = "51440317000180";
    private static readonly DateOnly Today = DateOnly.FromDateTime(DateTime.Today);

    private static string Code(string prefix, int length = 12) => $"{prefix}{Guid.NewGuid():N}"[..length].ToUpper();
    private static ProductIn Tube(string code) => new(code, "Tubo " + code, ProductKind.Part, TubeShape.Circular, 25.4m, null, null, 1.5m, 1000m, null, null, "73063010", "PC", 50, false, null, null);

    private static async Task<FiscalSettingsDto> Configure(HttpClient admin, string company, bool enabled, string cnpj)
    {
        var s = await (await admin.GetAsync($"/api/fiscal/settings?company={company}")).Read<FiscalSettingsDto>();
        var next = s with
        {
            Enabled = enabled, Environment = SefazEnvironment.Homologation, CompanyName = $"{company} Tubos Ltda", TradeName = company, Cnpj = cnpj, StateRegistration = "111222333444", TaxRegime = 3,
            Street = "Rua das Industrias", Number = "10", District = "Distrito", City = "Embu das Artes", CityIbgeCode = "3515004", Uf = "SP", ZipCode = "06800000", Phone = "1144444444"
        };
        return await (await admin.Put($"/api/fiscal/settings?company={company}", next)).Read<FiscalSettingsDto>();
    }

    private static Task<FiscalSettingsDto> Settings(HttpClient admin, string company) => admin.GetAsync($"/api/fiscal/settings?company={company}").ContinueWith(t => t.Result.Read<FiscalSettingsDto>()).Unwrap();

    private static async Task<decimal> Balance(HttpClient c, int productId, int locationId) =>
        (await (await c.GetAsync($"/api/stock/balances?productId={productId}&locationId={locationId}")).Read<Page<StockBalanceOut>>()).Items.Sum(b => b.Quantity);

    /// <summary>A released order of 10 pieces from stock for the given "Faturar para".</summary>
    private static async Task<SalesOrderOut> ReleasedOrderAsync(HttpClient admin, BillTo billTo)
    {
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        var address = await (await admin.Post($"/api/customers/{customer.Id}/addresses", new CustomerAddressIn("26133636000103", "SP", null, "148061942112", true, "Av. Brasil", "100", null, "Centro", "Embu", "3515004", "06800000", "5101", "Edilto", "compras@cliente.com", null))).Read<CustomerAddressOut>();
        var tube = await (await admin.Post("/api/products", Tube(Code("T")))).Read<ProductOut>();
        var shipping = await (await admin.Post("/api/stock-locations", new StockLocationIn(Code("E", 10), "Expedição", StockLocationKind.Internal))).Read<StockLocationOut>();
        (await admin.Put("/api/sales/settings", new SalesSettingsDto(5m, 15, 0m, shipping.Id, null))).EnsureSuccessStatusCode();
        (await admin.Post("/api/stock/documents", new StockPost(MovementType.AdjustmentIn, Today, [new StockLine(null, tube.Id, shipping.Id, 30m, UnitCost: 5m)], "INV"))).EnsureSuccessStatusCode();
        var term = await (await admin.Post("/api/sales/payment-terms", new PaymentTermIn(Code("P", 8), "28 DDL", "28", 1_000_000m))).Read<PaymentTermOut>();
        (await admin.Post("/api/sales/price-list", new PriceListIn(tube.Id, null, 100m, 5m, 18m, Today.AddDays(-1), null))).EnsureSuccessStatusCode();
        var order = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customer.Id, address.Id, [new SalesLineInput(tube.Id, 10m)], "PO-9", term.Id, BillTo: billTo))).Read<SalesOrderOut>();
        await admin.Post($"/api/sales/orders/{order.Id}/release", new SalesReleaseIn());
        return order;
    }

    private static async Task<DeliveryOut> ShipAsync(HttpClient admin, int orderId)
    {
        var delivery = await (await admin.Post($"/api/sales/orders/{orderId}/deliveries", new DeliveryInput(Today))).Read<DeliveryOut>();
        return await (await admin.Post($"/api/sales/deliveries/{delivery.Id}/ship", new ShipInput(Today, WithoutCertificate: true))).Read<DeliveryOut>();
    }

    private static async Task<FiscalDocumentOut> DocumentOfAsync(HttpClient admin, int deliveryId)
    {
        var doc = Assert.Single((await (await admin.GetAsync($"/api/fiscal/documents?deliveryId={deliveryId}")).Read<Page<FiscalDocumentSummary>>()).Items);
        return await (await admin.GetAsync($"/api/fiscal/documents/{doc.Id}")).Read<FiscalDocumentOut>();
    }

    [Fact]
    public async Task Both_companies_have_their_own_issuer_and_editing_one_leaves_the_other_alone()
    {
        var admin = await api.AdminAsync();
        var all = await (await admin.GetAsync("/api/fiscal/settings/all")).Read<List<FiscalSettingsDto>>();
        Assert.Equal(["EBT", "BST"], all.Select(s => s.Company).ToArray());
        Assert.True(all[1].NextNumber >= 897, "BST numbering starts at 897");
        Assert.False(all[1].Enabled);

        var ebtBefore = await Settings(admin, "EBT");
        var bst = await Configure(admin, "BST", false, BstCnpj);
        Assert.Equal("BST", bst.Company);
        Assert.Equal(BstCnpj, bst.Cnpj);
        var ebtAfter = await Settings(admin, "EBT");
        Assert.Equal(ebtBefore.Cnpj, ebtAfter.Cnpj);
        Assert.Equal(ebtBefore.NextNumber, ebtAfter.NextNumber);
        Assert.Equal(ebtBefore.Enabled, ebtAfter.Enabled);

        // No company named means EBT; an unknown one is refused.
        Assert.Equal("EBT", (await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>()).Company);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.GetAsync("/api/fiscal/settings?company=XYZ")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.Put("/api/fiscal/settings?company=XYZ", bst)).StatusCode);
    }

    [Fact]
    public async Task Each_order_is_issued_by_the_company_of_its_faturar_para_with_that_companys_cnpj_and_numbering()
    {
        var admin = await api.AdminAsync();
        // The shipping location is one setting of the system, so each order is created right before it ships.
        var bstOrder = await ReleasedOrderAsync(admin, BillTo.Bts);
        try
        {
            var ebt = await Configure(admin, "EBT", true, EbtCnpj);
            var bst = await Configure(admin, "BST", true, BstCnpj);

            var bstDelivery = await ShipAsync(admin, bstOrder.Id);
            var bstNf = await DocumentOfAsync(admin, bstDelivery.Id);
            Assert.Equal("BST", bstNf.IssuerCompany);
            Assert.Equal(bst.NextNumber, bstNf.Number);
            Assert.Equal(bst.NextNumber.ToString(), bstDelivery.InvoiceNumber);
            Assert.Equal(BstCnpj, bstNf.AccessKey.Substring(6, 14));

            var ebtOrder = await ReleasedOrderAsync(admin, BillTo.Ebt);
            var ebtDelivery = await ShipAsync(admin, ebtOrder.Id);
            var ebtNf = await DocumentOfAsync(admin, ebtDelivery.Id);
            Assert.Equal("EBT", ebtNf.IssuerCompany);
            Assert.Equal(ebt.NextNumber, ebtNf.Number);
            Assert.Equal(EbtCnpj, ebtNf.AccessKey.Substring(6, 14));

            // Each company's counter moved by one, the other did not.
            Assert.Equal(bst.NextNumber + 1, (await Settings(admin, "BST")).NextNumber);
            Assert.Equal(ebt.NextNumber + 1, (await Settings(admin, "EBT")).NextNumber);

        }
        finally
        {
            await Configure(admin, "EBT", false, EbtCnpj);
            await Configure(admin, "BST", false, BstCnpj);
        }
    }

    [Fact]
    public async Task A_company_with_emission_off_does_not_emit_even_when_the_other_one_does()
    {
        var admin = await api.AdminAsync();
        var bstOrder = await ReleasedOrderAsync(admin, BillTo.Bts);
        try
        {
            await Configure(admin, "EBT", true, EbtCnpj);
            var bstBefore = await Configure(admin, "BST", false, BstCnpj);

            var delivery = await ShipAsync(admin, bstOrder.Id);

            Assert.Equal(DeliveryStatus.Shipped, delivery.Status);
            Assert.Null(delivery.InvoiceNumber);
            Assert.Empty((await (await admin.GetAsync($"/api/fiscal/documents?deliveryId={delivery.Id}")).Read<Page<FiscalDocumentSummary>>()).Items);
            Assert.Equal(bstBefore.NextNumber, (await Settings(admin, "BST")).NextNumber);
        }
        finally
        {
            await Configure(admin, "EBT", false, EbtCnpj);
        }
    }

    [Fact]
    public async Task The_dry_run_of_an_order_shows_the_issuer_of_its_company()
    {
        var admin = await api.AdminAsync();
        var bstOrder = await ReleasedOrderAsync(admin, BillTo.Bts);
        var ebtOrder = await ReleasedOrderAsync(admin, BillTo.Ebt);
        try
        {
            await Configure(admin, "EBT", false, EbtCnpj);
            var bst = await Configure(admin, "BST", false, BstCnpj);

            var bstPreview = await (await admin.GetAsync($"/api/fiscal/preview/order/{bstOrder.Id}")).Read<NfPreview>();
            Assert.Equal("BST", bstPreview.Company);
            Assert.Equal(BstCnpj, bstPreview.Issuer.Document);
            Assert.Equal(bst.NextNumber, bstPreview.NextNumber);

            var ebtPreview = await (await admin.GetAsync($"/api/fiscal/preview/order/{ebtOrder.Id}")).Read<NfPreview>();
            Assert.Equal("EBT", ebtPreview.Company);
            Assert.Equal(EbtCnpj, ebtPreview.Issuer.Document);
        }
        finally
        {
            await Configure(admin, "BST", false, BstCnpj);
        }
    }

    [Fact]
    public async Task An_incomplete_issuer_of_one_company_blocks_only_that_company()
    {
        var admin = await api.AdminAsync();
        var bstOrder = await ReleasedOrderAsync(admin, BillTo.Bts);
        var ebtOrder = await ReleasedOrderAsync(admin, BillTo.Ebt);
        var bst = await Settings(admin, "BST");
        try
        {
            await Configure(admin, "EBT", true, EbtCnpj);
            // BST stays with the issuer data it has now (maybe empty); the preview names what is missing, and only for BST.
            var bstPreview = await (await admin.GetAsync($"/api/fiscal/preview/order/{bstOrder.Id}")).Read<NfPreview>();
            var ebtPreview = await (await admin.GetAsync($"/api/fiscal/preview/order/{ebtOrder.Id}")).Read<NfPreview>();
            Assert.DoesNotContain(ebtPreview.Problems, p => p.Area == "Emitente");
            if (string.IsNullOrWhiteSpace(bst.Cnpj)) Assert.Contains(bstPreview.Problems, p => p.Area == "Emitente" && p.Blocking);
        }
        finally
        {
            await Configure(admin, "EBT", false, EbtCnpj);
        }
    }

    private static async Task<HttpResponseMessage> UploadAsync(HttpClient c, object bundle, bool apply)
    {
        var form = new MultipartFormDataContent { { new ByteArrayContent(new UTF8Encoding(false).GetBytes(JsonSerializer.Serialize(bundle))), "file", "fiscal-data.json" } };
        return await c.PostAsync($"/api/fiscal/legacy-import?apply={apply.ToString().ToLowerInvariant()}", form);
    }

    [Fact]
    public async Task The_import_of_a_bst_file_fills_only_the_bst_issuer_and_leaves_rules_and_prices_out()
    {
        var admin = await api.AdminAsync();
        var ebtBefore = await Settings(admin, "EBT");
        var bundle = new
        {
            source = "BST",
            issuer = new { companyName = "BST TUBOS LTDA", cnpj = "51.440.317/0001-80", stateRegistration = "124.491.149.119", street = "R ANTONIO DA SILVA LEITE", number = "175", district = "VILA NOVA PARADA", city = "SAO PAULO", cityIbgeCode = "3550308", uf = "SP", zipCode = "02883-070", nextNumber = 1 },
            taxRules = new[] { new { productCode = "QUALQUER", customerCode = "1", cfop = "5101", icmsCst = "00", icmsPercent = 18m, ipiCst = "50", ipiPercent = 3.25m, pisPercent = 0.65m, cofinsPercent = 3m } },
            monthlyPrices = Array.Empty<object>()
        };
        var rulesBefore = (await (await admin.GetAsync("/api/fiscal/legacy-import/summary")).Read<FiscalDataSummary>()).TaxRules;

        var preview = await (await UploadAsync(admin, bundle, apply: false)).Read<FiscalImportResult>();
        Assert.Contains(preview.Sections.Single(x => x.Section == "issuer").Notes, n => n.Contains("BST"));
        Assert.Equal(1, preview.Sections.Single(x => x.Section == "taxRules").Skipped);
        Assert.Equal(0, preview.Sections.Single(x => x.Section == "taxRules").Added);

        var bstBefore = await Settings(admin, "BST");
        Assert.True((await UploadAsync(admin, bundle, apply: true)).IsSuccessStatusCode);
        var bst = await Settings(admin, "BST");
        if (string.IsNullOrWhiteSpace(bstBefore.Cnpj))
        {
            Assert.Equal("51440317000180", bst.Cnpj);
            Assert.Equal("BST TUBOS LTDA", bst.CompanyName);
        }
        Assert.False(bst.Enabled);
        Assert.True(bst.NextNumber >= bstBefore.NextNumber, "a lower number in the file never lowers the counter");

        var ebtAfter = await Settings(admin, "EBT");
        Assert.Equal(ebtBefore.Cnpj, ebtAfter.Cnpj);
        Assert.Equal(ebtBefore.NextNumber, ebtAfter.NextNumber);
        Assert.Equal(rulesBefore, (await (await admin.GetAsync("/api/fiscal/legacy-import/summary")).Read<FiscalDataSummary>()).TaxRules);

        var summary = await (await admin.GetAsync("/api/fiscal/legacy-import/summary?company=BST")).Read<FiscalDataSummary>();
        Assert.Equal("BST", summary.Company);
        Assert.Equal(bst.NextNumber, summary.NextNumber);
    }

    [Fact]
    public async Task A_file_that_names_an_unknown_company_is_refused()
    {
        var admin = await api.AdminAsync();
        var res = await UploadAsync(admin, new { source = "XYZ" }, apply: false);
        Assert.Equal(HttpStatusCode.BadRequest, res.StatusCode);
    }

    [Fact]
    public void Faturar_para_maps_to_the_issuing_company_and_names_are_normalized()
    {
        Assert.Equal("EBT", FiscalCompany.Of(BillTo.Ebt));
        Assert.Equal("BST", FiscalCompany.Of(BillTo.Bts));
        Assert.Equal("EBT", FiscalCompany.Parse(null));
        Assert.Equal("EBT", FiscalCompany.Parse(" ebt "));
        Assert.Equal("BST", FiscalCompany.Parse("bst"));
        Assert.Null(FiscalCompany.Parse("outra"));
    }
}
