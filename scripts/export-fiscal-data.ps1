<#
.SYNOPSIS
  Builds fiscal-data.json, the file MetaGest imports in Configuracoes > Administracao > Dados fiscais, from the DBFs of the old billing system.

.DESCRIPTION
  Reads (no writes, no database):
    NFCONTR.DBF (SI\NF)   issuer: razao social, CNPJ, IE, address, IBGE, CEP, phone, CRT, next NF number
    NF520.DBF             IBGE municipality table (city name of the issuer)
    NF270.DBF             carriers
    NF050.DBF             default ICMS rate per UF
    NF080.DBF / NF090.DBF CFOP master and tax regime per CFOP (CSTs, IPI framing, IPI/PIS/COFINS rates)
    NF070.DBF + NF020.DBF default CFOP per customer x product x address (the address gives the UF)
    NF100.DBF             monthly price per customer x product x CFOP
  Output sections (see Ebt.Core/Fiscal/FiscalDataImporter.cs):
    issuer, cfops (only 6101: the interstate twin of 5101), carriers, taxRules (one per product x customer x CFOP: ICMS CST and rate of the customer's UF,
    IPI variant of the legacy CFOP suffix: .00 = CST 50 with 3.25%, .01 = CST 55 without IPI, PIS/COFINS from NF090), monthlyPrices (last -Months months).
  The legacy CFOP suffix (5101.00 / 5101.01 / 5101.02) is dropped from the code: it only selected the IPI variant, which is now carried by the tax rule.
  The file holds real prices and customer data: it is git-ignored (fiscal-data*.json). Nothing is written to the database; import it from the app (admin).

  Windows PowerShell 5.1. ASCII only.
.EXAMPLE
  powershell -File scripts\export-fiscal-data.ps1
  powershell -File scripts\export-fiscal-data.ps1 -Db C:\Users\italo\Desktop\EBT\DHBSTDB -NfContr C:\Users\italo\Desktop\BST\DHBst\SI\NF\NFCONTR.DBF -Source BST -Out fiscal-data-bst.json
#>
param(
    [string]$Db = 'C:\Users\italo\Desktop\EBT\DHEBTDB',
    [string]$NfContr = 'C:\Users\italo\Desktop\EBT\SI\NF\NFCONTR.DBF',
    [string]$Source = 'EBT',
    [int]$Months = 6,
    [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'fiscal-data.json')
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$enc = [Text.Encoding]::GetEncoding(850)

function Read-Dbf([string]$Path) {
    if (-not (Test-Path $Path)) { Write-Warning "Not found: $Path"; return @() }
    $b = [IO.File]::ReadAllBytes($Path)
    $cnt = [BitConverter]::ToInt32($b, 4); $hl = [BitConverter]::ToInt16($b, 8); $rl = [BitConverter]::ToInt16($b, 10)
    $f = @(); $o = 1; $p = 32
    while ($b[$p] -ne 0x0D -and $p -lt $hl) {
        $nm = $enc.GetString($b, $p, 11).Split([char]0)[0]
        $f += [pscustomobject]@{ n = $nm; l = [int]$b[$p + 16]; o = $o }
        $o += $b[$p + 16]; $p += 32
    }
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $cnt; $i++) {
        $s = $hl + $i * $rl
        if ($b[$s] -eq 0x2A) { continue }
        $h = @{}
        foreach ($x in $f) { $h[$x.n] = $enc.GetString($b, $s + $x.o, $x.l).Trim() }
        $rows.Add($h)
    }
    return $rows
}

function Num($s) { $d = 0.0; if ([decimal]::TryParse(("$s").Replace(',', '.'), [Globalization.NumberStyles]::Number, $inv, [ref]$d)) { return [decimal]$d } else { return [decimal]0 } }
function Digits($s) { return (("$s") -replace '\D', '') }
function Key($s) { $t = ("$s").Trim(); if ($t -match '^\d+$') { return [string][int64]$t } else { return $t } }

# ---- issuer
$c = (Read-Dbf $NfContr) | Select-Object -First 1
if (-not $c) { throw "NFCONTR not found or empty: $NfContr" }
$ibge = Digits $c['IDMUNICIPI']
$city = $null
foreach ($m in (Read-Dbf (Join-Path $Db 'NF520.DBF'))) { if ((Digits $m['N52IDMUNIC']) -eq $ibge) { $city = $m['N52DSMUNIC']; break } }
$issuer = [ordered]@{
    companyName = $c['DSRAZAOSOC']; tradeName = $c['DSFANTASIA']; cnpj = Digits $c['IDCNPJ']; stateRegistration = Digits $c['IDIE']
    taxRegime = [int](Num $c['CRT']); street = $c['DSENDERECO']; number = "$([int](Num $c['NUMERO']))"; complement = $c['DSCOMPLEME']; district = $c['DSBAIRRO']
    city = $city; cityIbgeCode = $ibge; uf = $c['CDUF']; zipCode = Digits $c['IDCEP']; phone = Digits $c['TELEFONE']; nextNumber = [int](Num $c['NRNF'])
}
if (-not $city) { Write-Warning "City for IBGE $ibge not found in NF520: fill it in the app." }

