using System.Net;
using Ebt.Api.Endpoints;
using Ebt.Api.Infrastructure;
using Ebt.Core.Duplicates;
using Ebt.Core.Entities;

namespace Ebt.Tests;

/// <summary>Duplicate detection of customers, products and suppliers: the matching rules, the "not a duplicate" mark and who may set it.</summary>
[Collection("api")]
public class DuplicateTests(ApiFixture api)
{
    private static string Tag() => Guid.NewGuid().ToString("N")[..8].ToUpper();

    /// <summary>A CNPJ with a unique root so no other test's customer shares it.</summary>
    private static string Cnpj(int root, int branch = 1) => $"{root:00000000}{branch:0000}00";

    private static int nextRoot = 50_000_000 + Environment.TickCount % 10_000_000;
    private static int NewRoot() => Interlocked.Increment(ref nextRoot);

    private static async Task<CustomerOut> Customer(HttpClient c, string name, string? trade = null, string? document = null, string? legacy = null) =>
        await (await c.Post("/api/customers", new CustomerIn(name, trade, legacy, ConsumerType.Normal, Company: document == null ? null : new CustomerCompany(document, null, false, null, null, null, null, "Embu", "SP", null, null, null, null)))).Read<CustomerOut>();

    private static async Task<ProductOut> Product(HttpClient c, string code, string name, decimal d, decimal t, decimal l) =>
        await (await c.Post("/api/products", new ProductIn(code, name, ProductKind.Part, TubeShape.Circular, d, null, null, t, l, null, null, "73063010", "PC", null, false, null, null))).Read<ProductOut>();

    private static Task<RecordDuplicatesOut> ForRecord(HttpClient c, string plural, int id) => c.GetAsync($"/api/{plural}/{id}/duplicates").ContinueWith(t => t.Result.Read<RecordDuplicatesOut>()).Unwrap();

    [Theory]
    [InlineData("Aços Brasil Indústria LTDA", "ACOS BRASIL INDUSTRIA")]
    [InlineData("Metalúrgica Silva S.A.", "METALURGICA SILVA")]
    [InlineData("Metalúrgica  Silva S/A", "METALURGICA SILVA")]
    [InlineData("Comércio de Tubos - ME", "COMERCIO TUBOS")]
    [InlineData("  ", "")]
    public void Name_key_drops_case_accents_punctuation_and_legal_suffixes(string input, string expected) => Assert.Equal(expected, DuplicateService.NameKey(input));

    [Fact]
    public void Digits_and_code_keys_ignore_punctuation()
    {
        Assert.Equal("11222333000181", DuplicateService.Digits("11.222.333/0001-81"));
        Assert.Equal("", DuplicateService.Digits(null));
        Assert.Equal("0600751", DuplicateService.CodeKey("060.075.1"));
        Assert.Equal("T1", DuplicateService.CodeKey("t-1"));
    }

    [Fact]
    public async Task Customers_with_the_same_cnpj_or_name_are_flagged_with_the_reason_and_each_page_sees_the_other()
    {
        var admin = await api.AdminAsync();
        var tag = Tag();
        var root = NewRoot();
        var a = await Customer(admin, $"Tubos {tag} Ltda", document: Cnpj(root));
        var b = await Customer(admin, $"TUBOS {tag} S.A.", "Tubos Rapidos", Cnpj(root)[..2] + "." + Cnpj(root)[2..5] + "." + Cnpj(root)[5..8] + "/" + Cnpj(root)[8..12] + "-" + Cnpj(root)[12..]);
        var other = await Customer(admin, "Outro cliente " + Tag());

        var mine = await ForRecord(admin, "customers", a.Id);
        var m = Assert.Single(mine.Matches);
        Assert.Equal(a.Id, m.A.Id);
        Assert.Equal(b.Id, m.B.Id);
        Assert.Equal(100, m.Score); // document 100, name 90: capped
        Assert.Contains(m.Reasons, r => r.Code == "document");
        Assert.Contains(m.Reasons, r => r.Code == "name");
        // Seen from the other side the pair is the same, with the record itself first.
        var theirs = Assert.Single((await ForRecord(admin, "customers", b.Id)).Matches);
        Assert.Equal(b.Id, theirs.A.Id);
        Assert.Equal(a.Id, theirs.B.Id);
        Assert.Empty((await ForRecord(admin, "customers", other.Id)).Matches);
    }

