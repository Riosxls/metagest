using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;

namespace Ebt.Tests;

/// <summary>The supplier list is a contact list: it carries the CNPJ, city, e-mail and phone of the default address.</summary>
[Collection("api")]
public class SupplierListTests(ApiFixture api)
{
    [Fact]
    public async Task The_list_carries_the_contact_data_of_the_default_address()
    {
        var admin = await api.AdminAsync();
        var name = "Contato " + Guid.NewGuid().ToString("N")[..8];
        var supplier = await (await admin.Post("/api/suppliers", new SupplierIn(name, null, null, null))).Read<SupplierOut>();
        Assert.Null(supplier.Email);
        (await admin.Post($"/api/suppliers/{supplier.Id}/addresses", new SupplierAddressIn("SP", "04252011000110", null, null, "Rua do Forno", "5", "Jardim", "São Paulo", null, "01001000", "vendas@forno.com.br", "1155550000"))).EnsureSuccessStatusCode();
        var page = await (await admin.GetAsync($"/api/suppliers?q={name}")).Read<Page<SupplierOut>>();
        var row = Assert.Single(page.Items);
        Assert.Equal("04252011000110", row.Document);
        Assert.Equal("São Paulo", row.City);
        Assert.Equal("SP", row.Uf);
        Assert.Equal("vendas@forno.com.br", row.Email);
        Assert.Equal("1155550000", row.Phone);
    }
}
