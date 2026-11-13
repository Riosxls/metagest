using System.Text.RegularExpressions;
using System.Globalization;
using Ebt.Core.Data;
using Ebt.Core.Entities;
using Ebt.Core.Sales;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Core.Certificates;

public sealed record TemplateUpdate(string? Title, string? Finish, string? Notes, IReadOnlyList<CertificateMeasureInput> Measures, string? User = null);
public sealed record CertificateMeasureInput(CertificateMeasureKind Kind, string Name, string? Specified = null, string? Found = null);

public sealed record CertificateInput(int OrderId, int? OrderLineId = null, int? DeliveryId = null, string? Company = null, string? CustomerPo = null, DateOnly? IssueDate = null, string? InvoiceNumber = null,
    decimal? Quantity = null, string? Unit = null, string? Description = null, string? CustomerPartNumber = null, string? CustomerPartDescription = null, string? RawMaterialLot = null, string? Hardness = null,
    string? Finish = null, string? Notes = null, string? ApprovedBy = null, IReadOnlyList<CertificateMeasureInput>? Measures = null, string? Title = null);

public sealed class CertificateService(EbtDbContext db)
{
    public const string DefaultFinish = "Isento de porosidade / Manchas / Riscos e Corrosão";

    // Last numbers issued on paper before the system took over (certificate folders, 2026-10-28); numbering is continuous across years.
    private static readonly Dictionary<string, int> LastPaperNumber = new() { ["EBT"] = 2145, ["BST"] = 5175 };

    private static readonly string[] ChemicalElements = ["C", "Mn", "P", "S", "Si", "Al", "Nb", "Cr", "Cu", "V"];
    private static readonly string[] MechanicalTests = ["LR", "LE", "LA"];
    private static readonly CultureInfo Pt = CultureInfo.GetCultureInfo("pt-BR");

    public static string ReferenceOf(int number, int year) => $"{number}-{year % 100:00}";

    /// <summary>Standard tables of the certificate template, with the dimensional specification taken from the product.</summary>
    public static List<CertificateMeasureInput> TemplateMeasures(Product? p)
    {
        var list = ChemicalElements.Select(e => new CertificateMeasureInput(CertificateMeasureKind.Chemical, e)).ToList();
        list.Add(new(CertificateMeasureKind.Dimensional, "Diâmetro", (p?.DiameterMm ?? p?.WidthMm)?.ToString("0.00", Pt)));
        list.Add(new(CertificateMeasureKind.Dimensional, "Espessura", p?.ThicknessMm?.ToString("0.00", Pt)));
        list.Add(new(CertificateMeasureKind.Dimensional, "Comprimento", p is not null && IsCoil(p) ? "Rolo" : p?.LengthMm?.ToString("0.##", Pt))); // a coil has no cut length: the sheets print "Rolo"
        list.AddRange(MechanicalTests.Select(t => new CertificateMeasureInput(CertificateMeasureKind.Mechanical, t)));
        return list;
    }

    /// <summary>"N° do Produto" the way the Excel certificates print it: T + diameter x100 (4 digits) + thickness x1000 (4 digits) + length (4 digits, 0 for a coil). Older sheets of some customers drop a zero; those keep their own code through the template.</summary>
    public static string? ExcelProductCode(Product? p)
    {
        if ((p?.DiameterMm ?? p?.WidthMm) is not { } d || p?.ThicknessMm is not { } t) return null;
        var length = IsCoil(p) || p.LengthMm is not { } l ? "0" : decimal.Round(l).ToString("0000", CultureInfo.InvariantCulture);
        return $"T{decimal.Round(d * 100):0000}{decimal.Round(t * 1000):0000}{length}";
    }

    /// <summary>"Descrição" the way the Excel certificates print it: "Tubo 12,00 X 1,60 X 6000" ("ROLO" for a coil).</summary>
    public static string? ExcelDescription(Product? p)
    {
        if ((p?.DiameterMm ?? p?.WidthMm) is not { } d || p?.ThicknessMm is not { } t) return null;
        var length = IsCoil(p) || p.LengthMm is not { } l ? "ROLO" : l.ToString("0.##", Pt);
        return $"Tubo {d.ToString("00.00", Pt)} X {t.ToString("0.00", Pt)} X {length}";
    }

