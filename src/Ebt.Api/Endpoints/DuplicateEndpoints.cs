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

/// <summary>Suspected duplicate customers, products and suppliers, with a field-by-field comparison and a way to settle them (keep one, deactivate the rest; nothing is deleted or re-pointed).</summary>
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

        // Field by field: the value each record holds, and what points at it. ?ids=1,2,3
        g.MapGet("/{kind}/compare", async (string kind, string ids, DuplicateMergeService svc, CancellationToken ct) =>
        {
            if (ParseKind(kind) is not { } k) return Results.NotFound();
            var list = ids.Split(',',StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(x => int.TryParse(x, out var n) ? n : 0).Where(n => n > 0).ToList();
            if (list.Distinct().Count() < 2) return Results.BadRequest(new { message = "Escolha ao menos dois cadastros para comparar", field = "ids" });
            return await svc.CompareAsync(k, list, ct) is { } r ? Results.Ok(r) : Results.NotFound();
        });

        // Settle a group: the chosen values go into the record that stays, the others are deactivated.
        g.MapPost("/{kind}/resolve", async (string kind, ResolveIn input, DuplicateMergeService svc, ClaimsPrincipal user, CancellationToken ct) =>
        {
            if (ParseKind(kind) is not { } k) return Results.NotFound();
            var (status, result, message) = await svc.ResolveAsync(k, input, user.Identity?.Name, ct);
            return status switch
            {
                DuplicateMergeService.ResolveStatus.Done => Results.Ok(result),
                DuplicateMergeService.ResolveStatus.NotFound => Results.NotFound(),
                DuplicateMergeService.ResolveStatus.Conflict => Results.Conflict(new { message }),
                _ => Results.BadRequest(new { message })
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
