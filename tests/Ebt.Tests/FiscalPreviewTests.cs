using System.Text;
using System.Text.Json;
using Ebt.Api.Endpoints;
using Ebt.Core.Entities;
using Ebt.Core.Fiscal;
using Ebt.Core.Inventory;
using Ebt.Core.Sales;

namespace Ebt.Tests;

/// <summary>The "Nota Fiscal" step of an order (dry run of the NF) and the import of the fiscal data of the old system.</summary>
[Collection("api")]
public class FiscalPreviewTests(ApiFixture api)
{
    private static readonly DateOnly Today = DateOnly.FromDateTime(DateTime.Today);
    private static string Code(string prefix, int length = 12) => $"{prefix}{Guid.NewGuid():N}"[..length].ToUpper();
    private static ProductIn Tube(string code, string? ncm = "73063010") => new(code, "Tubo " + code, ProductKind.Part, TubeShape.Circular, 25.4m, null, null, 1.5m, 1000m, null, null, ncm, "PC", 50, false, null, null);

    private static async Task<FiscalSettingsDto> SetIssuer(HttpClient admin, bool complete)
    {
        var s = await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>();
        var next = complete
            ? s with
            {
                Enabled = false, CompanyName = "EBT Tubos Ltda", TradeName = "EBT", Cnpj = "11222333000181", StateRegistration = "111222333444", TaxRegime = 3, Street = "Rua das Industrias", Number = "10", District = "Distrito",
                City = "Embu das Artes", CityIbgeCode = "3515004", Uf = "SP", ZipCode = "06800000", Phone = "1144444444"
            }
            : s with { Enabled = false, CompanyName = null, TradeName = null, Cnpj = null, StateRegistration = null, Street = null, Number = null, District = null, City = null, CityIbgeCode = null, ZipCode = null, Phone = null };
        return await (await admin.Put("/api/fiscal/settings", next)).Read<FiscalSettingsDto>();
    }