    private static bool IsCoil(Product p) => p.Name.Contains("ROLO", StringComparison.OrdinalIgnoreCase);

    public async Task<QualityCertificate> CreateAsync(CertificateInput i, string? user, CancellationToken ct = default)
    {
        var order = await db.SalesOrders.AsNoTracking().Include(o => o.Lines).FirstOrDefaultAsync(o => o.Id == i.OrderId, ct) ?? throw SalesException.NotFound("Order");
        if (order.Status == SalesOrderStatus.Cancelled) throw SalesException.Conflict("Order is cancelled");
        var delivery = i.DeliveryId is { } did
            ? await db.Deliveries.AsNoTracking().Include(d => d.Lines).FirstOrDefaultAsync(d => d.Id == did && d.OrderId == order.Id && d.Status != DeliveryStatus.Cancelled, ct)
                ?? throw SalesException.Invalid("deliveryId", "Not an active delivery of this order")
            : null;
        var lineId = i.OrderLineId ?? (delivery is { Lines.Count: 1 } ? delivery.Lines[0].OrderLineId : order.Lines.Count == 1 ? order.Lines[0].Id : null);
        var line = lineId is { } lid ? order.Lines.FirstOrDefault(l => l.Id == lid) ?? throw SalesException.Invalid("orderLineId", "Not a line of this order") : null;
        if (line is null) throw SalesException.Invalid("orderLineId", "Choose the order line the certificate covers");
        var product = await db.Products.AsNoTracking().FirstOrDefaultAsync(p => p.Id == line.ProductId, ct);
        var link = await db.ProductCustomers.AsNoTracking().FirstOrDefaultAsync(c => c.ProductId == line.ProductId && c.CustomerId == order.CustomerId, ct);
        var deliveryQty = delivery?.Lines.FirstOrDefault(l => l.OrderLineId == line.Id)?.Quantity;
        var template = await TemplateAsync(line.ProductId, order.CustomerId, ct);
        var borrowed = false;
        if (template is null && product is not null)
        {
            template = await ClosestTemplateAsync(product, order.CustomerId, ct);
            borrowed = template is not null;
        }
        var quantity = i.Quantity ?? deliveryQty ?? line.Quantity;
        if (quantity <= 0) throw SalesException.Invalid("quantity", "Must be greater than zero");

        var company = SalesService.CompanyOf(i.Company ?? order.Company);
        var date = i.IssueDate ?? SalesService.Today();
        for (var attempt = 0; ; attempt++)
        {
            var number = await NextNumberAsync(company, ct);
            var c = new QualityCertificate
            {
                Company = company, Number = number, Year = date.Year, Reference = ReferenceOf(number, date.Year), OrderId = order.Id, OrderLineId = line.Id, DeliveryId = delivery?.Id, ProductId = line.ProductId,
                CustomerPo = Clean(i.CustomerPo) ?? order.CustomerPo, IssueDate = date, InvoiceNumber = Clean(i.InvoiceNumber) ?? Clean(delivery?.InvoiceNumber), Quantity = quantity, Unit = (Clean(i.Unit) ?? line.Unit).ToUpperInvariant(),
                ProductCode = template?.ProductCode ?? ExcelProductCode(product) ?? product?.Code, Description = Clean(i.Description) ?? template?.Description ?? ExcelDescription(product) ?? line.Description,
                CustomerPartNumber = Clean(i.CustomerPartNumber) ?? Clean(link?.CustomerPartNumber) ?? line.CustomerPartNumber,
                CustomerPartDescription = Clean(i.CustomerPartDescription) ?? link?.CustomerDescription, RawMaterialLot = Clean(i.RawMaterialLot) ?? template?.RawMaterialLot, Hardness = Clean(i.Hardness) ?? template?.Hardness, Finish = Clean(i.Finish) ?? template?.Finish ?? DefaultFinish, Title = Clean(i.Title) ?? template?.Title,
                Notes = Clean(i.Notes) ?? template?.Notes, ApprovedBy = Clean(i.ApprovedBy), Status = CertificateStatus.Draft, CreatedBy = user, CreatedAt = DateTimeOffset.UtcNow
            };
            SetMeasures(c, i.Measures ?? (borrowed ? BorrowedMeasures(template!, product) : template?.Measures.OrderBy(m => m.Kind).ThenBy(m => m.Sequence).Select(m => new CertificateMeasureInput(m.Kind, m.Name, m.Specified, m.Found)).ToList()) ?? TemplateMeasures(product));
            db.QualityCertificates.Add(c);
            try
            {
                await db.SaveChangesAsync(ct);
                return c;
            }
            catch (DbUpdateException) when (attempt < 3)
            {
                db.ChangeTracker.Clear(); // another certificate took the number: try the next one
            }
        }
    }

