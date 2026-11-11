using System.Security.Claims;
using Ebt.Api.Infrastructure;
using Ebt.Core.Duplicates;

namespace Ebt.Api.Endpoints;

public static class DuplicatePolicies
{
    /// <summary>Mark two records as "not a duplicate" (and take it back). Reading the suspects follows the read policy.</summary>
    public const string Review = "duplicates-review";
}

public sealed record DismissIn(string? Reason);

/// <summary>What a record's own page shows: the records that look like it, and the pairs somebody already cleared.</summary>
public sealed record RecordDuplicatesOut(IReadOnlyList<DuplicatePair> Matches, IReadOnlyList<DismissedPair> Dismissed);

public sealed record DuplicateListOut(IReadOnlyList<DuplicateGroup> Groups, int Pairs, int Records);

/// <summary>Suspected duplicate customers, products and suppliers. Detection only: nothing is merged or changed on the records.</summary>
public static class DuplicateEndpoints
{
    private static DuplicateKind? ParseKind(string s) => s.ToLowerInvariant() switch
    {
        "customer" or "customers" => DuplicateKind.Customer,
        "product" or "products" => DuplicateKind.Product,
        "supplier" or "suppliers" => DuplicateKind.Supplier,
        _ => null
    };

    public static void MapDuplicates(this WebApplication app)
    {
        // The three record pages read their own suspects: /api/customers/{id}/duplicates, /api/products/{id}/duplicates, /api/suppliers/{id}/duplicates.
        foreach (var (plural, kind, tag) in new[] { ("customers", DuplicateKind.Customer, "Customers"), ("products", DuplicateKind.Product, "Products"), ("suppliers", DuplicateKind.Supplier, "Suppliers") })
        {
            app.MapGet($"/api/{plural}/{{id:int}}/duplicates", async (int id, DuplicateService svc, int? minScore, CancellationToken ct) =>
            {
                var matches = await svc.PairsAsync(kind, Math.Clamp(minScore ?? DuplicateService.DefaultMinScore, 1, 100), id, ct);
                return Results.Ok(new RecordDuplicatesOut(matches, await svc.DismissedAsync(kind, id, ct)));
            }).WithTags(tag).RequireAuthorization(Policies.Read);
        }

        var g = app.MapGroup("/api/duplicates").WithTags("Duplicates").RequireAuthorization(Policies.Read);

        // Every suspected group of one kind (customers, products or suppliers), best first.
        g.MapGet("/{kind}", async (string kind, DuplicateService svc, int? minScore, CancellationToken ct) =>
        {
            if (ParseKind(kind) is not { } k) return Results.NotFound();
            var pairs = await svc.PairsAsync(k, Math.Clamp(minScore ?? DuplicateService.DefaultMinScore, 1, 100), null, ct);
            var groups = DuplicateService.Group(pairs);
            return Results.Ok(new DuplicateListOut(groups, pairs.Count, groups.Sum(x => x.Members.Count)));
        });

        g.MapPost("/{kind}/{a:int}/{b:int}/dismiss", async (string kind, int a, int b, DismissIn? i, DuplicateService svc, ClaimsPrincipal user, CancellationToken ct) =>
        {
            if (ParseKind(kind) is not { } k) return Results.NotFound();
            return await svc.DismissAsync(k, a, b, i?.Reason, user.Identity?.Name, ct) switch
            {
                DuplicateService.DismissResult.SameRecord => Results.BadRequest(new { message = "Escolha dois registros diferentes", field = "b" }),
                DuplicateService.DismissResult.NotFound => Results.NotFound(),
                _ => Results.NoContent()
            };
        }).RequireAuthorization(DuplicatePolicies.Review);

        // Take the mark back: the pair is flagged again.
        g.MapDelete("/{kind}/{a:int}/{b:int}/dismiss", async (string kind, int a, int b, DuplicateService svc, CancellationToken ct) =>
        {
            if (ParseKind(kind) is not { } k) return Results.NotFound();
            return await svc.RestoreAsync(k, a, b, ct) ? Results.NoContent() : Results.NotFound();
        }).RequireAuthorization(DuplicatePolicies.Review);
    }
}