    private async Task<(SalesOrderOut Order, ProductOut Product)> NewOrderAsync(HttpClient admin, string uf, string? ncm = "73063010")
    {
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        var address = await (await admin.Post($"/api/customers/{customer.Id}/addresses", new CustomerAddressIn("26133636000103", uf, null, "148061942112", true, "Av. Brasil", "100", null, "Centro", "Embu", "3515004", "06800000", null, "Edilto", "compras@cliente.com", null))).Read<CustomerAddressOut>();
        var tube = await (await admin.Post("/api/products", Tube(Code("T"), ncm))).Read<ProductOut>();
        var term = await (await admin.Post("/api/sales/payment-terms", new PaymentTermIn(Code("P", 8), "28 DDL", "28", 1_000_000m))).Read<PaymentTermOut>();
        (await admin.Post("/api/sales/price-list", new PriceListIn(tube.Id, null, 100m, 5m, 18m, Today.AddDays(-1), null))).EnsureSuccessStatusCode();
        var order = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customer.Id, address.Id, [new SalesLineInput(tube.Id, 10m)], "PO-9", term.Id))).Read<SalesOrderOut>();
        return (order, tube);
    }

    [Fact]
    public async Task Preview_lists_what_is_missing_without_reserving_a_number_or_saving_anything()
    {
        var admin = await api.AdminAsync();
        await SetIssuer(admin, complete: false);
        var before = await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>();
        var (order, _) = await NewOrderAsync(admin, "SP");

        var nf = await (await admin.GetAsync($"/api/fiscal/preview/order/{order.Id}")).Read<NfPreview>();

        Assert.False(nf.Ready);
        Assert.Contains(nf.Problems, p => p.Blocking && p.Area == "Emitente");
        Assert.Equal("5101", nf.Cfop);
        Assert.Single(nf.Lines);
        Assert.Equal(1000m, nf.Lines[0].Total); // 10 x 100
        Assert.Single(nf.Installments);
        Assert.True(nf.Simulated); // no A1 certificate in tests
        var after = await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>();
        Assert.Equal(before.NextNumber, after.NextNumber);
        var list = await (await admin.GetAsync($"/api/fiscal/documents?q={Uri.EscapeDataString(nf.Recipient.Name)}")).Read<JsonElement>();
        Assert.Equal(0, list.GetProperty("total").GetInt32());
    }

    [Fact]
    public async Task Preview_is_ready_once_the_issuer_the_customer_and_the_product_are_complete()
    {
        var admin = await api.AdminAsync();
        await SetIssuer(admin, complete: true);
        var (order, _) = await NewOrderAsync(admin, "SP");

        var nf = await (await admin.GetAsync($"/api/fiscal/preview/order/{order.Id}")).Read<NfPreview>();

        Assert.True(nf.Ready, string.Join(" | ", nf.Problems.Where(p => p.Blocking).Select(p => p.Message)));
        Assert.Equal("Embu das Artes", nf.Issuer.City);
        Assert.True(nf.InvoiceTotal >= nf.ProductsTotal);
        Assert.All(nf.Problems, p => Assert.False(p.Blocking));
    }

    [Fact]
    public async Task Preview_flags_a_customer_in_another_state_when_the_interstate_cfop_does_not_exist()
    {
        var admin = await api.AdminAsync();
        await SetIssuer(admin, complete: true);
        var (order, _) = await NewOrderAsync(admin, "MG");

        var nf = await (await admin.GetAsync($"/api/fiscal/preview/order/{order.Id}")).Read<NfPreview>();

        Assert.Equal("6101", nf.Cfop);
        Assert.Contains(nf.Problems, p => p.Blocking && p.Area == "CFOP");
        Assert.False(nf.Ready);
    }

    private static IEnumerable<JsonElement> Items(JsonElement e) => e.ValueKind == JsonValueKind.Array ? e.EnumerateArray() : e.GetProperty("items").EnumerateArray();
    private static async Task<List<string>> CarrierNamesAsync(HttpClient c) => Items(await (await c.GetAsync("/api/fiscal/carriers?take=500")).Read<JsonElement>()).Select(x => x.GetProperty("name").GetString()!).ToList();
    private static async Task<List<string>> CfopCodesAsync(HttpClient c) => Items(await (await c.GetAsync("/api/fiscal/cfops")).Read<JsonElement>()).Select(x => x.GetProperty("code").GetString()!).ToList();

    private static async Task<HttpResponseMessage> UploadAsync(HttpClient c, object bundle, bool apply)
    {
        var form = new MultipartFormDataContent { { new ByteArrayContent(new UTF8Encoding(false).GetBytes(JsonSerializer.Serialize(bundle))), "file", "fiscal-data.json" } };
        return await c.PostAsync($"/api/fiscal/legacy-import?apply={apply.ToString().ToLowerInvariant()}", form);
    }

    [Fact]
    public async Task Import_previews_first_fills_only_what_is_empty_adds_the_missing_cfop_and_never_lowers_the_next_number()
    {
        var admin = await api.AdminAsync();
        await SetIssuer(admin, complete: false);
        var carrier = "Transportadora " + Code("X", 6);
        var bundle = new
        {
            source = "EBT",
            issuer = new { companyName = "EBT IND COM LTDA", cnpj = "26133636000103", stateRegistration = "298227696110", street = "AV X", number = "321", district = "BAIRRO", city = "EMBU", cityIbgeCode = "3515004", uf = "SP", zipCode = "06807320", nextNumber = 10 },
            cfops = new[] { new { code = "6101", description = "VENDA DE MERCADORIA", taxed = true, icmsCst = "00", ipiCst = "50", pisCst = "01", cofinsCst = "01", defaultPisPercent = 0.65m, defaultCofinsPercent = 3m, ipiFramingCode = "999", generatesInstallments = true } },
            carriers = new[] { new { name = carrier, document = "12.360.920/0001-08", stateRegistration = "147.383.315.110", address = "R X", city = "SAO PAULO", uf = "SP" } },
            taxRules = new[] { new { productCode = "NAO-EXISTE", customerCode = "999999", cfop = "5101", icmsCst = "00", icmsPercent = 18m, ipiCst = "50", ipiPercent = 3.25m, pisPercent = 0.65m, cofinsPercent = 3m } },
            monthlyPrices = Array.Empty<object>()
        };
        var next = (await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>()).NextNumber;

        var preview = await (await UploadAsync(admin, bundle, apply: false)).Read<FiscalImportResult>();
        Assert.False(preview.Applied);
        Assert.Equal(1, preview.Sections.Single(x => x.Section == "carriers").Added);
        Assert.Null((await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>()).Cnpj); // preview saved nothing
        Assert.DoesNotContain(carrier, await CarrierNamesAsync(admin));

        var done = await (await UploadAsync(admin, bundle, apply: true)).Read<FiscalImportResult>();
        Assert.True(done.Applied);
        var settings = await (await admin.GetAsync("/api/fiscal/settings")).Read<FiscalSettingsDto>();
        Assert.Equal("26133636000103", settings.Cnpj);
        Assert.Equal("EMBU", settings.City);
        Assert.False(settings.Enabled); // emission is never switched on by the import
        Assert.Equal(next, settings.NextNumber); // a lower number from the file is ignored
        Assert.Contains(carrier, await CarrierNamesAsync(admin));
        Assert.Contains("6101", await CfopCodesAsync(admin));
        var rules = done.Sections.Single(x => x.Section == "taxRules");
        Assert.Equal(1, rules.Skipped);
        Assert.Contains(rules.Notes, n => n.Contains("cliente não cadastrado") || n.Contains("produto não cadastrado"));

        var again = await (await UploadAsync(admin, bundle, apply: true)).Read<FiscalImportResult>();
        Assert.Equal(0, again.Sections.Single(x => x.Section == "carriers").Added);
        Assert.Equal(1, again.Sections.Single(x => x.Section == "carriers").Unchanged);
    }

    [Fact]
    public async Task Import_is_for_admins_and_rejects_a_file_that_is_not_the_export()
    {
        var admin = await api.AdminAsync();
        var bad = await admin.PostAsync("/api/fiscal/legacy-import?apply=false", new MultipartFormDataContent { { new ByteArrayContent(Encoding.UTF8.GetBytes("isto nao e json")), "file", "x.json" } });
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, bad.StatusCode);

        var viewer = await api.UserAsync(UserRole.Reader);
        var denied = await UploadAsync(viewer, new { source = "EBT" }, apply: false);
        Assert.Equal(System.Net.HttpStatusCode.Forbidden, denied.StatusCode);
    }
}
