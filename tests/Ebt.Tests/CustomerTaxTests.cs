using System.Text.Json;
using Ebt.Api.Endpoints;
using Ebt.Core.Entities;
using Ebt.Core.Sales;

namespace Ebt.Tests;

/// <summary>Usual IPI and ICMS of a customer: stored on the cadastro, learned from the old orders, used when the price list has none.</summary>
[Collection("api")]
public class CustomerTaxTests(ApiFixture api)
{
    private static string Code(string prefix, int length = 12) => $"{prefix}{Guid.NewGuid():N}"[..length].ToUpper();
    private static string Cnpj() => Random.Shared.NextInt64(10_000_000_000_000, 99_999_999_999_999).ToString();
    private static string Word() => new(Guid.NewGuid().ToString("N").Take(8).Select(c => (char)('a' + c % 26)).ToArray());
    private static ProductIn Tube(string code) => new(code, "Tubo " + code, ProductKind.Part, TubeShape.Circular, 25.4m, null, null, 1.5m, 1000m, null, null, "73063010", "PC", 50, false, null, null);

    private static CustomerCompany Company(string cnpj, decimal? ipi = null, decimal? icms = null, string? note = null) =>
        new(cnpj, null, false, null, null, null, null, null, "SP", null, null, null, null, IpiPercent: ipi, IcmsPercent: icms, TaxNote: note);

