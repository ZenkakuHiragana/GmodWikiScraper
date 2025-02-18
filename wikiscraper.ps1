# .SYNOPSIS
#     Garry's Mod WikiのページをJSON形式で取得し、pagesフォルダに格納します。
#
# .DESCRIPTION
#     Garry's Mod WikiのページをJSON形式で取得し、pagesフォルダに格納します。
#     ページ一覧はpages\pagelist.jsonに保存され、次回以降の実行で更新差分を調べるのに使われます。
#
# .PARAMETER ScrapeWholeWiki
#     デフォルトでは、pages\pagelist.jsonが存在する場合、
#     各ページのupdateCountを参照して更新差分を抽出します。
#     このスイッチを指定すると、更新差分を考慮せずに全てのページを取得します。
#
# .PARAMETER SkipPreviousData
#     pages\ページ名.jsonが存在する場合、更新の有無にかかわらずページの取得をスキップします。
#
# .PARAMETER UseExistingPageList
#     ページ一覧の取得をせずに、既存のpages\pagelist.jsonを使用します。
#
# .PARAMETER MaxRetry
#     ページの取得に失敗した場合の再試行回数です（デフォルト : 5）。
#
# .PARAMETER RetryWaitSeconds
#     ページの取得に失敗した場合、再試行の前に待つ秒数です（デフォルト : 2）。
#
# .PARAMETER ConcurrentNum
#     ページ取得リクエストの同時並行実行数を指定します（デフォルト : 24）。
#

param(
    [switch]$Help,
    [switch]$Examples,
    [switch]$Detailed,
    [switch]$Full,
    [switch]$ScrapeWholeWiki,
    [switch]$SkipPreviousData,
    [switch]$UseExistingPageList,
    [int]$MaxRetry = 5,
    [int]$RetryWaitSeconds = 2,
    [int]$ConcurrentNum = 24)

if ($Help -or $Detailed -or $Examples -or $Full) {
    Get-Help $MyInvocation.InvocationName
    exit
}

# ページ一覧を取得する
$script:BaseUrl = "https://wiki.facepunch.com/gmod"
function Get-PageList {
    param([bool]$Incremental)
    if ($UseExistingPageList) {
        return Get-Content -LiteralPath pagelist.json -Raw | ConvertFrom-Json
    }

    # リクエスト送信
    $Response = Invoke-WebRequest -Uri "$BaseUrl/~pagelist?format=json"
    $Json = $Response.Content
    $List = ConvertFrom-Json $Json
    
    # すでに取得済みの一覧がある場合、updateCountを比較して更新分を抽出する
    $HasPreviousJson = Test-Path -LiteralPath pagelist.json
    if ($Incremental -and $HasPreviousJson) {
        $OldJson = Get-Content -LiteralPath pagelist.json -Raw
        $OldList = ConvertFrom-Json $OldJson
        $Hash = @{}
        foreach ($Entry in $OldList) {
            $Hash[$Entry.address] = $Entry.updateCount
        }
        $List = $List | Where-Object {
            -not $Hash.ContainsKey($_.address) -or $_.updateCount -gt $Hash[$_.address]
        }
    }
    Out-File -InputObject $Json -Encoding utf8 -FilePath pagelist.json
    return $List
}

function Invoke-PageRequests {
    # ページ一覧取得
    $PageList = Get-PageList -Incremental $(-not $ScrapeWholeWiki)
    $FailedPageList = New-Object -TypeName System.Collections.ArrayList
    $NumPages = $PageList.Count

    # リクエスト送信と結果の保存を並列処理する
    $Hash = [hashtable]::Synchronized(@{ Progress = 0 })
    $PageList | ForEach-Object -ThrottleLimit $ConcurrentNum -Parallel {
        # 進捗表示
        $Hash = $using:Hash
        $Hash['Progress']++
        # 毎度更新をかけるのも重そうなので、並列数で割って進展があったらやる
        if (-not $($Hash['Progress'] % $using:ConcurrentNum)) {
            $NumPages = $using:NumPages
            $Percent = $Hash['Progress'] / $NumPages * 100
            $Status = "$([Math]::Round($Percent)) % | $($Hash['Progress']) / $NumPages"
            Write-Progress -Activity "Scraping..." -Status $Status -PercentComplete $Percent
        }
        
        # ファイル名として使えないコロンやスラッシュをURLエンコードして回避する
        $Name = $_.address
        $FileName = "$([System.Web.HttpUtility]::UrlEncode($Name)).json"

        # すでにある場合、リクエストを送信しない
        $FileExists = Test-Path -LiteralPath $FileName
        $Overwrite = -not $using:SkipPreviousData
        $FailedPageList = $using:FailedPageList
        if (-not $FileExists -or $Overwrite) {
            for ($i = 0; $i -lt $using:MaxRetry; $i++) {
                try {
                    $Uri = "${using:BaseUrl}/${Name}?format=json"
                    Invoke-WebRequest -Uri $Uri -OutFile $FileName -SkipHttpErrorCheck | Out-Null
                    break
                }
                catch {
                    $WaitSeconds = $using:RetryWaitSeconds * $i
                    Write-Error "Failed to fetch $Name, Trial = $i, Waiting for $WaitSeconds seconds..."
                    Start-Sleep -Seconds $WaitSeconds
                }
            }
            if ($i -ge $using:MaxRetry) {
                $FailedPageList.Add($Name) | Out-Null
            }
        }
    }
    if ($FailedPageList.Count -gt 0) {
        Write-Output "$($FailedPageList.Count) pages could not retrieved:"
        $FailedPageList | ForEach-Object {
            Write-Output "    $_.address"
        }
    }
}

# 出力フォルダ準備
Push-Location -LiteralPath "$PSScriptRoot"
New-Item pages -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
Pop-Location
Push-Location -LiteralPath "$PSScriptRoot\pages"

# 文字エンコーディング指定 : UTF-8
$ConsoleOutputEncoding = [console]::OutputEncoding
$OldOutputEncoding = $OutputEncoding
[console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
try {
    Invoke-PageRequests
}
finally {
    Pop-Location
    [console]::OutputEncoding = $ConsoleOutputEncoding
    $OutputEncoding = $OldOutputEncoding
}
