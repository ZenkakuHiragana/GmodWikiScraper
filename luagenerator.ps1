

# TODO:
#   library fields (<function type="libraryfield">)
#   panels/overrides, panels/DHTML description

# 出力フォルダの準備
Push-Location -LiteralPath "$PSScriptRoot"
New-Item .vscode\types            -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\server\functions -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\client\functions -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\server\enums     -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\client\enums     -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\server\panels    -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\client\panels    -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\server\structs   -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\client\structs   -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\server\events    -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
New-Item .vscode\client\events    -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
. .\globalfunction.ps1
Pop-Location

# 定数のコピー
Copy-Item constants-cl.lua .vscode\client
Copy-Item constants-sv.lua .vscode\server

# アノテーションファイルの生成
function Get-Annotation {
    param([string]$FileName)
    # 出力エンコーディングの設定を保存しつつ一時的にUTF-8に設定する
    $ConsoleOutputEncoding = [console]::OutputEncoding
    $OldOutputEncoding = $OutputEncoding
    [console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $Realm = switch ($FileName -replace "^.+-") {
        "sv"    { "server\" }
        "cl"    { "client\" }
        Default { "" }
    }
    $OutDir = $FileName -replace "-.+$"
    Push-Location -LiteralPath "$PSScriptRoot\.vscode\$Realm$OutDir"
    try {
        # yqのフィルタでページタイトルやアドレスなどの必要な情報を出力のXMLに含める
        $Filter = @(
            "[ .[]"
            "    | `"<pagetitle>`" + .title + `"</pagetitle>\n`""
            "    + `"<address>`" + .address + `"</address>`" + .markup"
            "]"
        ) -join ""
        $Markup = $(yq -P -p json -o json $Filter "$PSScriptRoot\work\$FileName.json") -join "`n"
        $Lua = Get-AnnotationFromMarkup $Markup $OutDir
        foreach ($Parent in $Lua.Keys) {
            # 出てきたアノテーションテキストに対してさらに整形を行う
            # (行頭の空白を消さないとコードブロック扱いになってしまうので)
            $ReplacedText = $Lua.$Parent | ForEach-Object {
                # コードブロック中の行頭空白はインデントなので除外
                # (「```」を検知したらフラグを切り替える)
                $InCodeBlock = $false
                # 前の行の行末が空白である場合は除外 (箇条書きのインデントが崩れるので)
                # 一応、単語区切りの空白とかがマッチしないように\s{2,}で2連続以上の空白にマッチさせる
                $PreviousLineEndsWithSpaces = $false
                $_ -replace "(?m)(?<=^---).+$", {
                    if ($_ -match "^\s*``{3}") { $InCodeBlock = -not $InCodeBlock }
                    if ($InCodeBlock -or $PreviousLineEndsWithSpaces) {
                        $PreviousLineEndsWithSpaces = $_ -match "\s{2,}$"
                        $_
                    }
                    else {
                        $PreviousLineEndsWithSpaces = $_ -match "\s{2,}$"
                        $_ -replace "^\s+"
                    }
                }
            }
            $AllText = $ReplacedText -join "`n`n"
            Write-Output "---@meta`n`n$AllText" | Out-File "$Parent.lua"
        }
    }
    catch {
        Write-Error $_
        Write-Error $_.ScriptStackTrace
    }
    finally {
        Pop-Location
        [console]::OutputEncoding = $ConsoleOutputEncoding
        $OutputEncoding = $OldOutputEncoding
    }
}

Get-Annotation "types"
Get-Annotation "functions-sv"
Get-Annotation "functions-cl"
Get-Annotation "enums-sv"
Get-Annotation "enums-cl"
Get-Annotation "panels-sv"
Get-Annotation "panels-cl"
Get-Annotation "structs-sv"
Get-Annotation "structs-cl"
Get-Annotation "events-sv"
Get-Annotation "events-cl"