    public async Task<QualityCertificate> UpdateAsync(int id, CertificateInput i, CancellationToken ct = default)
    {
        var c = await LoadAsync(id, ct);
        if (c.Status != CertificateStatus.Draft) throw SalesException.Conflict($"Certificate is {c.Status}; only drafts can be edited");
        await CheckDeliveryAsync(c, i.DeliveryId, ct);
        c.DeliveryId = i.DeliveryId;
        if (i.Quantity is { } q) c.Quantity = q > 0 ? q : throw SalesException.Invalid("quantity", "Must be greater than zero");
        if (i.IssueDate is { } d)
        {
            c.IssueDate = d;
            c.Year = d.Year;
            c.Reference = ReferenceOf(c.Number, c.Year);
        }
        c.CustomerPo = Clean(i.CustomerPo);
        c.InvoiceNumber = Clean(i.InvoiceNumber);
        if (Clean(i.Unit) is { } u) c.Unit = u.ToUpperInvariant();
        if (Clean(i.Description) is { } desc) c.Description = desc;
        c.CustomerPartNumber = Clean(i.CustomerPartNumber);
        c.CustomerPartDescription = Clean(i.CustomerPartDescription);
        c.RawMaterialLot = Clean(i.RawMaterialLot);
        c.Hardness = Clean(i.Hardness);
        c.Finish = Clean(i.Finish) ?? DefaultFinish;
        c.Title = Clean(i.Title);
        c.Notes = Clean(i.Notes);
        c.ApprovedBy = Clean(i.ApprovedBy);
        if (i.Measures is not null)
        {
            db.CertificateMeasures.RemoveRange(c.Measures);
            c.Measures = new();
            SetMeasures(c, i.Measures);
        }
        await db.SaveChangesAsync(ct);
        return c;
    }

    /// <summary>Links the certificate to a delivery of the same order (or unlinks it with null). Allowed on issued certificates too, since the delivery is usually planned after the certificate.</summary>
    public async Task<QualityCertificate> LinkDeliveryAsync(int id, int? deliveryId, CancellationToken ct = default)
    {
        var c = await LoadAsync(id, ct);
        if (c.Status == CertificateStatus.Cancelled) throw SalesException.Conflict("Certificate is cancelled");
        await CheckDeliveryAsync(c, deliveryId, ct);
        c.DeliveryId = deliveryId;
        await db.SaveChangesAsync(ct);
        return c;
    }

    private async Task CheckDeliveryAsync(QualityCertificate c, int? deliveryId, CancellationToken ct)
    {
        if (deliveryId is { } did && did != c.DeliveryId && !await db.Deliveries.AnyAsync(d => d.Id == did && d.OrderId == c.OrderId && d.Status != DeliveryStatus.Cancelled, ct))
            throw SalesException.Invalid("deliveryId", "Not an active delivery of this order");
    }

