using System.Globalization;
using System.Reflection;
using System.Text;

namespace Ebt.Core.Fiscal;

/// <summary>
/// The 5,571 Brazilian municipalities with their 7-digit IBGE code (the cMun of the NF-e), built in (<c>Fiscal/Data/ibge-municipios.csv</c>, from the IBGE
/// localities service: code;UF;name). Lookup is by city name and UF, ignoring case, accents, punctuation, the little words (de, da, do...) and the
/// usual abbreviations (STO, STA), so "Sto. André", "SANTO ANDRE" and "Santo André" are the same city.
/// </summary>
public static class IbgeMunicipalities
{
    private static readonly Lazy<Dictionary<(string Uf, string Key), string>> Map = new(Load);

    private static readonly HashSet<string> LittleWords = ["DE", "DA", "DO", "DAS", "DOS", "D"];

    private static readonly Dictionary<string, string> Abbreviations = new()
    {
        ["STO"] = "SANTO", ["STA"] = "SANTA", ["STOS"] = "SANTOS", ["STAS"] = "SANTAS", ["S"] = "SAO", ["SAN"] = "SAO", ["PRES"] = "PRESIDENTE", ["PTE"] = "PRESIDENTE", ["CEL"] = "CORONEL", ["DR"] = "DOUTOR",
    };

    /// <summary>The name as a comparison key: upper case, no accents or punctuation, abbreviations spelled out, little words dropped.</summary>
    public static string Key(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "";
        var d = name.Normalize(NormalizationForm.FormD).Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark);
        var plain = new string(d.Select(c => char.IsLetterOrDigit(c) ? char.ToUpperInvariant(c) : ' ').ToArray());
        var tokens = plain.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(t => Abbreviations.GetValueOrDefault(t, t)).Where(t => !LittleWords.Contains(t));
        return string.Concat(tokens);
    }

    private static Dictionary<(string, string), string> Load()
    {
        var asm = typeof(IbgeMunicipalities).Assembly;
        var resource = asm.GetManifestResourceNames().First(n => n.EndsWith("ibge-municipios.csv", StringComparison.Ordinal));
        using var reader = new StreamReader(asm.GetManifestResourceStream(resource)!, Encoding.UTF8);
        var map = new Dictionary<(string, string), string>();
        while (reader.ReadLine() is { } line)
        {
            var p = line.Split(';', 3);
            if (p.Length < 3 || p[0].Length != 7) continue;
            // Two cities of the same state that read alike once the little words are gone keep the first one: the lookup then answers "unknown" for the second only if it is asked by a spelling that matches neither.
            map.TryAdd((p[1], Key(p[2])), p[0]);
        }
        return map;
    }

    /// <summary>The IBGE code of the city in that state, or null when the name matches none.</summary>
    public static string? Find(string? city, string? uf)
    {
        var state = (uf ?? "").Trim().ToUpperInvariant();
        var key = Key(city);
        if (state.Length != 2 || key.Length == 0) return null;
        return Map.Value.TryGetValue((state, key), out var code) ? code : null;
    }

    /// <summary>How many municipalities the table holds (for tests and the about page).</summary>
    public static int Count => Map.Value.Count;
}