    [Fact]
    public async Task Same_cnpj_root_with_a_different_branch_is_a_weak_match_and_a_contained_name_is_found()
    {
        var admin = await api.AdminAsync();
        var tag = Tag();
        var root = NewRoot();
        var matriz = await Customer(admin, $"Zeta{tag} Industrial", document: Cnpj(root, 1));
        var filial = await Customer(admin, $"Beta {Tag()} Comercio", document: Cnpj(root, 2));
        var longer = await Customer(admin, $"Zeta{tag} Industrial Tubos Especiais");

        var m = (await ForRecord(admin, "customers", matriz.Id)).Matches;
        var branch = Assert.Single(m, x => x.B.Id == filial.Id);
        Assert.Equal(["document-root"], branch.Reasons.Select(r => r.Code));
        Assert.Equal(60, branch.Score);
        var contained = Assert.Single(m, x => x.B.Id == longer.Id);
        Assert.Equal("name-contains", Assert.Single(contained.Reasons).Code);

        // Above the score of the weak rule it is left out.
        var strict = await (await admin.GetAsync($"/api/customers/{matriz.Id}/duplicates?minScore=70")).Read<RecordDuplicatesOut>();
        Assert.DoesNotContain(strict.Matches, x => x.B.Id == filial.Id);
    }

    [Fact]
    public async Task Legacy_code_matches_and_test_records_are_left_out()
    {
        var admin = await api.AdminAsync();
        var legacy = "L" + Tag();
        var a = await Customer(admin, "Primeiro " + Tag(), legacy: legacy);
        var b = await Customer(admin, "Segundo " + Tag(), legacy: legacy.ToLower());
        var m = Assert.Single((await ForRecord(admin, "customers", a.Id)).Matches);
        Assert.Equal("legacy-code", Assert.Single(m.Reasons).Code);
        Assert.Equal(95, m.Score);

        // Flag the second one as Test data: it no longer counts.
        (await admin.Post("/api/admin/data-source", new { entity = "Customer", ids = new[] { b.Id }, target = "Test", apply = true })).EnsureSuccessStatusCode();
        Assert.Empty((await ForRecord(admin, "customers", a.Id)).Matches);
    }

    [Fact]
    public async Task Products_match_by_code_measures_name_and_the_customers_part_number()
    {
        var admin = await api.AdminAsync();
        var tag = Tag();
        var d = 40_000 + Math.Abs(tag.GetHashCode() % 50_000) / 100m; // a diameter no other test uses
        var p1 = await Product(admin, $"A{tag}.01", $"Tubo {tag} X", d, 1.5m, 1000m);
        var p2 = await Product(admin, $"B{tag}.02", $"Outro nome {tag}", d, 1.5m, 1000m);
        var p3 = await Product(admin, $"A{tag}01", $"Diferente {tag}", d + 1m, 2m, 500m);
        var p4 = await Product(admin, $"C{tag}", $"tubo {tag} x", d + 2m, 3m, 700m);
        var customer = await Customer(admin, "Cliente " + tag);
        (await admin.Put($"/api/products/{p2.Id}/customers/{customer.Id}", new ProductCustomerIn($"PN-{tag}", null))).EnsureSuccessStatusCode();
        (await admin.Put($"/api/products/{p4.Id}/customers/{customer.Id}", new ProductCustomerIn($"pn {tag}", null))).EnsureSuccessStatusCode();

        var m = (await ForRecord(admin, "products", p1.Id)).Matches;
        Assert.Equal(["measures"], Assert.Single(m, x => x.B.Id == p2.Id).Reasons.Select(r => r.Code));
        Assert.Equal(["code"], Assert.Single(m, x => x.B.Id == p3.Id).Reasons.Select(r => r.Code)); // "A{tag}.01" and "A{tag}01"
        Assert.Equal(["name"], Assert.Single(m, x => x.B.Id == p4.Id).Reasons.Select(r => r.Code));
        Assert.Contains("Ø", Assert.Single(m, x => x.B.Id == p2.Id).A.Detail);

        var fromP2 = (await ForRecord(admin, "products", p2.Id)).Matches;
        var part = Assert.Single(fromP2, x => x.B.Id == p4.Id);
        Assert.Equal(["customer-part"], part.Reasons.Select(r => r.Code));
        Assert.Equal(80, part.Score);
    }

    [Fact]
    public async Task Suppliers_match_by_cnpj_of_their_addresses_and_name()
    {
        var admin = await api.AdminAsync();
        var tag = Tag();
        var root = NewRoot();
        var a = await (await admin.Post("/api/suppliers", new SupplierIn($"Aco {tag} Ltda", null, null, null))).Read<SupplierOut>();
        var b = await (await admin.Post("/api/suppliers", new SupplierIn($"Fornecedor outro {tag}", null, null, null))).Read<SupplierOut>();
        foreach (var s in new[] { a, b })
            (await admin.Post($"/api/suppliers/{s.Id}/addresses", new SupplierAddressIn("SP", Cnpj(root), null, null, null, null, null, "Embu", null, null, null, null))).EnsureSuccessStatusCode();

        var m = Assert.Single((await ForRecord(admin, "suppliers", a.Id)).Matches);
        Assert.Equal(b.Id, m.B.Id);
        Assert.Equal("document", Assert.Single(m.Reasons).Code);
    }

