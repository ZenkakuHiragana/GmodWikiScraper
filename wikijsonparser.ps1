# .SYNOPSIS
#     JSON形式で取得したGarry's Mod Wikiのページを1つのJSONファイルにまとめます。
#     また、サーバー側とクライアント側にJSONファイルを分割し、JSON形式とYAML形式で出力します。
#
# .DESCRIPTION
#     pagesフォルダに格納されたJSONファイルを読み込み、1つのJSONファイルに結合します。
#     結合されたJSONファイルはwork\allpages-raw.jsonに保存されます。
#     また、改行コード等の修正を施したwork\allpages.jsonも出力します。
#     その後で不要なキーを省略したwork\allpages-slim.jsonを出力します。
#     それをサーバー側とクライアント側に分割し、work\server.jsonおよびwork\client.jsonとして出力します。
#
# .PARAMETER ConcurrentNum
#     同時並行実行数を指定します（デフォルト : 64）。
#

# スクレイピングして得られた6000のページを読み、1つのJSONにまとめる
param(
    [switch]$Help,
    [switch]$Examples,
    [switch]$Detailed,
    [switch]$Full,
    [int]$ConcurrentNum = 64)

# pagesフォルダ以下にあるJSONファイルを読み込み、1つのJSONファイルに結合する
# $Yamlスイッチが渡された時は、YAMLファイルも出力する
function Merge-Json {
    $Hash = [hashtable]::Synchronized(@{})
    $JsonAll = New-Object -TypeName System.Collections.ArrayList
    $Files = Get-ChildItem -LiteralPath ..\pages -File -Exclude "pagelist.json"
    $NumFiles = $Files.Count
    $Files | ForEach-Object -ThrottleLimit $ConcurrentNum -Parallel {
        # 進捗表示
        $Hash = $using:Hash
        $Hash['Progress']++
        if (-not $($Hash['Progress'] % $using:ConcurrentNum)) {
            $NumFiles = $using:NumFiles
            $Percent = $Hash['Progress'] / $NumFiles * 100
            $Status = "$([Math]::Round($Percent)) % | $($Hash['Progress']) / $NumFiles"
            Write-Progress -Activity "Merging..." -Status $Status -PercentComplete $Percent
        }

        # JSONを読み、$JsonAllに追記
        $Json = Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json
        $JsonAll = $using:JsonAll
        $JsonAll.Add($Json) | Out-Null
    }

    $script:Progress = 0
    $NumOutputs = $(Select-String $PSCommandPath -Pattern "Push-Progress").Count - 2
    function Push-Progress {
        $script:Progress++
        Write-Progress -Activity "Writing..." `
            -Status "$script:Progress / $NumOutputs" `
            -PercentComplete $(100 * $script:Progress / $NumOutputs)
    }

    # 全ページを固めて出力：allpages-raw.json
    ConvertTo-Json -Depth 3 $JsonAll | Out-File -Encoding utf8 -FilePath allpages-raw.json; Push-Progress

    # 改行コードがエスケープされていたりCRLFだったりして混ざっているので、その修正
    Get-Content -LiteralPath allpages-raw.json -Raw |
    ForEach-Object -ThrottleLimit $ConcurrentNum -Parallel {
        $_ -replace "(?<!\\)(\\r\\n|\\n)", "\n" `
           -replace " *\\n", "\n" `
           -replace "\\n *$", "\n"
    } |

    # 全ページを固めて出力（改行コード補正済み） : allpages-fixed.json
    Out-File -Encoding utf8 -FilePath allpages-fixed.json; Push-Progress

    # 不要な要素を消す
    $YqFilterKeys = @(
        '['
        '    .[] | {'
        '        "title":   .title,'
        '        "tags":    .tags,'
        '        "address": .address,'
        '        "markup":  .markup'
        '    } |'
        '    select(.tags | contains("remvd") | not)'
        ']'
    ) -join "`n"

    # サーバー側とクライアント側に分ける
    $YqClient = '[ .[] | select(.tags | contains("realm-client")) ]'
    $YqServer = '[ .[] | select(.tags | contains("realm-server")) ]'

    # 分けたファイルに対してさらにフィルタリングする
    $YqFunction = '[ .[] | select(.tags | contains("function")) ]'
    $YqPanel    = '[ .[] | select(.tags | contains("panel")) ]'
    $YqType     = '[ .[] | select(.tags | contains("type")) ]'
    $YqEnum     = '[ .[] | select(.tags | contains("enum")) ]'
    $YqStruct   = '[ .[] | select(.tags | contains("struct")) ]'
    $YqEvent    = '[ .[] | select(.tags | contains("event")) ]'

    # mikefarah/yq - https://github.com/mikefarah/yq
    # -r : unwrap scalar and print values with no quotes
    # -P : pretty print
    # -p : input format
    # -o : output format
    yq -p json -o json $YqFilterKeys allpages-fixed.json > allpages-slim.json; Push-Progress
    yq -p json -o json $YqClient     allpages-slim.json  > allpages-cl.json;   Push-Progress
    yq -p json -o json $YqServer     allpages-slim.json  > allpages-sv.json;   Push-Progress
    yq -p json -o json $YqType       allpages-slim.json  > types.json;         Push-Progress

    yq -p json -o json $YqFunction   allpages-cl.json    > functions-cl.json;  Push-Progress
    yq -p json -o json $YqFunction   allpages-sv.json    > functions-sv.json;  Push-Progress
    yq -p json -o json $YqPanel      allpages-cl.json    > panels-cl.json;     Push-Progress
    yq -p json -o json $YqPanel      allpages-sv.json    > panels-sv.json;     Push-Progress
    yq -p json -o json $YqEnum       allpages-cl.json    > enums-cl.json;      Push-Progress
    yq -p json -o json $YqEnum       allpages-sv.json    > enums-sv.json;      Push-Progress
    yq -p json -o json $YqStruct     allpages-cl.json    > structs-cl.json;    Push-Progress
    yq -p json -o json $YqStruct     allpages-sv.json    > structs-sv.json;    Push-Progress
    yq -p json -o json $YqEvent      allpages-cl.json    > events-cl.json;     Push-Progress
    yq -p json -o json $YqEvent      allpages-sv.json    > events-sv.json;     Push-Progress

    # YAMLの出力はUnicode文字に引っかかって改行されたりされなかったりするので、デバッグ用にのみ使う
    yq -r -P -p json -o yaml '' allpages-slim.json > allpages-slim.yml; Push-Progress
    yq -r -P -p json -o yaml '' allpages-cl.json   > allpages-cl.yml;   Push-Progress
    yq -r -P -p json -o yaml '' allpages-sv.json   > allpages-sv.yml;   Push-Progress
    yq -r -P -p json -o yaml '' types.json         > types.yml;         Push-Progress

    yq -r -P -p json -o yaml '' functions-cl.json  > functions-cl.yml;  Push-Progress
    yq -r -P -p json -o yaml '' functions-sv.json  > functions-sv.yml;  Push-Progress
    yq -r -P -p json -o yaml '' panels-cl.json     > panels-cl.yml;     Push-Progress
    yq -r -P -p json -o yaml '' panels-sv.json     > panels-sv.yml;     Push-Progress
    yq -r -P -p json -o yaml '' enums-cl.json      > enums-cl.yml;      Push-Progress
    yq -r -P -p json -o yaml '' enums-sv.json      > enums-sv.yml;      Push-Progress
    yq -r -P -p json -o yaml '' structs-cl.json    > structs-cl.yml;    Push-Progress
    yq -r -P -p json -o yaml '' structs-sv.json    > structs-sv.yml;    Push-Progress
    yq -r -P -p json -o yaml '' events-cl.json     > events-cl.yml;     Push-Progress
    yq -r -P -p json -o yaml '' events-sv.json     > events-sv.yml;     Push-Progress
}

# 文字エンコーディング指定 : UTF-8
$ConsoleOutputEncoding = [console]::OutputEncoding
$OldOutputEncoding = $OutputEncoding
[console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 出力フォルダの準備
Push-Location -LiteralPath "$PSScriptRoot"
New-Item work -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
Pop-Location
Push-Location -LiteralPath "$PSScriptRoot\work"

try {
    Merge-Json
}
finally {
    Pop-Location
    [console]::OutputEncoding = $ConsoleOutputEncoding
    $OutputEncoding = $OldOutputEncoding
}
