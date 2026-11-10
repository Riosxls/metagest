using System.Text.Json;
using Ebt.Api.Infrastructure;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Ebt.Core.Sales;

namespace Ebt.Api.Endpoints;

/// <param name="Apply">false only previews which customers would get which rates.</param>
/// <param name="Overwrite">true also replaces rates a customer already has (default keeps them).</param>
public sealed record CustomerTaxImportIn(bool Apply, bool Overwrite, List<TaxOrderRow>? Rows);

/// <summary>Fills each customer's usual IPI and ICMS from the old internal sales orders (see scripts/export-customer-taxes.ps1). Admin only, audited.</summary>
public static class CustomerTaxEndpoints
{
    public static void MapCustomerTaxes(this WebApplication app)
    {
        app.MapPost("/api/customers/tax-import", async (CustomerTaxImportIn i, CustomerTaxImporter importer, EbtDbContext db, System.Security.Claims.ClaimsPrincipal user, CancellationToken ct) =>
        {
            if (i.Rows is not { Count: > 0 }) return Results.BadRequest(new { message = "Nenhum pedido enviado", field = "rows" });
            var result = await importer.ImportAsync(i.Rows, i.Apply, i.Overwrite, ct);
            if (i.Apply)
            {
                db.AuditLog.Add(new AuditEntry
                {
                    At = DateTimeOffset.UtcNow, User = user.Identity?.Name, Entity = "Customer", EntityId = "tax-import", Action = "Import",
                    Changes = JsonSerializer.Serialize(new { result.Read, result.Used, result.Skipped, customers = result.Matches.Count(m => m.Applied), unmatched = result.Unmatched.Count })
                });
                await db.SaveChangesAsync(ct);
            }
            return Results.Ok(result);
        }).WithTags("Customers").RequireAuthorization(Policies.Admin);
    }
}