    [Fact]
    public async Task Marking_a_pair_as_not_a_duplicate_hides_it_is_audited_and_can_be_taken_back()
    {
        var admin = await api.AdminAsync();
        var reader = await api.UserAsync(UserRole.Reader);
        var stock = await api.UserAsync(UserRole.Stock);
        var sales = await api.UserAsync(UserRole.Sales);
        var root = NewRoot();
        var a = await Customer(admin, "Gama " + Tag(), document: Cnpj(root, 1));
        var b = await Customer(admin, "Delta " + Tag(), document: Cnpj(root, 1));

        Assert.Equal(HttpStatusCode.Forbidden, (await reader.Post($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss", new DismissIn(null))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await stock.Post($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss", new DismissIn(null))).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await sales.Post($"/api/duplicates/customers/{a.Id}/{a.Id}/dismiss", new DismissIn(null))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await sales.Post($"/api/duplicates/customers/{a.Id}/999999999/dismiss", new DismissIn(null))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await sales.Post($"/api/duplicates/nonsense/{a.Id}/{b.Id}/dismiss", new DismissIn(null))).StatusCode);
        // Reading is open to every signed-in user.
        Assert.Single((await ForRecord(reader, "customers", a.Id)).Matches);

        // Either order works and marking twice is harmless.
        Assert.Equal(HttpStatusCode.NoContent, (await sales.Post($"/api/duplicates/customers/{b.Id}/{a.Id}/dismiss", new DismissIn("Filiais independentes"))).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await sales.Post($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss", new DismissIn(null))).StatusCode);

        var after = await ForRecord(admin, "customers", a.Id);
        Assert.Empty(after.Matches);
        var cleared = Assert.Single(after.Dismissed);
        Assert.Equal(b.Id, cleared.Other.Id);
        Assert.Equal("Filiais independentes", cleared.Reason);
        Assert.NotNull(cleared.CreatedBy);
        var list = await (await admin.GetAsync("/api/duplicates/customers")).Read<DuplicateListOut>();
        Assert.DoesNotContain(list.Groups, g => g.Members.Any(x => x.Id == a.Id));

        var audit = (await (await admin.GetAsync($"/api/audit?entity=DuplicateDismissal&entityId={cleared.Id}")).Read<Page<AuditOut>>()).Items;
        Assert.Contains(audit, e => e.Action == "Insert");

        // Take it back: flagged again, and a second undo finds nothing.
        Assert.Equal(HttpStatusCode.NoContent, (await sales.DeleteAsync($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss")).StatusCode);
        Assert.Single((await ForRecord(admin, "customers", a.Id)).Matches);
        Assert.Equal(HttpStatusCode.NotFound, (await sales.DeleteAsync($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss")).StatusCode);
        audit = (await (await admin.GetAsync($"/api/audit?entity=DuplicateDismissal&entityId={cleared.Id}")).Read<Page<AuditOut>>()).Items;
        Assert.Contains(audit, e => e.Action == "Delete");
        Assert.Equal(HttpStatusCode.Forbidden, (await reader.DeleteAsync($"/api/duplicates/customers/{a.Id}/{b.Id}/dismiss")).StatusCode);
    }

    [Fact]
    public async Task The_list_groups_linked_pairs_and_rejects_an_unknown_kind()
    {
        var admin = await api.AdminAsync();
        var tag = Tag();
        var root = NewRoot();
        // a-b share the CNPJ, b-c share the name: one group of three.
        var a = await Customer(admin, $"Ecos {tag} Tubos", document: Cnpj(root, 1));
        var b = await Customer(admin, $"Ecos {tag} Industria", "Ecos Tubos " + tag, Cnpj(root, 1));
        var c = await Customer(admin, $"Ecos Tubos {tag} Ltda");

        var list = await (await admin.GetAsync("/api/duplicates/customers")).Read<DuplicateListOut>();
        var group = Assert.Single(list.Groups, g => g.Members.Any(x => x.Id == a.Id));
        Assert.Contains(group.Members, x => x.Id == b.Id);
        Assert.Contains(group.Members, x => x.Id == c.Id);
        Assert.True(group.Pairs.Count >= 2);
        Assert.Equal(group.Pairs.Max(p => p.Score), group.Score);
        Assert.True(list.Pairs >= group.Pairs.Count);
        // Sorted best first.
        Assert.Equal(list.Groups.Select(g => g.Score).OrderByDescending(s => s), list.Groups.Select(g => g.Score));

        Assert.Equal(HttpStatusCode.NotFound, (await admin.GetAsync("/api/duplicates/orders")).StatusCode);
        var products = await (await admin.GetAsync("/api/duplicates/product")).Read<DuplicateListOut>();
        Assert.NotNull(products.Groups);
    }
}