    [Fact]
    public async Task The_customer_keeps_its_usual_ipi_and_icms_and_rejects_nonsense()
    {
        var admin = await api.AdminAsync();
        var created = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal, Company: Company(Cnpj(), 3.25m, 18m, "ICMS: 18% (SP, 3 ped.)")))).Read<CustomerOut>();
        Assert.Equal(3.25m, created.Company!.IpiPercent);
        Assert.Equal(18m, created.Company.IcmsPercent);
        Assert.Equal("ICMS: 18% (SP, 3 ped.)", created.Company.TaxNote);

        var bad = await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal, Company: Company(Cnpj(), 120m)));
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, bad.StatusCode);
    }

    [Fact]
    public async Task An_order_line_without_a_price_list_ipi_takes_the_customers_usual_rates()
    {
        var admin = await api.AdminAsync();
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal, Company: Company(Cnpj(), 3.25m, 18m)))).Read<CustomerOut>();
        var address = await (await admin.Post($"/api/customers/{customer.Id}/addresses", new CustomerAddressIn("26133636000103", "SP", null, "148061942112", true, "Av. Brasil", "100", null, "Centro", "Embu", "3515004", "06800000", null, "Edilto", "compras@cliente.com", null))).Read<CustomerAddressOut>();
        var term = await (await admin.Post("/api/sales/payment-terms", new PaymentTermIn(Code("P", 8), "28 DDL", "28", 1_000_000m))).Read<PaymentTermOut>();
        var product = await (await admin.Post("/api/products", Tube(Code("T")))).Read<ProductOut>();
        (await admin.Post("/api/sales/price-list", new PriceListIn(product.Id, null, 100m, null, null, DateOnly.FromDateTime(DateTime.Today).AddDays(-1), null))).EnsureSuccessStatusCode();

        var order = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customer.Id, address.Id, [new SalesLineInput(product.Id, 5m)], "PO-1", term.Id))).Read<SalesOrderOut>();
        Assert.Equal(3.25m, order.Lines[0].IpiPercent);
        Assert.Equal(18m, order.Lines[0].IcmsPercent);

        // A rate typed on the line still wins.
        var typed = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customer.Id, address.Id, [new SalesLineInput(product.Id, 5m, IpiPercent: 5m, IcmsPercent: 12m)], "PO-2", term.Id))).Read<SalesOrderOut>();
        Assert.Equal(5m, typed.Lines[0].IpiPercent);
        Assert.Equal(12m, typed.Lines[0].IcmsPercent);
    }

    [Fact]
    public async Task The_old_orders_fill_the_customers_by_cnpj_then_by_name_with_the_latest_rates_and_a_note()
    {
        var admin = await api.AdminAsync();
        var cnpj = Cnpj();
        var byCnpj = await (await admin.Post("/api/customers", new CustomerIn("Metalurgica " + Code("A", 8), null, null, ConsumerType.Normal, Company: Company(cnpj)))).Read<CustomerOut>();
        var word = Word();
        var byName = await (await admin.Post("/api/customers", new CustomerIn($"{word} Pecas Ltda", word, null, ConsumerType.Normal))).Read<CustomerOut>();
        var ambiguous = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal))).Read<CustomerOut>();

        var rows = new List<TaxOrderRow>
        {
            new("00010-24", new DateOnly(2024, 3, 1), "Nome diferente no pedido", cnpj, "SP", 18m, 5m),
            new("00011-25", new DateOnly(2025, 6, 1), "Nome diferente no pedido", cnpj, "S.P", 18m, 3.25m),
            new("00002-25", null, "Nome diferente no pedido", cnpj, "RS", 12m, 3.25m),   // undated: January of 2025, before the June one
            new("00005-23", null, $"{word.ToUpper()} PEÇAS DIESEL", null, "SP", 18m, 5m),
            new("00006-99", null, $"{word.ToUpper()} PEÇAS DIESEL", null, "SP", 7m, 9m),  // year 2099: a typo, never "the latest"
            new("00007-25", null, "Sem imposto", cnpj, "SP", null, null),
            new("00001-25", null, "Ninguém tem este nome", "00000000000191", "SP", 18m, 5m),
        };

        var preview = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, rows))).Read<CustomerTaxResult>();
        Assert.Equal(2, preview.Matches.Count);
        Assert.All(preview.Matches, m => Assert.False(m.Applied));
        Assert.Contains("Ninguém tem este nome", preview.Unmatched);
        Assert.Equal(2, preview.Skipped); // the 2099 order and the one without taxes

        var applied = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows))).Read<CustomerTaxResult>();
        var a = applied.Matches.Single(m => m.CustomerId == byCnpj.Id);
        Assert.Equal("CNPJ", a.MatchedBy);
        Assert.Equal(3.25m, a.Ipi); // the June 2025 order is the latest
        Assert.Equal(18m, a.Icms);
        Assert.Contains("12% (RS, 1 ped.)", a.Note);
        Assert.Contains("18% (SP, 2 ped.)", a.Note);
        Assert.Contains("5% (1)", a.Note);
        var n = applied.Matches.Single(m => m.CustomerId == byName.Id);
        Assert.Equal("nome", n.MatchedBy);
        Assert.Equal(5m, n.Ipi);

        var read = await (await admin.GetAsync($"/api/customers/{byCnpj.Id}")).Read<CustomerOut>();
        Assert.Equal(3.25m, read.Company!.IpiPercent);
        Assert.Equal(18m, read.Company.IcmsPercent);
        Assert.Contains("Pedidos internos 2024-2025", read.Company.TaxNote);
        Assert.DoesNotContain(applied.Matches, m => m.CustomerId == ambiguous.Id);

        // A second run keeps what is there unless asked to overwrite.
        var again = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows))).Read<CustomerTaxResult>();
        Assert.All(again.Matches, m => Assert.False(m.Applied));
        var over = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, true, rows))).Read<CustomerTaxResult>();
        Assert.All(over.Matches, m => Assert.True(m.Applied));
    }

    [Fact]
    public async Task Only_an_admin_may_import_and_an_empty_file_is_refused()
    {
        var admin = await api.AdminAsync();
        var empty = await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, []));
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, empty.StatusCode);
        var anon = api.Anonymous();
        var body = new CustomerTaxImportIn(false, false, [new("1-25", null, "x", null, null, 18m, 5m)]);
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, (await anon.Post("/api/customers/tax-import", body)).StatusCode);
        Assert.Equal(System.Net.HttpStatusCode.Forbidden, (await (await api.UserAsync(UserRole.Sales)).Post("/api/customers/tax-import", body)).StatusCode);
    }
}
