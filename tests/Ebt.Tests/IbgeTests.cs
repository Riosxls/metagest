using System.Net;
using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Ebt.Core.Fiscal;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Ebt.Tests;

/// <summary>The built-in IBGE municipality table, the code filled from city and state on save, and the batch fill of existing addresses.</summary>
[Collection("api")]
public class IbgeTests(ApiFixture api)
{
    private static string Tag() => Guid.NewGuid().ToString("N")[..8].ToUpper();
    private static int nextRoot = 70_000_000 + Environment.TickCount % 10_000_000;
    private static string Cnpj() => $"{Interlocked.Increment(ref nextRoot):00000000}000100";

    [Fact]
    public void The_table_holds_every_municipality_and_matches_by_name_and_state()
    {
        Assert.True(IbgeMunicipalities.Count >= 5500);
        Assert.Equal("3527306", IbgeMunicipalities.Find("Louveira", "SP"));
        Assert.Equal("3550308", IbgeMunicipalities.Find("São Paulo", "SP"));
        Assert.Equal("3550308", IbgeMunicipalities.Find("SAO PAULO", "SP"));
        // The little words and the usual abbreviations do not matter.
        Assert.Equal("3547809", IbgeMunicipalities.Find("Sto. André", "SP"));
        Assert.Equal("3547809", IbgeMunicipalities.Find("SANTO ANDRE", "SP"));
        Assert.Equal("1100015", IbgeMunicipalities.Find("Alta Floresta D'Oeste", "RO"));
        // The same name in another state is another city, and an unknown name matches nothing.
        Assert.NotEqual(IbgeMunicipalities.Find("Bom Jesus", "RS"), IbgeMunicipalities.Find("Bom Jesus", "PB"));
        Assert.Null(IbgeMunicipalities.Find("Cidade Que Nao Existe", "SP"));
        Assert.Null(IbgeMunicipalities.Find("Louveira", null));
        Assert.Null(IbgeMunicipalities.Find(null, "SP"));
    }

    [Fact]
    public async Task The_lookup_endpoint_answers_the_code_or_404()
    {
        var admin = await api.AdminAsync();
        var ok = await admin.GetAsync("/api/fiscal/ibge?city=Louveira&uf=SP");
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
        Assert.Contains("3527306", await ok.Content.ReadAsStringAsync());
        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync("/api/fiscal/ibge?city=Nada&uf=SP")).StatusCode);
    }

    private static CustomerAddressIn Address(string city, string uf, string? ibge = null) =>
        new(Cnpj(), uf, null, null, false, "Rua A", "1", null, "Centro", city, ibge, "13290000", null, null, null, null);

    [Fact]
    public async Task Saving_an_address_fills_the_code_from_city_and_state_without_overwriting_a_typed_one()
    {
        var admin = await api.AdminAsync();
        var c = await (await admin.Post("/api/customers", new CustomerIn("Ibge " + Tag(), null, null, ConsumerType.Normal))).Read<CustomerOut>();

        var filled = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Louveira", "SP"))).Read<CustomerAddressOut>();
        Assert.Equal("3527306", filled.CityIbgeCode);

        var typed = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Louveira", "SP", "1234567"))).Read<CustomerAddressOut>();
        Assert.Equal("1234567", typed.CityIbgeCode);

        // An older client that does not send the code keeps the stored one while the city is the same.
        var again = await (await admin.Put($"/api/customers/{c.Id}/addresses/{typed.Id}", Address("Louveira", "SP") with { Document = typed.Document })).Read<CustomerAddressOut>();
        Assert.Equal("1234567", again.CityIbgeCode);

        // A city that matches nothing stays empty, and a malformed code is refused.
        var unknown = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Cidade Inventada", "SP"))).Read<CustomerAddressOut>();
        Assert.Null(unknown.CityIbgeCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Louveira", "SP", "12"))).StatusCode);
    }

    [Fact]
    public async Task The_company_block_has_its_own_code_filled_from_the_city()
    {
        var admin = await api.AdminAsync();
        var company = new CustomerCompany(Cnpj(), null, false, "Rua B", "2", null, "Centro", "Louveira", "SP", "13290000", null, null, null);
        var c = await (await admin.Post("/api/customers", new CustomerIn("Empresa " + Tag(), null, null, ConsumerType.Normal, Company: company))).Read<CustomerOut>();
        Assert.Equal("3527306", c.Company!.CityIbgeCode);
        var typed = await (await admin.Put($"/api/customers/{c.Id}", new CustomerIn(c.Name, null, null, ConsumerType.Normal, Company: company with { CityIbgeCode = "7654321" }))).Read<CustomerOut>();
        Assert.Equal("7654321", typed.Company!.CityIbgeCode);
    }

    [Fact]
    public async Task The_batch_fill_previews_then_fills_only_the_empty_codes_and_never_changes_a_valid_one()
    {
        var admin = await api.AdminAsync();
        var sales = await api.UserAsync(UserRole.Sales);
        var c = await (await admin.Post("/api/customers", new CustomerIn("Lote " + Tag(), null, null, ConsumerType.Normal))).Read<CustomerOut>();
        var a1 = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Louveira", "SP"))).Read<CustomerAddressOut>();
        var a2 = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Santo André", "SP", "9999999"))).Read<CustomerAddressOut>();
        var a3 = await (await admin.Post($"/api/customers/{c.Id}/addresses", Address("Cidade Inventada", "SP"))).Read<CustomerAddressOut>();
        using (var scope = api.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<EbtDbContext>();
            (await db.CustomerAddresses.FindAsync(a1.Id))!.CityIbgeCode = null; // as the addresses saved before the code existed
            await db.SaveChangesAsync();
        }

        Assert.Equal(HttpStatusCode.Forbidden, (await sales.Post("/api/fiscal/ibge/fill", new { })).StatusCode);

        var preview = await (await admin.Post("/api/fiscal/ibge/fill", new { })).Read<IbgeFillResult>();
        Assert.False(preview.Applied);
        Assert.True(preview.Filled >= 1);
        Assert.Contains(preview.Missing, m => m.OwnerId == c.Id && m.City == "Cidade Inventada");
        using (var scope = api.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<EbtDbContext>();
            Assert.Null((await db.CustomerAddresses.AsNoTracking().FirstAsync(a => a.Id == a1.Id)).CityIbgeCode);
        }

        var applied = await (await admin.Post("/api/fiscal/ibge/fill?apply=true", new { })).Read<IbgeFillResult>();
        Assert.True(applied.Applied);
        using (var scope = api.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<EbtDbContext>();
            Assert.Equal("3527306", (await db.CustomerAddresses.AsNoTracking().FirstAsync(a => a.Id == a1.Id)).CityIbgeCode);
            Assert.Equal("9999999", (await db.CustomerAddresses.AsNoTracking().FirstAsync(a => a.Id == a2.Id)).CityIbgeCode);
            Assert.Null((await db.CustomerAddresses.AsNoTracking().FirstAsync(a => a.Id == a3.Id)).CityIbgeCode);
        }
        // Nothing left to fill the second time.
        var second = await (await admin.Post("/api/fiscal/ibge/fill?apply=true", new { })).Read<IbgeFillResult>();
        Assert.Equal(0, second.Filled);
    }
}
