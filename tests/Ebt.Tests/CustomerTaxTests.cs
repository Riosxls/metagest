using System.Text.Json;
using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;
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

    [Fact]
    public async Task Customers_on_the_orders_but_not_in_the_cadastro_are_registered_with_the_data_of_their_latest_order()
    {
        var admin = await api.AdminAsync();
        var word = Word();
        var cnpj = Cnpj();
        var known = await (await admin.Post("/api/customers", new CustomerIn("Ja Cadastrada " + Code("K", 8), null, null, ConsumerType.Normal, Company: Company(Cnpj())))).Read<CustomerOut>();
        var rows = new List<TaxOrderRow>
        {
            new("00001-24", new DateOnly(2024, 1, 5), $"{word.ToUpper()} COMERCIAL LTDA", cnpj, "SP", 18m, 5m, "RUA ANTIGA, 10", "CENTRO", "SAO PAULO", "01000-000", "111.222.333.444", "SR. ANTIGO", "(11) 1111-1111", "antigo@x.com", "30 DDL"),
            new("00002-26", new DateOnly(2026, 3, 1), $"{word.ToUpper()} COMERCIAL LTDA", cnpj, "SP", 18m, 3.25m, "RUA ARISUGAWA,153", "JD JAPAO", "SAO PAULO", "03228 - 000", "115.467.772.113", "SR.ANTONIO", "(11) 2982 - 5522", "Antonio@Jetro.com.br", "30/45/60 DDL"),
            new("00003-26", null, $"Sem Cnpj {word}", null, "RS", 12m, 3.25m),
        };

        var preview = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, rows, true))).Read<CustomerTaxResult>();
        Assert.Equal(2, preview.Created!.Count);
        Assert.Empty((await (await admin.GetAsync($"/api/customers?q={word}")).Read<Page<System.Text.Json.JsonElement>>()).Items);

        var applied = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows, true))).Read<CustomerTaxResult>();
        Assert.Equal(2, applied.Created!.Count);
        Assert.Equal(2, applied.Matches.Count); // the new customers also get their rates
        var page = await (await admin.GetAsync($"/api/customers?q={word}")).Read<Page<System.Text.Json.JsonElement>>();
        Assert.Equal(2, page.Items.Count);
        var company = page.Items.Single(i => i.GetProperty("name").GetString()!.Contains("Comercial", StringComparison.OrdinalIgnoreCase));
        var read = await (await admin.GetAsync($"/api/customers/{company.GetProperty("id").GetInt32()}")).Read<CustomerOut>();
        Assert.EndsWith("Comercial Ltda", read.Name);
        Assert.Equal(cnpj, read.Company!.Document);
        Assert.Equal("Rua Arisugawa", read.Company.Street);
        Assert.Equal("153", read.Company.Number);
        Assert.Equal("Jd Japao", read.Company.District);
        Assert.Equal("Sao Paulo", read.Company.City);
        Assert.Equal("SP", read.Company.Uf);
        Assert.Equal("03228000", read.Company.ZipCode);
        Assert.Equal("115.467.772.113", read.Company.StateRegistration);
        Assert.True(read.Company.IcmsContributor);
        Assert.Equal("antonio@jetro.com.br", read.Company.Email);
        Assert.Equal(3.25m, read.Company.IpiPercent); // from the latest order

        // A second run finds them by CNPJ and name: nothing is created twice.
        var again = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows, true))).Read<CustomerTaxResult>();
        Assert.Empty(again.Created!);
        Assert.Equal(2, (await (await admin.GetAsync($"/api/customers?q={word}")).Read<Page<System.Text.Json.JsonElement>>()).Items.Count);
        Assert.NotEqual(0, known.Id);
    }

    [Fact]
    public async Task Missing_contact_data_is_completed_and_the_usual_material_of_a_product_is_learned_from_the_old_orders()
    {
        var admin = await api.AdminAsync();
        var cnpj = Cnpj();
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Contato " + Code("C", 8), null, null, ConsumerType.Normal, Company: Company(cnpj)))).Read<CustomerOut>();
        var product = await (await admin.Post("/api/products", Tube(Code("M")))).Read<ProductOut>();
        var rows = new List<TaxOrderRow>
        {
            new("00001-25", new DateOnly(2025, 1, 5), "Nome no pedido", cnpj, "SP", 18m, 5m, Contact: "SR. ANTIGO", Material: "BK DIN 2391", ProductCode: product.Code),
            new("00002-26", new DateOnly(2026, 2, 5), "Nome no pedido", cnpj, "SP", 18m, 3.25m, Contact: "SR. NOVO", Phone: "(11) 2982-5522", Email: "Novo@X.com", StateRegistration: "115.467.772.113", Material: "BK DIN 2393", ProductCode: product.Code),
            new("00003-26", new DateOnly(2026, 2, 6), "Nome no pedido", cnpj, "SP", 18m, 3.25m, Material: "TUBO-C 08,00 X 0,90 X 6000 MM", ProductCode: product.Code),
        };

        var preview = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, rows))).Read<CustomerTaxResult>();
        Assert.Equal(1, preview.ContactsFilled);
        Assert.Equal(1, preview.Materials);
        Assert.Null((await (await admin.GetAsync($"/api/sales/material-suggestion?customerId={customer.Id}&productId={product.Id}")).Read<System.Text.Json.JsonElement>()).GetProperty("material").GetString());

        await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows));
        var read = await (await admin.GetAsync($"/api/customers/{customer.Id}")).Read<CustomerOut>();
        Assert.Equal("Sr. Novo", read.Company!.Contact);
        Assert.Equal("(11) 2982-5522", read.Company.Phone);
        Assert.Equal("novo@x.com", read.Company.Email);
        Assert.Equal("115.467.772.113", read.Company.StateRegistration);
        Assert.True(read.Company.IcmsContributor);
        var material = await (await admin.GetAsync($"/api/sales/material-suggestion?customerId={customer.Id}&productId={product.Id}")).Read<System.Text.Json.JsonElement>();
        Assert.Equal("BK DIN 2393", material.GetProperty("material").GetString()); // the latest order; the tube name is never a material

        // Another customer of the same product falls back to what most orders said.
        var other = await (await admin.Post("/api/customers", new CustomerIn("Outro " + Code("C", 8), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        var fallback = await (await admin.GetAsync($"/api/sales/material-suggestion?customerId={other.Id}&productId={product.Id}")).Read<System.Text.Json.JsonElement>();
        Assert.Equal("BK DIN 2393", fallback.GetProperty("material").GetString());

        // Contact data already in the cadastro is never replaced.
        var again = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, true, rows))).Read<CustomerTaxResult>();
        Assert.Equal(0, again.ContactsFilled);
    }

    [Fact]
    public async Task The_latest_order_corrects_the_ie_adds_a_different_delivery_address_and_makes_the_customer_and_item_known()
    {
        var admin = await api.AdminAsync();
        var cnpj = Cnpj();
        var company = new CustomerCompany(cnpj, "112470391112", true, "Rua Padre Isidoro", "182", null, "Vila Nova York", "São Paulo", "SP", "03479020", null, null, null);
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Entrega " + Code("C", 8), null, null, ConsumerType.Normal, Company: company))).Read<CustomerOut>();
        var product = await (await admin.Post("/api/products", Tube(Code("N")))).Read<ProductOut>();
        string NoveltyUrl() => $"/api/sales/customers/{customer.Id}/novelty?productId={product.Id}";
        var before = await (await admin.GetAsync(NoveltyUrl())).Read<System.Text.Json.JsonElement>();
        Assert.True(before.GetProperty("customerNew").GetBoolean());
        Assert.True(before.GetProperty("itemNew").GetBoolean());

        var rows = new List<TaxOrderRow>
        {
            new("00001-26", new DateOnly(2026, 3, 1), "Entrega", cnpj, "SP", 18m, 3.25m, StateRegistration: "112.970.351.112", ProductCode: product.Code,
                DeliveryAddress: "Rua Lateral,810 Vila Nova York São Paulo-SP 03479-020"),
            new("00002-26", new DateOnly(2026, 3, 2), "Entrega", cnpj, "SP", 18m, 3.25m, StateRegistration: "112.970.351.112", ProductCode: "OUTRO", DeliveryAddress: "Rua Padre Isidoro, 182 Vila Nova York São Paulo-SP 03479-020"),
        };
        var preview = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, rows))).Read<CustomerTaxResult>();
        Assert.Single(preview.IeCorrected!);
        Assert.Single(preview.DeliveryAddresses!);

        var applied = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows))).Read<CustomerTaxResult>();
        Assert.Single(applied.IeCorrected!);
        var read = await (await admin.GetAsync($"/api/customers/{customer.Id}")).Read<CustomerOut>();
        Assert.Equal("112.970.351.112", read.Company!.StateRegistration);
        var addresses = await (await admin.GetAsync($"/api/customers/{customer.Id}/addresses")).Read<List<CustomerAddressOut>>();
        var delivery = Assert.Single(addresses);
        Assert.Equal("Rua Lateral", delivery.Street);
        Assert.Equal("810", delivery.Number);
        Assert.Equal("03479020", delivery.ZipCode);
        Assert.Equal("São Paulo", delivery.City);
        Assert.Equal("Vila Nova York", delivery.District);

        var after = await (await admin.GetAsync(NoveltyUrl())).Read<System.Text.Json.JsonElement>();
        Assert.False(after.GetProperty("customerNew").GetBoolean());
        Assert.False(after.GetProperty("itemNew").GetBoolean()); // the same product code was on an old order

        // A second run adds nothing.
        var again = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, true, rows))).Read<CustomerTaxResult>();
        Assert.Empty(again.DeliveryAddresses!);
        Assert.Empty(again.IeCorrected!);
    }

    [Fact]
    public async Task A_customer_without_a_delivery_address_delivers_to_its_main_address()
    {
        var admin = await api.AdminAsync();
        var company = new CustomerCompany(Cnpj(), "112470391112", true, "Rua Padre Isidoro", "182", null, "Vila Nova York", "São Paulo", "SP", "03479020", "Adelaide", "a@x.com", "1135151910");
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Principal " + Code("C", 8), null, null, ConsumerType.Normal, Company: company))).Read<CustomerOut>();
        var first = await (await admin.PostAsync($"/api/customers/{customer.Id}/addresses/from-main", null)).Read<List<CustomerAddressOut>>();
        var copy = Assert.Single(first);
        Assert.Equal("Rua Padre Isidoro", copy.Street);
        Assert.Equal("182", copy.Number);
        Assert.Equal("Adelaide", copy.Buyer);
        // Asking again adds nothing; a customer that already has a delivery address is left alone.
        Assert.Single(await (await admin.PostAsync($"/api/customers/{customer.Id}/addresses/from-main", null)).Read<List<CustomerAddressOut>>());
        var bare = await (await admin.Post("/api/customers", new CustomerIn("Sem endereco " + Code("C", 8), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        Assert.Empty(await (await admin.PostAsync($"/api/customers/{bare.Id}/addresses/from-main", null)).Read<List<CustomerAddressOut>>());
    }

    [Fact]
    public async Task The_observation_a_customer_always_puts_on_a_product_is_learned_without_the_purchase_order_number()
    {
        var admin = await api.AdminAsync();
        var cnpj = Cnpj();
        var company = new CustomerCompany(cnpj, "112470391112", true, "Rua Padre Isidoro", "182", null, "Vila Nova York", "São Paulo", "SP", "03479020", null, null, null);
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Obs " + Code("C", 8), null, null, ConsumerType.Normal, Company: company))).Read<CustomerOut>();
        var code = $"{Random.Shared.Next(100, 999)}.{Random.Shared.Next(100, 999)}.{Random.Shared.Next(10, 99)}";
        var product = await (await admin.Post("/api/products", Tube(code))).Read<ProductOut>();
        var other = await (await admin.Post("/api/products", Tube(Code("O")))).Read<ProductOut>();
        var rows = new List<TaxOrderRow>
        {
            new("00001-26", new DateOnly(2026, 3, 1), "Obs", cnpj, "SP", 18m, 3.25m, ProductCode: code, Notes: "PEDIDO O.C 3166 || O.C 3166  ISENTO DE OLEO E GRAXA"),
            new("00002-26", new DateOnly(2026, 3, 2), "Obs", cnpj, "SP", 18m, 3.25m, ProductCode: code, Notes: "PEDIDO Nº 3.170 || ISENTO DE ÓLEO E GRAXA || Horário de recebimento até as 16:00 hs"),
            new("00003-26", new DateOnly(2026, 3, 3), "Obs", cnpj, "SP", 18m, 3.25m, ProductCode: code, Notes: "PEDIDO VERBAL"),
        };
        var preview = await (await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(false, false, rows))).Read<CustomerTaxResult>();
        Assert.Equal(1, preview.NotesLearned);
        await admin.Post("/api/customers/tax-import", new CustomerTaxImportIn(true, false, rows));
        var suggestion = await (await admin.GetAsync($"/api/sales/material-suggestion?customerId={customer.Id}&productId={product.Id}")).Read<System.Text.Json.JsonElement>();
        Assert.Contains("ISENTO DE", suggestion.GetProperty("note").GetString()!, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("3166", suggestion.GetProperty("note").GetString()!);
        Assert.DoesNotContain("16:00", suggestion.GetProperty("note").GetString()!);
        // Another product of the customer, which no order mentioned, gets none.
        var none = await (await admin.GetAsync($"/api/sales/material-suggestion?customerId={customer.Id}&productId={other.Id}")).Read<System.Text.Json.JsonElement>();
        Assert.Equal(System.Text.Json.JsonValueKind.Null, none.GetProperty("note").ValueKind);
    }
}
