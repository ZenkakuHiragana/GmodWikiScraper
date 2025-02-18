# .SYNOPSIS
#     Garry's Mod Wikiの本文中に出現するタグを数えて記録します。
#
# .DESCRIPTION
#     work\allpages-slim.json、work\server.json、work\client.jsonから、
#     ページを記述するマークアップを抽出し、出現するタグと属性、および属性の値を数えます。
#     結果はwork\stats\markup*.jsonに記録されます。
#     また、ページに付けられたタグについても同様に出現数を数え、work\stats\tags*.jsonに記録します。
#
# .PARAMETER ConcurrentNum
#     同時並行実行数を指定します（デフォルト : 64）。
#

# Wikiページに付けられたタグの出現数とマークアップテキスト中のタグの出現数を分析する
param([int]$ConcurrentNum = 64)

# tagsフィールドに含まれるスペース区切りのキーワードの出現数を数え、tags.jsonに出力する
function Get-TagAppearanceCount {
    param(
        [string]$FileName = "allpages-slim.json",
        [string]$OutFile = "tags.json")
    $Hash = [hashtable]::Synchronized(@{})
    $TagCloud = [hashtable]::Synchronized(@{})
    $Json = Get-Content -LiteralPath "..\$FileName" -Raw | ConvertFrom-Json
    $NumEntry = $Json.Count
    $Json | ForEach-Object -ThrottleLimit $ConcurrentNum -Parallel {
        # 進捗表示
        $Hash = $using:Hash
        $Hash['Progress']++
        if (-not $($Hash['Progress'] % $using:ConcurrentNum)) {
            $NumEntry = $using:NumEntry
            $Percent = $Hash['Progress'] / $NumEntry * 100
            $Status = "$([Math]::Round($Percent)) % | $($Hash['Progress']) / $NumEntry"
            Write-Progress -Activity "Counting page tags for $using:FileName..." `
                -Status $Status -PercentComplete $Percent
        }

        # タグの出現数を記録する
        $TagCloud = $using:TagCloud
        -split $_.tags | ForEach-Object {
            if ($TagCloud.ContainsKey($_)) {
                $TagCloud[$_]++
            }
            else {
                $TagCloud[$_] = 1
            }
        }
    }

    # タグの出現数の出力：tags.json
    ConvertTo-Json -Depth 3 $TagCloud | Out-File -Encoding utf8 -FilePath $OutFile
    yq -i -P -p json -o json 'sort_keys(..)' $OutFile
}

# markupフィールドに含まれる本文に出現するタグの出現数を数え、markup.jsonに出力する
function Get-MarkupTagAppearanceCount {
    param(
        [string]$FileName = "allpages-slim.json",
        [string]$OutFile = "markup.json")
    $Hash = [hashtable]::Synchronized(@{})
    $TagCloud = [hashtable]::Synchronized(@{})
    $Json = Get-Content -LiteralPath "..\$FileName" -Raw | ConvertFrom-Json
    $NumEntry = $Json.Count
    $Json | ForEach-Object -ThrottleLimit $ConcurrentNum -Parallel {
        # 進捗表示
        $Hash = $using:Hash
        $Hash['Progress']++
        if (-not $($Hash['Progress'] % $using:ConcurrentNum)) {
            $NumEntry = $using:NumEntry
            $Percent = $Hash['Progress'] / $NumEntry * 100
            $Status = "$([Math]::Round($Percent)) % | $($Hash['Progress']) / $NumEntry"
            Write-Progress -Activity "Counting markup tags for $using:FileName..." `
                -Status $Status -PercentComplete $Percent
        }

        # タグの出現数を記録する
        $TagCloud = $using:TagCloud
        $RegexTagName = [regex]"<([A-Za-z0-9_-]+)([^>]*)>" # <(タグ名)(残り)> に一致
        $RegexAttributes = [regex]"\s+([A-Za-z0-9_-]+)=([`"'])(.*?)\2(.*)$" # (属性名)="(値)"(残り) に一致
        $RegexTagName.Matches($_.markup) | ForEach-Object {
            $Tag = $_.Groups[1].ToString()
            $Attributes = $_.Groups[2].ToString()
            if (-not $TagCloud.ContainsKey($Tag)) {
                $TagCloud[$Tag] = [hashtable]::Synchronized(@{})
                $TagCloud[$Tag]["##count"] = 1
            }
            else {
                $TagCloud[$Tag]["##count"]++
            }
            while (-not ([string]::IsNullOrEmpty($Attributes) `
                   -or [string]::IsNullOrWhiteSpace($Attributes)) `
                   -and -not ($Attributes -match "^\s+/")) {
                $Results = $RegexAttributes.Matches($Attributes)
                if ((-not $Results) -or ($Results.Groups.Count -lt 4)) { break }
                $Name = $Results.Groups[1].ToString()
                $Value = $Results.Groups[3].ToString()
                $Attributes = $Results.Groups[4]
                if ($null -eq $TagCloud[$Tag][$Name]) {
                    $TagCloud[$Tag][$Name] = [hashtable]::Synchronized(@{})
                }
                if (-not $TagCloud[$Tag][$Name].ContainsKey($Value)) {
                    $TagCloud[$Tag][$Name][$Value] = 1
                }
                else {
                    $TagCloud[$Tag][$Name][$Value]++
                }
            }
        }
    }

    ConvertTo-Json -Depth 4 $TagCloud | Out-File -Encoding utf8 -FilePath $OutFile
    yq -i -P -p json -o json 'sort_keys(..)' $OutFile
}

# 文字エンコーディング指定 : UTF-8
$ConsoleOutputEncoding = [console]::OutputEncoding
$OldOutputEncoding = $OutputEncoding
[console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 出力フォルダの準備
Push-Location -LiteralPath "$PSScriptRoot"
New-Item work\stats -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
Pop-Location
Push-Location -LiteralPath "$PSScriptRoot\work\stats"

try {
    Get-TagAppearanceCount "allpages-slim.json" "tags.json"
    Get-TagAppearanceCount "allpages-cl.json"   "tags-allpages-cl.json"
    Get-TagAppearanceCount "allpages-sv.json"   "tags-allpages-sv.json"
    Get-TagAppearanceCount "types.json"         "tags-types.json"
    Get-TagAppearanceCount "functions-cl.json"  "tags-functions-cl.json"
    Get-TagAppearanceCount "functions-sv.json"  "tags-functions-sv.json"
    Get-TagAppearanceCount "panels-cl.json"     "tags-panels-cl.json"
    Get-TagAppearanceCount "panels-sv.json"     "tags-panels-sv.json"
    Get-TagAppearanceCount "enums-cl.json"      "tags-enums-cl.json"
    Get-TagAppearanceCount "enums-sv.json"      "tags-enums-sv.json"
    Get-TagAppearanceCount "structs-cl.json"    "tags-structs-cl.json"
    Get-TagAppearanceCount "structs-sv.json"    "tags-structs-sv.json"
    Get-TagAppearanceCount "events-cl.json"     "tags-events-cl.json"
    Get-TagAppearanceCount "events-sv.json"     "tags-events-sv.json"
    
    Get-MarkupTagAppearanceCount "allpages-slim.json" "markup.json"
    Get-MarkupTagAppearanceCount "allpages-cl.json"   "markup-allpages-cl.json"
    Get-MarkupTagAppearanceCount "allpages-sv.json"   "markup-allpages-sv.json"
    Get-MarkupTagAppearanceCount "types.json"         "markup-types.json"
    Get-MarkupTagAppearanceCount "functions-cl.json"  "markup-functions-cl.json"
    Get-MarkupTagAppearanceCount "functions-sv.json"  "markup-functions-sv.json"
    Get-MarkupTagAppearanceCount "panels-cl.json"     "markup-panels-cl.json"
    Get-MarkupTagAppearanceCount "panels-sv.json"     "markup-panels-sv.json"
    Get-MarkupTagAppearanceCount "enums-cl.json"      "markup-enums-cl.json"
    Get-MarkupTagAppearanceCount "enums-sv.json"      "markup-enums-sv.json"
    Get-MarkupTagAppearanceCount "structs-cl.json"    "markup-structs-cl.json"
    Get-MarkupTagAppearanceCount "structs-sv.json"    "markup-structs-sv.json"
    Get-MarkupTagAppearanceCount "events-cl.json"     "markup-events-cl.json"
    Get-MarkupTagAppearanceCount "events-sv.json"     "markup-events-sv.json"
}
finally {
    Pop-Location
    [console]::OutputEncoding = $ConsoleOutputEncoding
    $OutputEncoding = $OldOutputEncoding
}
