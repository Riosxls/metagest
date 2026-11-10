<#
.SYNOPSIS
  Reads the usual IPI and ICMS of every customer from the old "Pedido Interno de Venda" workbooks and writes customer-taxes.json, the file for
  POST /api/customers/tax-import (admin; the API itself picks the latest rates per customer and writes the note).

.DESCRIPTION
  One xlsx per order, sheet 1, read as zip + XML (no Excel). Cells are found by their label: CLIENTE:, CNPJ:, ESTADO:, ICMS:, I.P.I:, DATA.
  A rate stored as a fraction (0.0325) becomes a percentage (3.25). The order number comes from the file name (PEDIDO 04183-25 ...).
  The same sheets carry the customer's registration (END, BAIRRO, MUNICIPIO, CEP, I.E, CONTATO, TEL/FAX, E-mail, PRAZO); with -CreateMissing the API also registers the
  customers that are on orders but not in the cadastro, one per CNPJ, with the data of their latest order (preview first, -Apply to save).
  Nothing is written to the database. Send the file with -Send (asks the API first with apply=false and prints who would get what), then -Apply to save.
  The file is git-ignored (customer-taxes*.json).

  Windows PowerShell 5.1. Saved as UTF-8 with BOM.
#>
param(
    [string]$Folder = 'C:\Users\italo\Desktop\EBT\Pedidos de Vendas\PEDIDOS DE VENDAS  BST 25 & 26',
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'customer-taxes.json'),
    [string]$Api = 'http://localhost:8080',
    [switch]$Send,
    [switch]$Apply,
    [switch]$Overwrite,
    [switch]$CreateMissing
)

$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

