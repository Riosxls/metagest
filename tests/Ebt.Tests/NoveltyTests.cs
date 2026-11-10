using System.Text.Json;
using Ebt.Api.Endpoints;
using Ebt.Core.Entities;
using Ebt.Core.Sales;

namespace Ebt.Tests;

/// <summary>"Cliente novo / item novo" boxes of the pedido interno and the OF.</summary>
[Collection("api")]
public class NoveltyTests(ApiFixture api)
{
    private static string Code(string prefix, int length = 12) => $"{prefix}{Guid.NewGuid():N}"[..length].ToUpper();
    private static ProductIn Tube(string code) => new(code, "Tubo " + code, ProductKind.Part, TubeShape.Circular, 25.4m, null, null, 1.5m, 1000m, null, null, "73063010", "PC", 50, false, null, null);

    private async Task<(int CustomerId, int AddressId, int TermId)> NewCustomerAsync(HttpClient admin)
    {
        var customer = await (await admin.Post("/api/customers", new CustomerIn("Cliente " + Code("C"), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        var address = await (await admin.Post($"/api/customers/{customer.Id}/addresses", new CustomerAddressIn("26133636000103", "SP", null, "148061942112", true, "Av. Brasil", "100", null, "Centro", "Embu", "3515004", "06800000", null, "Edilto", "compras@cliente.com", null))).Read<CustomerAddressOut>();
        var term = await (await admin.Post("/api/sales/payment-terms", new PaymentTermIn(Code("P", 8), "28 DDL", "28", 1_000_000m))).Read<PaymentTermOut>();
        return (customer.Id, address.Id, term.Id);
    }

    private static async Task<(bool CustomerNew, bool ItemNew)> NoveltyAsync(HttpClient admin, int customerId, int productId, int exceptOrderId)
    {
        var json = await (await admin.GetAsync($"/api/sales/customers/{customerId}/novelty?productId={productId}&exceptOrderId={exceptOrderId}")).Content.ReadAsStringAsync();
        var doc = JsonDocument.Parse(json).RootElement;
        return (doc.GetProperty("customerNew").GetBoolean(), doc.GetProperty("itemNew").GetBoolean());
    }

    [Fact]
    public async Task First_order_is_new_the_next_one_of_the_same_product_is_already_supplied()
    {
        var admin = await api.AdminAsync();
        var (customerId, addressId, termId) = await NewCustomerAsync(admin);
        var a = await (await admin.Post("/api/products", Tube(Code("T")))).Read<ProductOut>();
        var b = await (await admin.Post("/api/products", Tube(Code("T")))).Read<ProductOut>();
        (await admin.Post("/api/sales/price-list", new PriceListIn(a.Id, null, 100m, 0m, 0m, DateOnly.FromDateTime(DateTime.Today).AddDays(-1), null))).EnsureSuccessStatusCode();
        (await admin.Post("/api/sales/price-list", new PriceListIn(b.Id, null, 100m, 0m, 0m, DateOnly.FromDateTime(DateTime.Today).AddDays(-1), null))).EnsureSuccessStatusCode();

        var first = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customerId, addressId, [new SalesLineInput(a.Id, 5m)], "PO-1", termId))).Read<SalesOrderOut>();
        Assert.Equal((true, true), await NoveltyAsync(admin, customerId, a.Id, first.Id));

        var second = await (await admin.Post("/api/sales/orders", new SalesOrderIn(customerId, addressId, [new SalesLineInput(a.Id, 5m), new SalesLineInput(b.Id, 5m)], "PO-2", termId))).Read<SalesOrderOut>();
        Assert.Equal((false, false), await NoveltyAsync(admin, customerId, a.Id, second.Id)); // known customer, product already supplied
        Assert.Equal((false, true), await NoveltyAsync(admin, customerId, b.Id, second.Id)); // known customer, new product
        Assert.Equal((true, true), await NoveltyAsync(admin, customerId, a.Id, first.Id)); // the first order is still the first one
    }
}
