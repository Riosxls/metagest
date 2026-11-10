using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;
using Ebt.Core.Entities;

namespace Ebt.Tests;

/// <summary>The search boxes read tube sizes as numbers and ignore accents and case, whatever way the old system typed the name.</summary>
[Collection("api")]
public class SmartSearchTests(ApiFixture api)
{
    private static string Letters(int n = 8) => new(Guid.NewGuid().ToString("N").Take(n).Select(c => (char)('a' + c % 26)).ToArray());

    private static ProductIn Tube(string code, string name, decimal od, decimal wall, decimal length) =>
        new(code, name, ProductKind.Part, TubeShape.Circular, od, null, null, wall, length, null, null, "73063010", "PC", 50, false, null, null);

    private static async Task<List<string>> Names(HttpClient admin, string path, string q)
    {
        var page = await (await admin.GetAsync($"{path}?q={Uri.EscapeDataString(q)}&take=100")).Read<Page<System.Text.Json.JsonElement>>();
        return page.Items.Select(i => i.GetProperty(path.Contains("products") ? "code" : "name").GetString()!).ToList();
    }

    [Fact]
    public async Task Tubes_are_found_by_their_sizes_however_the_name_was_typed()
    {
        var admin = await api.AdminAsync();
        var tag = Letters(6).ToUpper();
        // Odd sizes nobody else uses, so the assertions are about these three only.
        var a = await (await admin.Post("/api/products", Tube($"{tag}.1", $"TUBO-C 71,30 X 0,90 X 6000 MM {tag}", 71.3m, 0.9m, 6000m))).Read<ProductOut>();
        var b = await (await admin.Post("/api/products", Tube($"{tag}.2", $"TUBO-C 71,30 X 1,25 X ROLO {tag}", 71.3m, 1.25m, 1000m))).Read<ProductOut>();
        var c = await (await admin.Post("/api/products", Tube($"{tag}.3", $"TUBO-C 72,00 X 0,90 X 6000MM {tag}", 72m, 0.9m, 6000m))).Read<ProductOut>();

        async Task<HashSet<string>> Find(string q) => (await Names(admin, "/api/products", q)).Where(x => x.StartsWith(tag)).ToHashSet();

        Assert.Equal([a.Code, b.Code], await Find($"71,3 {tag}"));
        Assert.Equal([a.Code, b.Code], await Find($"71.3 {tag}"));
        Assert.Equal([a.Code], await Find($"71,3 x 0,9 {tag}"));
        Assert.Equal([a.Code], await Find("71,3x0,9x6000"));
        Assert.Equal([a.Code], await Find("Ø71,3 X 0,90 X 6000 MM"));
        Assert.Equal([b.Code], await Find("71,3 x 1,25"));
        Assert.Equal([a.Code, c.Code], await Find($"0,9 6000 {tag}"));
        Assert.Equal([c.Code], await Find($"72 0,9 {tag.ToLower()}"));
        Assert.Empty(await Find("71,3 x 5"));
        Assert.Equal([a.Code, b.Code, c.Code], await Find(tag));
        // Words match in any order, without caring for case.
        Assert.Equal([b.Code], await Find($"rolo {tag.ToLower()}"));
    }

    [Fact]
    public async Task Customers_are_found_by_any_words_of_the_name_without_accents_and_by_document_or_city()
    {
        var admin = await api.AdminAsync();
        var word = Letters();
        var doc = Random.Shared.NextInt64(10_000_000_000_000, 99_999_999_999_999).ToString();
        var created = await (await admin.Post("/api/customers", new CustomerIn($"Metalúrgica {word} Indústria Ltda", null, null, ConsumerType.Normal,
            Company: new CustomerCompany(doc, null, false, null, null, null, null, "Ribeirão Pires", "SP", null, null, null, null)))).Read<CustomerOut>();

        async Task<bool> Hit(string q) => (await Names(admin, "/api/customers", q)).Contains(created.Name);

        Assert.True(await Hit($"metalurgica {word}"));
        Assert.True(await Hit($"{word.ToUpper()} industria"));
        Assert.True(await Hit($"{word} ribeirao"));
        Assert.True(await Hit(doc[..8]));
        Assert.True(await Hit($"{doc[..2]}.{doc.Substring(2, 3)}.{doc.Substring(5, 3)}/{doc.Substring(8, 4)}"));
        Assert.False(await Hit($"{word} campinas"));
        Assert.False(await Hit($"{word}zz"));
    }
}