public static class TaxReader
{
    class Cell { public int Row, Col; public string Text; public bool IsNum; public double Num; public string Fold; }
    static readonly XNamespace Ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    static string Fold(string s)
    {
        if (s == null) return "";
        string d = s.Normalize(NormalizationForm.FormD);
        StringBuilder sb = new StringBuilder();
        foreach (char c in d) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return Regex.Replace(sb.ToString().ToUpperInvariant(), @"\s+", " ").Trim();
    }
    static int ColIndex(string r, out int row)
    {
        int i = 0, col = 0;
        while (i < r.Length && char.IsLetter(r[i])) { col = col * 26 + (char.ToUpperInvariant(r[i]) - 'A' + 1); i++; }
        row = int.Parse(r.Substring(i), CultureInfo.InvariantCulture);
        return col;
    }
    static List<Cell> Load(ZipArchive zip)
    {
        List<string> shared = new List<string>();
        ZipArchiveEntry se = zip.GetEntry("xl/sharedStrings.xml");
        if (se != null) using (Stream st = se.Open())
            foreach (XElement si in XDocument.Load(st).Root.Elements(Ns + "si"))
                shared.Add(string.Concat(si.Descendants(Ns + "t").Select(x => x.Value)));
        ZipArchiveEntry sheet = zip.GetEntry("xl/worksheets/sheet1.xml");
        if (sheet == null) sheet = zip.Entries.Where(e => Regex.IsMatch(e.FullName, @"^xl/worksheets/sheet\d+\.xml$")).OrderBy(e => e.FullName).FirstOrDefault();
        List<Cell> cells = new List<Cell>();
        if (sheet == null) return cells;
        using (Stream st = sheet.Open())
            foreach (XElement c in XDocument.Load(st).Descendants(Ns + "c"))
            {
                XAttribute r = c.Attribute("r"); if (r == null) continue;
                int row; int col = ColIndex(r.Value, out row);
                string t = c.Attribute("t") == null ? "" : c.Attribute("t").Value;
                XElement v = c.Element(Ns + "v");
                string text = null; bool isNum = false; double num = 0;
                if (t == "s") { int idx; if (v != null && int.TryParse(v.Value, out idx) && idx < shared.Count) text = shared[idx]; }
                else if (t == "inlineStr") { XElement iss = c.Element(Ns + "is"); if (iss != null) text = string.Concat(iss.Descendants(Ns + "t").Select(x => x.Value)); }
                else if (t == "str") { if (v != null) text = v.Value; }
                else if (t == "b" || t == "e") { }
                else if (v != null && double.TryParse(v.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out num)) { isNum = true; text = num.ToString("R", CultureInfo.InvariantCulture); }
                if (string.IsNullOrWhiteSpace(text)) continue;
                cells.Add(new Cell { Row = row, Col = col, Text = text.Trim(), IsNum = isNum, Num = num, Fold = Fold(text) });
            }
        return cells;
    }
    static double? Pct(string raw)
    {
        if (raw == null) return null;
        string s = raw.Replace("%", "").Replace(" ", "").Trim();
        if (s.Length == 0) return null;
        s = s.Replace(',', '.');
        double v;
        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return null;
        return v;
    }
    // The text after the colon of a label cell ("BAIRRO:JD JAPAO"); an empty field never borrows the next label of the row.
    static string After(List<Cell> cells, Pattern p)
    {
        Cell label = cells.Where(x => Regex.IsMatch(x.Fold, p.Re)).OrderBy(x => x.Row).ThenBy(x => x.Col).FirstOrDefault();
        if (label == null) return "";
        int i = label.Text.IndexOf(':');
        if (i >= 0 && label.Text.Substring(i + 1).Trim().Length > 0) return label.Text.Substring(i + 1).Trim();
        Cell next = cells.Where(x => x.Row == label.Row && x.Col > label.Col).OrderBy(x => x.Col).FirstOrDefault();
        return next == null || next.Text.Contains(":") ? "" : next.Text;
    }
    class Pattern { public string Re; public Pattern(string re) { Re = re; } }
    static string Value(List<Cell> cells, Cell label)
    {
        int i = label.Text.IndexOf(':');
        if (i >= 0 && label.Text.Substring(i + 1).Trim().Length > 0) return label.Text.Substring(i + 1).Trim();
        Cell next = cells.Where(x => x.Row == label.Row && x.Col > label.Col).OrderBy(x => x.Col).FirstOrDefault();
        return next == null ? null : next.Text;
    }
    public static string Read(string path)
    {
        List<Cell> cells;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (ZipArchive zip = new ZipArchive(fs, ZipArchiveMode.Read))
            cells = Load(zip);
        Cell cust = cells.FirstOrDefault(x => x.Fold.StartsWith("CLIENTE:"));
        Cell icms = cells.FirstOrDefault(x => x.Fold.StartsWith("ICMS"));
        Cell ipi = cells.FirstOrDefault(x => Regex.IsMatch(x.Fold, @"^I\.?\s?P\.?\s?I"));
        Cell data = cells.Where(x => x.Fold == "DATA").OrderByDescending(x => x.Row).FirstOrDefault();
        Cell uf = cells.FirstOrDefault(x => x.Fold.StartsWith("ESTADO"));
        Cell cnpj = cells.FirstOrDefault(x => x.Fold.StartsWith("CNPJ"));
        string cnpjV = cnpj == null ? "" : Regex.Replace(Value(cells, cnpj) ?? "", @"\D", "");
        string date = "";
        if (data != null)
        {
            Cell d = cells.Where(x => x.Col == data.Col && x.Row < data.Row && x.IsNum && x.Num > 40000 && x.Num < 48000).OrderByDescending(x => x.Row).FirstOrDefault();
            if (d != null) date = DateTime.FromOADate(Math.Floor(d.Num)).ToString("yyyy-MM-dd");
        }
        double? icmsV = icms == null ? null : Pct(Value(cells, icms));
        double? ipiV = ipi == null ? null : Pct(Value(cells, ipi));
        // Stored as a fraction (0.0325) in some sheets, as a percentage (18) in others.
        Func<double?, string> f = v => v == null ? "" : (v.Value > 0 && v.Value < 1 ? v.Value * 100 : v.Value).ToString("0.####", CultureInfo.InvariantCulture);
        string name = cust == null ? "" : Value(cells, cust);
        string ufv = uf == null ? "" : (Value(cells, uf) ?? "");
        string[] extra = new[] {
            After(cells, new Pattern(@"^END\s?:")), After(cells, new Pattern(@"^BAIRRO\s?:")), After(cells, new Pattern(@"^MUNICIPIO\s?:")),
            After(cells, new Pattern(@"^CEP\s?:")), After(cells, new Pattern(@"^I\.?\s?E\s?:")), After(cells, new Pattern(@"^CONTATO\s?:")),
            After(cells, new Pattern(@"^TEL")), After(cells, new Pattern(@"^E\s?-?\s?MAIL\s?:")), After(cells, new Pattern(@"^PRAZO DE PAG"))
        };
        List<string> parts = new List<string> { Path.GetFileName(path), (name ?? "").Replace(";", ","), ufv.Replace(";", ","), date, f(icmsV), f(ipiV), cnpjV };
        parts.AddRange(extra.Select(e => (e ?? "").Replace(";", ",").Trim()));
        return string.Join(";", parts);
    }
}
'@
Add-Type -TypeDefinition $source -ReferencedAssemblies System.IO.Compression, System.Xml.Linq, System.Xml
$rows = New-Object System.Collections.Generic.List[object]
Get-ChildItem $Folder -Filter '*.xlsx' | Where-Object { $_.Name -notlike '~$*' } | ForEach-Object {
    try { $p = [TaxReader]::Read($_.FullName).Split(';') } catch { Write-Warning "$($_.Name): $($_.Exception.Message)"; return }
    $m = [regex]::Match($_.Name, '(\d+)-(\d{2})')
    $num = { param($v) if ($v -eq '') { $null } else { [decimal]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } }
    $rows.Add([pscustomobject]@{
        reference = if ($m.Success) { $m.Value } else { $null }
        date      = if ($p[3] -ne '') { $p[3] } else { $null }
        customer  = $p[1]
        document  = ($p[6] -replace '\D', '')
        uf        = $p[2]
        icms      = (& $num $p[4])
        ipi       = (& $num $p[5])
        street    = $p[7]
        district  = $p[8]
        city      = $p[9]
        zipCode   = ($p[10] -replace '\D', '')
        stateRegistration = $p[11]
        contact   = $p[12]
        phone     = $p[13]
        email     = $p[14]
        paymentTerm = $p[15]
    })
}
$body = [pscustomobject]@{ apply = [bool]$Apply; overwrite = [bool]$Overwrite; createMissing = [bool]$CreateMissing; rows = $rows }
[IO.File]::WriteAllText($Out, ($body | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "$($rows.Count) pedidos lidos -> $Out"

if ($Send) {
    $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
    $pw = (Get-Content $envFile | Where-Object { $_ -match '^EBT_ADMIN_PASSWORD=' } | Select-Object -First 1) -replace '^EBT_ADMIN_PASSWORD=', ''
    $login = Invoke-RestMethod -Method Post -Uri "$Api/api/auth/login" -ContentType 'application/json' -Body (@{ username = 'admin'; password = $pw } | ConvertTo-Json)
    $h = @{ Authorization = "Bearer $($login.token)" }
    $res = Invoke-RestMethod -Method Post -Uri "$Api/api/customers/tax-import" -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 4)))
    $res.matches | Select-Object customerId, customerName, matchedBy, orders, ipi, icms, applied | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    if ($CreateMissing) {
        Write-Host "Cadastrados agora ($($res.created.Count)):"
        $res.created | ForEach-Object { Write-Host "  $_" }
        Write-Host "Nome ambiguo, nao cadastrados ($($res.ambiguous.Count)):"
        $res.ambiguous | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "Sem cliente no cadastro ($($res.unmatched.Count)):"
    $res.unmatched | ForEach-Object { Write-Host "  $_" }
    if (-not $Apply) { Write-Host 'Pre-visualizacao: nada foi gravado. Rode de novo com -Apply.' }
}
