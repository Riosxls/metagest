using System.Globalization;
using System.Text.RegularExpressions;
using Ebt.Core.Entities;
using Ebt.Core.Sales;
using Microsoft.EntityFrameworkCore;

namespace Ebt.Api.Infrastructure;

/// <summary>
/// The search box of products, customers, suppliers and materials. Every word typed must match (AND), accents and case are ignored, and for tubes the
/// numbers are read as dimensions: "12 x 1,5 x 900", "12,7 1,4", "952" or "080.090" all find the product whatever way its name was typed in the old system.
/// </summary>
public static class SmartSearch
{
    private const decimal Tolerance = 0.005m;
    private static readonly Regex Number = new(@"^\d+(?:[.,]\d+)?$", RegexOptions.Compiled);
    private static readonly Regex Chain = new(@"^\s*[ØøΦ]?\s*(?<n>\d+(?:[.,]\d+)?)(?:\s*(?:mm)?\s*[x×*]\s*(?<n>\d+(?:[.,]\d+)?))+\s*(?:mm)?", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    /// <param name="LastStep">When the chain ends right where the text ends (the user is still typing the last number), the size of one unit of its last decimal place: "0,9" -> 0.1, "0" -> 1. Otherwise 0.</param>
    public sealed record Parsed(IReadOnlyList<decimal> Chain, IReadOnlyList<string> Words, decimal LastStep = 0m);

    /// <summary>Splits the text into an optional leading "A x B x C" chain of dimensions and the remaining words (folded: no accents, lower case).</summary>
    public static Parsed Parse(string? text)
    {
        var s = text ?? "";
        var chain = new List<decimal>();
        var step = 0m;
        var m = Chain.Match(s);
        if (m.Success)
        {
            foreach (Capture c in m.Groups["n"].Captures) chain.Add(ParseNumber(c.Value));
            if (m.Length == s.Length && !char.IsWhiteSpace(s[^1]) && !s.TrimEnd().EndsWith("mm", StringComparison.OrdinalIgnoreCase))
            {
                var last = m.Groups["n"].Captures[^1].Value;
                var cut = last.IndexOfAny(['.', ',']);
                step = cut < 0 ? 1m : (decimal)Math.Pow(10, -(last.Length - cut - 1));
            }
            s = s[m.Length..];
        }
        var words = PriceHistoryImporter.Fold(s).ToLowerInvariant()
            .Split([' ', '\t', ';'], StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w.Trim().Trim('Ø', 'ø', '*', '×')).Where(w => w.Length > 0 && w is not ("x" or "mm")).ToList();
        return new Parsed(chain, words, step);
    }

    private static decimal ParseNumber(string raw) => decimal.Parse(raw.Replace(',', '.'), CultureInfo.InvariantCulture);

    private static string Pattern(string word) => "%" + word.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";

    public static IQueryable<Product> Products(IQueryable<Product> q, string text)
    {
        var parsed = Parse(text);
        if (parsed.Chain.Count >= 2)
        {
            var c = parsed.Chain.Take(4).ToList();
            var lo = c.Select(v => v - Tolerance).ToArray();
            var hi = c.Select(v => v + Tolerance).ToArray();
            decimal a0 = lo[0], a1 = hi[0], b0 = lo[1], b1 = hi[1];
            if (c.Count == 2)
            {
                // Still typing the wall ("8 x 0" on the way to "8 x 0,9"): every wall that starts with what was typed counts.
                if (parsed.LastStep > 0m) b1 = c[1] + parsed.LastStep - Tolerance;
                q = q.Where(p => ((p.DiameterMm >= a0 && p.DiameterMm <= a1) || (p.WidthMm >= a0 && p.WidthMm <= a1)) && p.ThicknessMm >= b0 && p.ThicknessMm <= b1);
            }
            else if (c.Count == 3)
            {
                decimal c0 = lo[2], c1 = hi[2];
                q = q.Where(p => ((p.DiameterMm >= a0 && p.DiameterMm <= a1) || (p.WidthMm >= a0 && p.WidthMm <= a1)) && p.ThicknessMm >= b0 && p.ThicknessMm <= b1 && p.LengthMm >= c0 && p.LengthMm <= c1);
            }
            else
            {
                // Rectangular: width x height x wall x length (the two sides in either order).
                decimal c0 = lo[2], c1 = hi[2], d0 = lo[3], d1 = hi[3];
                q = q.Where(p => ((p.WidthMm >= a0 && p.WidthMm <= a1 && p.HeightMm >= b0 && p.HeightMm <= b1) || (p.WidthMm >= b0 && p.WidthMm <= b1 && p.HeightMm >= a0 && p.HeightMm <= a1))
                    && p.ThicknessMm >= c0 && p.ThicknessMm <= c1 && p.LengthMm >= d0 && p.LengthMm <= d1);
            }
        }
        else if (parsed.Chain.Count == 1) { parsed = new Parsed([], [parsed.Chain[0].ToString(CultureInfo.InvariantCulture), .. parsed.Words]); }

        foreach (var word in parsed.Words)
        {
            var pat = Pattern(word);
            if (Number.IsMatch(word))
            {
                var v = ParseNumber(word);
                var lo = v - Tolerance;
                var hi = v + Tolerance;
                var decimalSeparator = word.Contains('.') || word.Contains(',');
                var digits = decimalSeparator ? "" : word;
                // The code of the old system ("127.150.90") has the sizes in it, so 3+ digits without a comma also match inside the code.
                var byCode = digits.Length >= 3;
                q = q.Where(p => (p.DiameterMm >= lo && p.DiameterMm <= hi) || (p.WidthMm >= lo && p.WidthMm <= hi) || (p.HeightMm >= lo && p.HeightMm <= hi)
                    || (p.ThicknessMm >= lo && p.ThicknessMm <= hi) || (p.LengthMm >= lo && p.LengthMm <= hi)
                    || (byCode && p.Code.Replace(".", "").Contains(digits))
                    || (p.DiameterMm == null && p.WidthMm == null && EF.Functions.ILike(p.Name, pat))
                    || p.Customers.Any(c => EF.Functions.ILike(c.CustomerPartNumber!, pat)));
            }
            else
            {
                var codeWord = word.Replace(".", "");
                q = q.Where(p => EF.Functions.ILike(EF.Functions.Unaccent(p.Name), pat) || EF.Functions.ILike(p.Code, pat)
                    || (codeWord.Length >= 3 && p.Code.Replace(".", "").StartsWith(codeWord))
                    || p.Customers.Any(c => EF.Functions.ILike(EF.Functions.Unaccent(c.CustomerPartNumber!), pat) || EF.Functions.ILike(EF.Functions.Unaccent(c.CustomerDescription!), pat)));
            }
        }
        return q;
    }

    public static IQueryable<Customer> Customers(IQueryable<Customer> q, string text)
    {
        foreach (var word in Parse(text).Words)
        {
            var pat = Pattern(word);
            var digits = new string(word.Where(char.IsDigit).ToArray());
            var byDocument = digits.Length >= 4 && digits.Length == word.Replace(".", "").Replace("-", "").Replace("/", "").Length;
            q = q.Where(c => EF.Functions.ILike(EF.Functions.Unaccent(c.Name), pat) || EF.Functions.ILike(EF.Functions.Unaccent(c.TradeName!), pat) || c.LegacyCode == word
                || EF.Functions.ILike(EF.Functions.Unaccent(c.City!), pat)
                || (byDocument && ((c.Document != null && c.Document.Contains(digits)) || c.Addresses.Any(a => a.Document.Contains(digits))))
                || c.Addresses.Any(a => EF.Functions.ILike(EF.Functions.Unaccent(a.City!), pat)));
        }
        return q;
    }

    public static IQueryable<Supplier> Suppliers(IQueryable<Supplier> q, string text)
    {
        foreach (var word in Parse(text).Words)
        {
            var pat = Pattern(word);
            q = q.Where(s => EF.Functions.ILike(EF.Functions.Unaccent(s.Name), pat) || EF.Functions.ILike(EF.Functions.Unaccent(s.TradeName!), pat) || s.LegacyCode == word);
        }
        return q;
    }

    public static IQueryable<Material> Materials(IQueryable<Material> q, string text)
    {
        foreach (var word in Parse(text).Words)
        {
            var pat = Pattern(word);
            q = q.Where(m => m.Code.StartsWith(word) || EF.Functions.ILike(m.Code, pat) || EF.Functions.ILike(EF.Functions.Unaccent(m.Description), pat));
        }
        return q;
    }
}