    public async Task<QualityCertificate> IssueAsync(int id, string? user, CancellationToken ct = default)
    {
        var c = await LoadAsync(id, ct);
        if (c.Status != CertificateStatus.Draft) throw SalesException.Conflict($"Certificate is {c.Status}");
        // The NF is usually issued first: a draft made before it, or left blank, takes the number of its delivery's NF when it is issued.
        if (string.IsNullOrWhiteSpace(c.InvoiceNumber) && c.DeliveryId is { } nfDelivery)
            c.InvoiceNumber = await db.Deliveries.AsNoTracking().Where(d => d.Id == nfDelivery).Select(d => d.InvoiceNumber).FirstOrDefaultAsync(ct);
        if (c.Measures.Count == 0 || c.Measures.Any(m => string.IsNullOrWhiteSpace(m.Found))) throw SalesException.Invalid("measures", "Fill in the value found on every row before issuing (remove the rows that do not apply)");
        c.Status = CertificateStatus.Issued;
        c.IssuedBy = user;
        c.IssuedAt = DateTimeOffset.UtcNow;
        await LearnAsync(c, user, ct);
        await db.SaveChangesAsync(ct);
        return c;
    }

    /// <summary>One draft per delivery item that has no certificate yet, each already filled from its template (the NF of the delivery covers several products, one certificate each).</summary>
    public async Task<IReadOnlyList<QualityCertificate>> CreateForDeliveryAsync(int deliveryId, string? user, CancellationToken ct = default)
    {
        var d = await db.Deliveries.AsNoTracking().Include(x => x.Lines).FirstOrDefaultAsync(x => x.Id == deliveryId, ct) ?? throw SalesException.NotFound("Delivery");
        if (d.Status == DeliveryStatus.Cancelled) throw SalesException.Conflict("Delivery is cancelled");
        var covered = await db.QualityCertificates.AsNoTracking().Where(c => c.DeliveryId == deliveryId && c.Status != CertificateStatus.Cancelled).Select(c => c.OrderLineId).ToListAsync(ct);
        var created = new List<QualityCertificate>();
        foreach (var l in d.Lines.OrderBy(x => x.Id).Where(x => !covered.Contains(x.OrderLineId)))
            created.Add(await CreateAsync(new CertificateInput(d.OrderId, l.OrderLineId, d.Id, Quantity: l.Quantity), user, ct));
        if (created.Count == 0) throw SalesException.Conflict("Every item of this delivery already has a certificate");
        return created;
    }

    /// <summary>
    /// A product that never had a certificate has no template; the customer's certificate of the closest product is the best starting point: the steel (chemical and mechanical specifications), the title, the finish
    /// and the notes are the same for a tube of the same diameter, only the wall and length change. The closest = same customer, same diameter, same kind (coil or bar), nearest wall thickness. Nothing
    /// is borrowed from another diameter, and the identity of the product (code, description, lot) and every found value stay out.
    /// </summary>
    public async Task<CertificateTemplate?> ClosestTemplateAsync(Product product, int customerId, CancellationToken ct = default)
    {
        if ((product.DiameterMm ?? product.WidthMm) is not { } d || product.ThicknessMm is not { } t) return null;
        var candidates = await db.CertificateTemplates.AsNoTracking().Include(x => x.Measures).Include(x => x.Product).Where(x => x.CustomerId == customerId && x.ProductId != product.Id && x.Product!.Shape == product.Shape).ToListAsync(ct);
        var best = candidates
            .Where(x => (x.Product!.DiameterMm ?? x.Product.WidthMm) is { } cd && Math.Abs(cd - d) <= 0.01m && x.Product.ThicknessMm is not null)
            .OrderBy(x => IsCoil(x.Product!) == IsCoil(product) ? 0 : 1).ThenBy(x => Math.Abs(x.Product!.ThicknessMm!.Value - t)).ThenByDescending(x => x.UpdatedAt)
            .FirstOrDefault();
        if (best is null) return null;
        // What identifies the other product or its lot does not come along.
        best.ProductCode = null;
        best.Description = null;
        best.RawMaterialLot = null;
        return best;
    }