# ---- carriers
$carriers = @()
foreach ($t in (Read-Dbf (Join-Path $Db 'NF270.DBF'))) {
    $name = $t['F27RSTRANS']; if (-not $name) { $name = $t['F27NMTRANS'] }
    if (-not $name) { continue }
    $carriers += [ordered]@{ name = $name; document = Digits $t['F27CGCTR']; stateRegistration = Digits $t['F27IETR']; address = $t['F27ENDERTR']; city = $t['F27CIDADTR']; uf = $t['F27CDESTTR'] }
}

# ---- rates and regimes
$ufRate = @{}
foreach ($u in (Read-Dbf (Join-Path $Db 'NF050.DBF'))) { $ufRate[$u['F05CDESTAD']] = Num $u['F05ICMSPAD'] }
$regime = @{}
foreach ($r in (Read-Dbf (Join-Path $Db 'NF090.DBF'))) { $regime[$r['F09CDOPRC']] = $r }
$cfopDesc = @{}
foreach ($r in (Read-Dbf (Join-Path $Db 'NF080.DBF'))) { $cfopDesc[$r['F08CDOPRC']] = $r['F08DSOPRC'] }

$cfops = @()
if ($regime.ContainsKey('6101.00')) {
    $r = $regime['6101.00']
    $cfops += [ordered]@{
        code = '6101'; description = $cfopDesc['6101.00']; taxed = $true; icmsCst = $r['F09STICMS']; ipiCst = $r['F09STIPI']; pisCst = $r['F09STPIS']; cofinsCst = $r['F09STCOFIN']
        defaultPisPercent = Num $r['F09ALQPIS']; defaultCofinsPercent = Num $r['F09ALQCOFI']; ipiFramingCode = $r['F09ENQIPI']; generatesInstallments = $true
    }
}

# ---- tax rules: customer x product x address -> UF
$addrUf = @{}
foreach ($a in (Read-Dbf (Join-Path $Db 'NF020.DBF'))) { $addrUf["$(Key $a['F02CDCLIE'])|$(Key $a['F02CDENDER'])"] = $a['F02CDESTAD'] }
$rules = @(); $seenRule = @{}; $noRegime = 0; $noUf = 0
foreach ($p in (Read-Dbf (Join-Path $Db 'NF070.DBF'))) {
    $code = $p['F07CDOPRC']
    if (-not $regime.ContainsKey($code)) { $noRegime++; continue }
    $uf = $addrUf["$(Key $p['F07CDCLIE'])|$(Key $p['F07CDENDER'])"]
    $r = $regime[$code]
    if ($r['F09ICMESTA'] -eq 'S') {
        if (-not $uf -or -not $ufRate.ContainsKey($uf)) { $noUf++; continue }
        $icms = $ufRate[$uf]
    } else { $icms = Num $r['F09ALQICMS'] }
    $cfop4 = $code.Substring(0, 4)
    $k = "$(Key $p['F07CDCLIE'])|$($p['F07CDPECA'])|$cfop4"
    if ($seenRule.ContainsKey($k)) { continue }
    $seenRule[$k] = $true
    $rules += [ordered]@{
        productCode = $p['F07CDPECA']; customerCode = Key $p['F07CDCLIE']; cfop = $cfop4; icmsCst = $r['F09STICMS']; icmsPercent = $icms
        ipiCst = $r['F09STIPI']; ipiPercent = Num $r['F09ALQIPI']; pisPercent = Num $r['F09ALQPIS']; cofinsPercent = Num $r['F09ALQCOFI']
    }
}

# ---- monthly prices of the last -Months months (the latest change of a month wins; rows priced in another unit than the taxed one are left out)
$limit = (Get-Date).AddMonths(-$Months).ToString('yyyyMM')
$best = @{}; $otherUnit = 0
foreach ($p in (Read-Dbf (Join-Path $Db 'NF100.DBF'))) {
    $ym = $p['F10ANOMES']
    if ($ym -lt $limit) { continue }
    $code = $p['F10CDOPRC']; if ($code.Length -lt 4) { continue }
    if ($p['F10UNIDADE'] -ne $p['F10UNTRIBU'] -or (Num $p['F10FATOR']) -ne 1) { $otherUnit++; continue }
    $k = "$(Key $p['F10CDCLIE'])|$($p['F10CDPECA'])|$($code.Substring(0, 4))|$ym"
    if (-not $best.ContainsKey($k) -or $p['F10DTALT'] -gt $best[$k]['F10DTALT']) { $best[$k] = $p }
}
$prices = @()
foreach ($p in $best.Values) {
    $prices += [ordered]@{
        productCode = $p['F10CDPECA']; customerCode = Key $p['F10CDCLIE']; cfop = $p['F10CDOPRC'].Substring(0, 4)
        year = [int]$p['F10ANOMES'].Substring(0, 4); month = [int]$p['F10ANOMES'].Substring(4, 2); unitPrice = Num $p['F10VALOR']
    }
}

$bundle = [ordered]@{ source = $Source; generatedAt = (Get-Date).ToString('s'); issuer = $issuer; cfops = $cfops; carriers = $carriers; taxRules = $rules; monthlyPrices = $prices }
$json = $bundle | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "Wrote $Out"
Write-Host ("issuer {0} | carriers {1} | cfops {2} | tax rules {3} (no regime {4}, no UF rate {5}) | monthly prices {6} (other unit {7})" -f $issuer.companyName, $carriers.Count, $cfops.Count, $rules.Count, $noRegime, $noUf, $prices.Count, $otherUnit)