    /// <summary>The borrowed template as rows: chemical and mechanical as specified (no found values), dimensional from this product with the tolerance of the template's row ("12,00 ± 0,12" -> "12,06 ± 0,12").</summary>
    private static List<CertificateMeasureInput> BorrowedMeasures(CertificateTemplate template, Product? product)
    {
        var own = TemplateMeasures(product);
        var rows = new List<CertificateMeasureInput>();
        foreach (var m in own)
        {
            if (m.Kind == CertificateMeasureKind.Dimensional)
            {
                var theirs = template.Measures.FirstOrDefault(x => x.Kind == CertificateMeasureKind.Dimensional && x.Name == m.Name)?.Specified;
                var coilLength = m.Name == "Comprimento" && product is not null && IsCoil(product);
                var spec = coilLength && !string.IsNullOrWhiteSpace(theirs) ? theirs : WithTolerance(m.Specified, theirs);
                rows.Add(new(m.Kind, m.Name, spec));
            }
        }
        var chemical = template.Measures.Where(x => x.Kind == CertificateMeasureKind.Chemical).OrderBy(x => x.Sequence).Select(x => new CertificateMeasureInput(x.Kind, x.Name, x.Specified)).ToList();
        var mechanical = template.Measures.Where(x => x.Kind == CertificateMeasureKind.Mechanical).OrderBy(x => x.Sequence).Select(x => new CertificateMeasureInput(x.Kind, x.Name, x.Specified)).ToList();
        return [.. (chemical.Count > 0 ? chemical : own.Where(m => m.Kind == CertificateMeasureKind.Chemical)), .. rows, .. (mechanical.Count > 0 ? mechanical : own.Where(m => m.Kind == CertificateMeasureKind.Mechanical))];
    }

    /// <summary>"12,06" + a template row "12,00± 0,12" -> "12,06 ± 0,12": the new nominal value with the tolerance the customer's drawing carries.</summary>
    private static string? WithTolerance(string? nominal, string? template)
    {
        if (string.IsNullOrWhiteSpace(nominal)) return template;
        var m = Regex.Match(template ?? "", @"^\s*[\d.,]+\s*(?<rest>.*)$");
        var rest = m.Success ? m.Groups["rest"].Value.Trim() : "";
        return rest.Length == 0 ? nominal : $"{nominal} {rest}";
    }

    public async Task<CertificateTemplate?> TemplateAsync(int productId, int customerId, CancellationToken ct = default) =>
        await db.CertificateTemplates.AsNoTracking().Include(t => t.Measures).FirstOrDefaultAsync(t => t.ProductId == productId && t.CustomerId == customerId, ct);

    public async Task<CertificateTemplate> UpdateTemplateAsync(int id, TemplateUpdate u, CancellationToken ct = default)
    {
        var t = await db.CertificateTemplates.Include(x => x.Measures).FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw SalesException.NotFound("Template");
        if (u.Measures.Any(m => string.IsNullOrWhiteSpace(m.Name))) throw SalesException.Invalid("measures", "Every row needs a name");
        t.Title = Clean(u.Title);
        t.Finish = Clean(u.Finish);
        t.Notes = Clean(u.Notes);
        t.UpdatedBy = u.User;
        t.UpdatedAt = DateTimeOffset.UtcNow;
        db.CertificateTemplateMeasures.RemoveRange(t.Measures);
        t.Measures = u.Measures.GroupBy(m => m.Kind).SelectMany(g => g.Select((m, i) => new CertificateTemplateMeasure { Kind = g.Key, Sequence = i + 1, Name = m.Name!.Trim(), Specified = Clean(m.Specified), Found = Clean(m.Found) })).ToList();
        await db.SaveChangesAsync(ct);
        return t;
    }

    public async Task DeleteTemplateAsync(int id, CancellationToken ct = default)
    {
        var t = await db.CertificateTemplates.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw SalesException.NotFound("Template");
        db.CertificateTemplates.Remove(t);
        await db.SaveChangesAsync(ct);
    }

    /// <summary>Remembers the specification of an issued certificate for the next one of the same product and customer. The found values, the raw-material lot and the notes (including the "certificado de origem do material" line) are kept too: on the 2025-26 Excel sheets the same customer and product reuse the lot in 86% of the repeats and the origin note in 92%, and the draft stays editable when the steel lot changes.</summary>
    private async Task LearnAsync(QualityCertificate c, string? user, CancellationToken ct)
    {
        if (c.ProductId is not { } productId) return;
        var customerId = await db.SalesOrders.Where(o => o.Id == c.OrderId).Select(o => o.CustomerId).FirstAsync(ct);
        var t = await db.CertificateTemplates.Include(x => x.Measures).FirstOrDefaultAsync(x => x.ProductId == productId && x.CustomerId == customerId, ct);
        if (t is null)
        {
            t = new CertificateTemplate { ProductId = productId, CustomerId = customerId };
            db.CertificateTemplates.Add(t);
        }
        t.Title = Clean(c.Title);
        t.Finish = Clean(c.Finish);
        t.Hardness = Clean(c.Hardness);
        t.ProductCode = Clean(c.ProductCode);
        t.Description = Clean(c.Description);
        t.RawMaterialLot = Clean(c.RawMaterialLot);
        t.Notes = Clean(c.Notes);
        t.UpdatedBy = user;
        t.UpdatedAt = DateTimeOffset.UtcNow;
        t.LearnedFrom = c.Reference;
        db.CertificateTemplateMeasures.RemoveRange(t.Measures);
        t.Measures = new();
        foreach (var g in c.Measures.GroupBy(m => m.Kind))
            foreach (var (m, n) in g.OrderBy(m => m.Sequence).Select((m, n) => (m, n)))
                t.Measures.Add(new CertificateTemplateMeasure { Kind = g.Key, Sequence = n + 1, Name = m.Name, Specified = m.Specified, Found = m.Found });
    }

    public async Task<QualityCertificate> CancelAsync(int id, string? reason, CancellationToken ct = default)
    {
        var c = await LoadAsync(id, ct);
        if (c.Status == CertificateStatus.Cancelled) throw SalesException.Conflict("Certificate is already cancelled");
        c.CancelReason = Clean(reason) ?? throw SalesException.Invalid("reason", "Required");
        c.Status = CertificateStatus.Cancelled;
        await db.SaveChangesAsync(ct);
        return c;
    }

    public async Task DeleteAsync(int id, CancellationToken ct = default)
    {
        var c = await LoadAsync(id, ct);
        if (c.Status != CertificateStatus.Draft) throw SalesException.Conflict($"Certificate is {c.Status}; cancel it instead");
        db.QualityCertificates.Remove(c);
        await db.SaveChangesAsync(ct);
    }

    public async Task SetWaivedAsync(int orderId, bool waived, CancellationToken ct = default)
    {
        var o = await db.SalesOrders.FirstOrDefaultAsync(x => x.Id == orderId, ct) ?? throw SalesException.NotFound("Order");
        o.CertificateWaived = waived;
        await db.SaveChangesAsync(ct);
    }

    private async Task<QualityCertificate> LoadAsync(int id, CancellationToken ct) =>
        await db.QualityCertificates.Include(c => c.Measures).FirstOrDefaultAsync(c => c.Id == id, ct) ?? throw SalesException.NotFound("Certificate");

    private async Task<int> NextNumberAsync(string company, CancellationToken ct)
    {
        var last = await db.QualityCertificates.Where(c => c.Company == company).Select(c => (int?)c.Number).MaxAsync(ct) ?? 0;
        return Math.Max(last, LastPaperNumber.GetValueOrDefault(company)) + 1;
    }

    private static void SetMeasures(QualityCertificate c, IEnumerable<CertificateMeasureInput> measures)
    {
        foreach (var g in measures.Where(m => Clean(m.Name) is not null).GroupBy(m => m.Kind))
            foreach (var (m, n) in g.Select((m, n) => (m, n)))
                c.Measures.Add(new CertificateMeasure { Kind = g.Key, Sequence = n + 1, Name = m.Name.Trim(), Specified = Clean(m.Specified), Found = Clean(m.Found) });
    }

    private static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
