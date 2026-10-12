
# 関数のマークアップを解読し、Luaアノテーションに変換する
$ClientImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAAAAAAAAAQCEeRdzAAAAq0lEQVR4nGP4///f/z8/3/9/d7nx/6Otuv/vrRb4f381P1YMkgOpAakF6QHpZfjz88P/5/td/99ewvD/7nLW//dWcuDFIDUgtSA9IL0Mby81gQUgCjiJxBxgPSC9DI+3av+/s5ydBM0QDNID0ssA9huJmmEYpHfUgMFhwBpBygygJCE92qoJSsqNFCTlRnIyEwtqZkJk5zqgk3TwZmdQeD3apvf/3aU6eHYGACIuqFE1BxacAAAAAElFTkSuQmCC"
$ServerImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAAAAAAAAAQCEeRdzAAAAwklEQVR4nN2TSw7CMAxEDayaXgPxuQbXQvQyRVSobLvnDMA5+KaIVgLjcZVKbEpLdliaTTLPSiwPsdSxeHF0KHmS5WxSy4HIpPmHqjOrHnjBoOhUPHm2LZiWF6bkxv21bRQ88IIBS9HuwRSf9XLQUtpIGGVH2Z1pdW0NO4FRFv/qCjuBpUAG9GsDsGQ8Gpg/aeA9xHDj+QJdhqT7IvWEGYJd+K5yHaYYYWoOUhUmq946TC7O833J4y9xDkVT8cDr4vwGW6m3gNvmRPwAAAAASUVORK5CYII="
$SharedImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAACXBIWXMAAAAAAAAAAQCEeRdzAAABJklEQVR4nJ3TvUrDYBjF8UeL2mRR70FEULwHBW/IWQt6KbaYxjgJGZyqk3vjItpWKtKpn6bS16b9mzcpQqFNG4ezhJMf4fBExkBDQe75hz23j+n4GGFMpz+V+JkfdXS3pfSbIKNhl7PSPZJXiPXFqu0nRnek0OX4QdFWI6TpXeIVshzZd0gxIBOWFiWC8h1y5QHy4e5TLa5Tsc0JMlwKkeseu+43UnM2qdoG7zfZ1Ije5A/4D2KE404BaRFzFpAGmQssiyQCyyALgUVIPOLtdiKQhERfoA/pzdpIiQSsWD129CE1yxe8FiQsZdMhV358yoHq0CidREjFWptA81MrZnjJC6ePT7QGAQJjAtWm5eWouwdUnS30sDMT7lV3D+l456A+o9/5F23WsF7ghkQuAAAAAElFTkSuQmCC"

# Lua標準関数のアノテーションはしない
$BuiltinFunctions = Get-Content builtin.json | ConvertFrom-Json

# Wikiで拾いきれない型情報を書くところ
$OverrideJson = Get-Content "$PSScriptRoot\overrides.json" -Encoding utf8 | ConvertFrom-Json

# NodeからXPathを取得する
# Given a [System.Xml.XmlNode] instance, returns the path to it
# inside its document in XPath form.
# Supports element, attribute, and text/CDATA nodes.
# https://stackoverflow.com/questions/24043313/find-xml-nodes-full-xpath
function Get-XPath {
    param (
        [ValidateNotNull()]
        [System.Xml.XmlNode] $node
    )

    if ($node -is [System.Xml.XmlDocument]) { return '' } # Root reached
    $isAttrib = $node -is [System.Xml.XmlAttribute]

    # IMPORTANT: Use get_*() accessors for all type-native property access,
    #            to prevent name collision with Powershell's adapted-DOM ETS properties.

    # Get the node's name.
    $name = if ($isAttrib) {
        '@' + $node.get_Name()
    } elseif ($node -is [System.Xml.XmlText] -or $node -is [System.Xml.XmlCDataSection]) {
        'text()'
    } else { # element
        $node.get_Name()
    }

    # Count any preceding siblings with the same name.
    # Note: To avoid having to provide a namespace manager, we do NOT use
    #       an XPath query to get the previous siblings.
    $prevSibsCount = 0; $prevSib = $node.get_PreviousSibling()
    while ($prevSib) {
        if ($prevSib.get_Name() -ceq $name) { ++$prevSibsCount }
        $prevSib = $prevSib.get_PreviousSibling()
    }

    # Determine the (1-based) index among like-named siblings, if applicable.
    $ndx = if ($prevSibsCount) { '[{0}]' -f (1 + $prevSibsCount) }

    # Determine the owner / parent element.
    $ownerOrParentElem = if ($isAttrib) { $node.get_OwnerElement() } else { $node.get_ParentNode() }

    # Recurse upward and concatenate with "/"
    "{0}/{1}" -f (Get-XPath $ownerOrParentElem), ($name + $ndx)
}
# XPathによる検索は大文字小文字を区別するが、
# Wikiのマークアップがそうとは限らないので区別しないXPathを作る
function XPathByNameInsensitive {
    param([string]$Name)
    $UpperCase = $Name.ToUpperInvariant()
    $LowerCase = $Name.ToLowerInvariant()
    "*[translate(name(), '$UpperCase', '$LowerCase') = '$LowerCase']"
}
# 行コメントを追加する
function Add-CommentHeader {
    foreach ($Element in $Input) {
        $Element -replace "^(?!---)", "---" -replace "\n(?!---)", "`n---" -replace "\n---$", "`n"
    }
}
# 引数の要素について子要素を全部変換する
function Get-Comments {
    param([System.Xml.XmlNode]$Element)
    $Text = $($Element.get_ChildNodes() | Get-AllText) -join "" -replace "\n\s*$" | Add-CommentHeader
    $Text = $Text -replace "(?m)^---\|", "---"
    "$Text`n"
}
# <arg>タグからデフォルト値を抽出する。ない場合は空文字列の文字列（'""'）とする
function Get-ArgumentDefault {
    param([System.Xml.XmlNode]$Element)
    $Default = $Element.default
    if ($Default -eq "") { $Default = '""' }
    "$Default"
}
# <arg>タグにdefault属性があるかどうかを返す
function Get-ArgumentHasDefault {
    param([System.Xml.XmlNode]$Element)
    ($null -ne $Element.Attributes) -and `
    ($null -ne $Element.Attributes["default"])
}
# <arg>タグのname属性にある引数名をLuaのキーワードと衝突しないようにする
function Get-SafeName {
    param([string]$Name)
    if (@(
        # Lua keywords
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
        "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
        "true", "until", "while",

        # Lua types
        "nil", "boolean", "number", "string", "userdata", "function", "thread", "table",

        # Built-in Lua functions
        "assert", "collectgarbage", "dofile", "error", "getmetatable", "ipairs", "load",
        "loadfile", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawset",
        "select", "setmetatable", "tonumber", "tostring", "type", "xpcall"
    ) -contains $Name) {
        "_$Name"
    }
    else {
        # スペースが入っていたり使えない文字を含んでいたりするので、それも直す
        $Name -replace "\s+", "_" -replace "/", "_or_"
    }
}
# <arg>タグと<ret>タグから引数の型を取得する
# table型で説明に構造体へのリンクがある場合はそちらを使用する
# number型で説明に列挙型へのリンクがある場合はそちらを使用する
function Get-ElementType {
    param(
        [System.Xml.XmlNode]$Element,
        [switch]$Alt)
    $Type = $Alt ? $Element.alttype : $Element.type
    $Children = $Element.SelectNodes($(XPathByNameInsensitive "page"))
    $TryReplace = $null
    if ($Children.Count -gt 0) {
        function Find-LinkToType {
            param([string]$SearchString)
            $Types = $Children | ForEach-Object {
                $Link = $_.InnerText
                if ($Link -match $SearchString) {
                    $Link -replace "s/", "."
                }
                $null
            }
            $TypesJoin = $Types.Where({ $null -ne $_ }) -join "|"
            $TypesJoin.Trim()
        }
        if ($Type -match "table") {
            $TryReplace = Find-LinkToType "Structures/"
        }
        elseif ($Type -match "number") {
            $TryReplace = Find-LinkToType "Enums/"
        }
    }
    if ([string]::IsNullOrEmpty($TryReplace)) {
        # file_class 型はFileクラスなので例外的に置き換える
        $Type -replace "file_class", "File" `
        <# number{T} => number #> `
        -replace "number{([A-Za-z0-9/._-]+)}", "number" `
        <# table<T> => T[] #> `
        -replace "table<([A-Za-z0-9/._-]+)>", "`$1[]" `
        <# table{T} => T #> `
        -replace "table{([A-Za-z0-9/._-]+)}", "Structure.`$1"
    }
    else {
        $TryReplace
    }
}
# 型へのリンクを得る
function Get-TypeLinkText() {
    param([string]$Type)
    $Type = $Type `
        -replace "\[\]" `
        -replace "<[A-Za-z0-9/._-]+?>" `
        -replace "fun\(.+?\)(:.+)?", "function"
    $TableKV = [regex]::Matches($Type, "table[<{](.+?),\s*(.+?)[>}]")
    $TableT = [regex]::Matches($Type, "table[<{]([^>}]+)[>}]")
    if ($TableKV) {
        $K = $TableKV.Groups[1].Value
        $V = $TableKV.Groups[2].Value
        "[table](https://wiki.facepunch.com/gmod/table)<[$K](https://wiki.facepunch.com/gmod/$K), [$V](https://wiki.facepunch.com/gmod/$V)>"
    }
    elseif ($TableT) {
        $T = $TableT.Groups[1].Value
        "[table](https://wiki.facepunch.com/gmod/table)<[$T](https://wiki.facepunch.com/gmod/$T)>"
    }
    else {
        "[$Type](https://wiki.facepunch.com/gmod/$Type)"
    }
}
# <callback>タグがある時、その関数シグネチャをfun([args[, ...]])[: returns[, ...]]の形で返す
function Get-CallbackType {
    param([System.Xml.XmlNode]$Element)
    $Callback = $Element.SelectNodes($(XPathByNameInsensitive "callback"))[0]
    if ($null -eq $Callback) { return $null }
    $Arguments = $Callback.SelectNodes($(XPathByNameInsensitive "arg"))
    $Returns = $Callback.SelectNodes($(XPathByNameInsensitive "ret"))
    $Text = "fun($($($Arguments | Get-AllText) -join ", "))"
    if ($Returns.Count -gt 0) {
        "${Text}: $($Returns | Get-AllText -join ", ")"
    }
    else {
        "$Text"
    }
}
# 子要素を全部変換する
function Get-AllText {
    foreach ($Element in $Input) {
        if ($null -eq $Element) { continue }
        # Element or Text
        # プロパティの読み取りと属性の読み取りが重複する場合があるが、
        # なぜかこうすると必ずプロパティの方を呼べる
        $NodeType = $Element.get_NodeType()
        $ElementName = $Element.get_Name()
        if ($NodeType -eq "Text") {
            [string]$Element.get_Value() `
                -replace "&amp;", "&" `
                -replace "&lt;", "<" `
                -replace "&gt;", ">"
        }
        else {
            switch ($ElementName) {
                br            { Get-Br          $Element; break }
                info          { "";                       break }
                item          { "";                       break }
                items         { "";                       break }
                added         { "";                       break }
                ambig         { "";                       break }
                appendedenums { "";                       break }
                bug           { Get-Bug         $Element; break }
                description   { Get-Description $Element; break }
                deprecated    { Get-Deprecated  $Element; break }
                internal      { Get-Internal    $Element; break }
                note          { Get-Note        $Element; break }
                removed       { Get-Removed     $Element; break }
                validate      { Get-Validate    $Element; break }
                warning       { Get-Warning     $Element; break }
                image         { Get-Image       $Element; break }
                upload        { Get-Image       $Element; break }
                key           { Get-Key         $Element; break }
                name          { Get-Name        $Element; break }
                callback      { Get-Callback    $Element; break }
                args          { Get-Args        $Element; break }
                arg           { Get-Arg         $Element; break }
                rets          { Get-Rets        $Element; break }
                ret           { Get-Ret         $Element; break }
                page          { Get-Page        $Element; break }
                example       { Get-Example     $Element; break }
                code          { Get-Code        $Element; break }
                output        { Get-Output      $Element; break }
                pagelist      { Get-PageList    $Element; break }
                Default       {
                    $str = "<Unknown tag: $ElementName>"
                    $m = 31
                    $n = $str.Length
                    $n += [System.Math]::Floor(($m - $n) / 2)
                    $str.PadLeft($n, "?").PadRight($m, "?")
                }
            }
        }
    }
}
# <br/>タグはとりあえず改行にするが、<code>ブロックの中は例外とする
function Get-Br {
    param([System.Xml.XmlNode]$Element)
    $Parent = $Element.ParentNode
    if ($Parent.get_Name().ToLowerInvariant() -eq "code") {
        ""
    }
    else {
        "`n"
    }
}
# <args>タグを整形し、@param要素にする
function Get-Args {
    param([System.Xml.XmlNode]$Element, [switch]$IsCallback)
    $Children = $Element.get_ChildNodes()
    $Text = for ($i = 0; $i -lt $Children.Count; $i++) {
        if ($Children[$i].get_Name() -ne "arg") {
            $null
        }
        else {
            Get-Arg $Children[$i] `
                -FallbackName "arg$($i + 1)" -IsCallback:$IsCallback
        }
    }
    if ($IsCallback) {
        $Text.Where({ -not [string]::IsNullOrEmpty($_) }) -join ", "
    }
    else {
        $Text = $Text.Where({ -not [string]::IsNullOrEmpty($_) }) `
            -join "" -replace "\n\s*$" | Add-CommentHeader
        "$Text`n" -replace "(^|\n)---\s*", "`$1---@param "
    }
}
# <rets>タグを整形し、@return要素にする
function Get-Rets {
    param([System.Xml.XmlNode]$Element, [switch]$IsCallback)
    if ($IsCallback) {
        $($Element.get_ChildNodes() | ForEach-Object { Get-Ret $_ -IsCallback }) -join ", "
    }
    else {
        $(Get-Comments $Element) -replace "(^|\n)---\s*", "`$1---@return "
    }
}
# <description>タグを整形し、関数説明部分に置くMarkdown文字列にする
function Get-Description {
    param([System.Xml.XmlNode]$Element)
    $Parent = $Element.ParentNode
    $ParentNodeName = $Parent.get_Name().ToLowerInvariant()
    # <example>タグの中にある<description>はただのテキスト
    if ($ParentNodeName -eq "example") {
        $Text = $($Element.get_ChildNodes() | Get-AllText) -join ""
        return "$Text`n"
    }
    else {
        $Address = switch($ParentNodeName) {
            "function" {
                $Name = $Parent.name
                $ParentName = $Parent.parent
                $Type = $Parent.type
                switch ($Type.ToLowerInvariant()) {
                    "classfunc"   { "${ParentName}:$Name" }
                    "libraryfunc" { "${ParentName}.$Name" }
                    "panelfunc"   { "${ParentName}:$Name" }
                }
            }
            "enum" {
                $Element.SelectSingleNode("../../address").InnerText
            }
        }
        $Realm = $Parent.SelectSingleNode($(XPathByNameInsensitive "realm"))
        $RealmText = $Realm.InnerText.ToLowerInvariant()
        $IsClient = $RealmText.Contains("client")
        $IsServer = $RealmText.Contains("server")
        $IsShared = $RealmText.Contains("shared")
        if ($IsClient) { $RealmImage = $ClientImage }
        if ($IsServer) { $RealmImage = $ServerImage }
        if ($IsShared) { $RealmImage = $SharedImage }
        $Text = "### ![]($RealmImage) Description [(📓Wiki)](https://wiki.facepunch.com/gmod/$Address)`n`n" | Add-CommentHeader
        "$Text$(Get-Comments $Element)"
    }
}
# <example>タグを整形し、関数説明部分に置くMarkdown文字列にする
function Get-Example {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n### Example`n`n" | Add-CommentHeader
    $Text + $(Get-Comments $Element)
}
# <arg>タグを整形する。$IsDescriptionが指定されている時は説明文中のコールバック関数を説明する部分を返す。
# そうでない時は、関数シグネチャや---@param要素の本文を返す。この時、名前のない引数名には$FallbackNameが用いられる。
function Get-Arg {
    param(
        [System.Xml.XmlNode]$Element,
        [string]$FallbackName = "",
        [switch]$IsDescription,
        [switch]$IsCallback)
    $ElementName = $Element.get_Name()
    if ($ElementName -ne "arg")
    {
        return $null
    }
    $Parent = $Element.ParentNode
    $ParentName = $Parent.get_Name().ToLowerInvariant()
    $Name = $Element.name
    $Type = Get-ElementType $Element
    $AltType = Get-ElementType $Element -Alt
    $Nullable = $(Get-ArgumentHasDefault $Element) ? "?" : ""

    # コールバック関数の引数を説明するMarkdown構文を返す
    if ($IsDescription) {
        $Text = "`n1. **" + (Get-TypeLinkText $Type)
        if ($AltType) { $Text += " | " + (Get-TypeLinkText $AltType) }
        if ($Name) { $Text += " $Name" }
        $Text += "**  `n   "
        $Text += $($Element.get_ChildNodes() | Get-AllText) `
                -join "" -replace "(?<=(^|\n))\s+" -replace "\n", "  `n   "
        return $Text
    }

    # 以下、---@param要素もしくはコールバック関数のシグネチャ型の引数部分を返す
    # 型定義が2つ用意されている場合はそれに従う
    if ($AltType) { $Type += "|$AltType" }

    # 名前のない引数は定義できないので、フォールバックする
    if ([string]::IsNullOrEmpty($Name)) { $Name = $FallbackName }

    # コールバック関数のシグネチャの場合、元の型名は"function"となっているので置き換える
    $CallbackFunType = Get-CallbackType $Element
    if ($null -ne $CallbackFunType) {
        $Type = $Type -replace "function", $CallbackFunType
    }

    # 可変長引数の場合は"vararg"という型名になっているので置き換える
    # Lua Language Serverでは可変長引数の型も指定できるが、GMOD Wikiには指定がないのでanyとする。
    if ($Type -match "vararg") {
        $Name = "..."
        $Nullable = ""
        $Type = "any"
    }
    if ($IsCallback -or $ParentName -eq "callback") { # 関数シグネチャの場合
        return "$(Get-SafeName $Name)${Nullable}: $Type"
    }
    elseif ($ParentName -eq "args") { # ---@param要素の場合
        return "$(Get-SafeName $Name)$Nullable $Type`n"
    }
}
# <ret>タグを整形し、@return要素にする
function Get-Ret {
    param(
        [System.Xml.XmlNode]$Element,
        [switch]$IsDescription,
        [switch]$IsCallback)
    $ElementName = $Element.get_Name()
    if ($ElementName -ne "ret")
    {
        return $null
    }
    $Parent = $Element.ParentNode
    $ParentName = $Parent.get_Name().ToLowerInvariant()
    $Name = $Element.name
    $Type = Get-ElementType $Element

    # コールバック関数の引数を説明するMarkdown構文を返す
    if ($IsDescription) {
        $Text = "`n1. **" + (Get-TypeLinkText $Type)
        if ($Name) { $Text += " $Name" }
        $Text += "**  `n   "
        $Text += $($Element.get_ChildNodes() | Get-AllText) `
                -join "" -replace "(?<=(^|\n))\s+" -replace "\n", "  `n   "
        return $Text
    }

    # 以下、---@param要素もしくはコールバック関数のシグネチャ型の引数部分を返す
    # コールバック関数のシグネチャの場合、元の型名は"function"となっているので置き換える
    $CallbackFunType = Get-CallbackType $Element
    if ($null -ne $CallbackFunType) {
        $Type = $Type -replace "function", $CallbackFunType
    }

    # 可変長引数の場合は"vararg"という型名になっているので置き換える
    # Lua Language Serverでは可変長引数の型も指定できるが、GMOD Wikiには指定がないのでanyとする。
    if ($Type -match "vararg") {
        $Name = "..."
        $Nullable = ""
        $Type = "any"
    }

    if ($IsCallback -or ($ParentName -eq "callback")) { # 関数シグネチャの場合
        if ($Name) {
            return "${Name}: $Type"
        }
        else {
            return $Type
        }
    }
    elseif ($ParentName -eq "rets") { # ---@return要素の場合
        return "$Type$Nullable $Name`n"
    }
}
# <page>タグを整形し、Markdownリンクにする
function Get-Page {
    param([System.Xml.XmlNode]$Element)
    $TextAttribute = $Element.text
    [string]$PageText = $($Element.get_ChildNodes() | Get-AllText) -join ""
    $LinkText = $TextAttribute.Value

    # 表示するテキストが指定されていない場合、中身をそのまま表示する
    # ただし、Global.から始まる場合はそこを省く
    if ([string]::IsNullOrEmpty($TextAttribute.Value) `
    -or [string]::IsNullOrWhiteSpace($TextAttribute.Value)) {
        $LinkText = $PageText -replace "Global."
    }
    "[$LinkText](https://wiki.facepunch.com/gmod/$PageText)"
}
# <bug>ブロックを整形し、それっぽいMarkdownを作る
function Get-Bug {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### 🐞 BUG`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <deprecated>ブロックを整形し、それっぽいMarkdownを作る
function Get-Deprecated {
    param([System.Xml.XmlNode]$Element)
    $Text = @(
        ""
        "#### 🔥 DEPRECATED"
        ""
        "@deprecated We advise against using this. It may be changed or removed in a future update."
        ""
    ) -join "`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <internal>ブロックを整形し、それっぽいMarkdownを作る
function Get-Internal {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### 🛠️ INTERNAL`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <note>ブロックを整形し、それっぽいMarkdownを作る
function Get-Note {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### 🗒️ NOTE`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <removed>ブロックを整形し、それっぽいMarkdownを作る
function Get-Removed {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### ❌ REMOVED`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <validate>ブロックを整形し、それっぽいMarkdownを作る
function Get-Validate {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### ❓ NEED TO VALIDATE`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <warning>ブロックを整形し、それっぽいMarkdownを作る
function Get-Warning {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### ⚠️ WARNING`n`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <upload>, <image>タグを整形し、画像にする
function Get-Image {
    param([System.Xml.XmlNode]$Element)
    $Name = $Element.alt ? $Element.alt : $Element.name
    $Source = $Element.src
    "![$Name](https://files.facepunch.com/wiki/files/$Source)`n"
}
# <key>タグを整形し、Markdown構文にする
function Get-Key {
    param([System.Xml.XmlNode]$Element)
    $Text = $($Element.get_ChildNodes() | Get-AllText) -join ""
    "**[$Text]**`n"
}
# <name>タグをプレーンテキストに直す
function Get-Name {
    param([System.Xml.XmlNode]$Element)
    $($Element.get_ChildNodes() | Get-AllText) -join ""
}
# <callback>タグを整形し、Markdown構文にする
function Get-Callback {
    param([System.Xml.XmlNode]$Element)
    $Arguments = $Element.SelectNodes($(XPathByNameInsensitive "arg"))
    $Returns = $Element.SelectNodes($(XPathByNameInsensitive "ret"))
    $Text = ""
    if ($Arguments.Count -gt 0) {
        $Text += "Function argument(s):`n"
        $Text += $($Arguments | ForEach-Object { Get-Arg $_ -IsDescription }) -join "`n"
    }
    if ($Returns.Count -gt 0) {
        $Text += "`n`nFunction return value(s):`n"
        $Text += $($Returns | ForEach-Object { Get-Ret $_ -IsDescription }) -join "`n"
    }
    "$Text`n"
}
# <code>ブロックを整形し、Markdown構文にする
function Get-Code {
    param([System.Xml.XmlNode]$Element)
    $Text = $($Element.get_ChildNodes() | Get-AllText) -join "" -replace "(?<=\n)\s*$"
    if ($Text -match "(?s)^[^\n]") { $Text = "`n$Text" } # 最初の行を空行にする
    if ($Text -match "(?s)[^\n]\s*$") { $Text += "`n" } # 最後の行を空行にする
    "`n``````lua$Text```````n"
}
# <output>タグを整形する
function Get-Output {
    param([System.Xml.XmlNode]$Element)
    $Text = "`n#### Output`n"
    $Text += $($Element.get_ChildNodes() | Get-AllText) -join ""
    "$Text`n"
}
# <pagelist>タグを整形する。gameeventでしか使われていないようだ。
function Get-PageList {
    param([System.Xml.XmlNode]$Element)
    $Category = $Element.category
    $Query = @(
        "[.[]"
        "    | select(.address | contains(`"$Category/`"))"
        "    | { `"address`": .address, `"title`": .title }"
        "]") -join "`n"
    $Pages = yq -p json -o json $Query $PSScriptRoot\work\allpages-slim.json
    $Text = "`n"
    $Pages | ConvertFrom-Json | ForEach-Object {
        $Address = $_.address
        $Title = $_.title
        $Text += "- [$Title](https://wiki.facepunch.com/gmod/$Address)`n"
    }
    "$Text`n"
}
# 関数定義の引数並びで使う、引数名の配列を取得する
function Get-ArgumentNames {
    foreach($Element in $Input) {
        if ($null -eq $Element) { continue }
        $Children = $Element.get_ChildNodes()
        $Names = for ($i = 0; $i -lt $Children.Count; $i++) {
            if ($Children[$i].get_Name() -ne "arg") {
                $null
            }
            elseif ($Children[$i].type -match "vararg") {
                "..."
            }
            elseif ([string]::IsNullOrEmpty($Children[$i].name)) {
                "arg$($i + 1)"
            }
            else {
                Get-Safename $Children[$i].name
            }
        }
        $Names.Where({ -not [string]::IsNullOrEmpty($_) })
    }
}
# 引数の説明ブロック
function Get-ArgumentDescriptions {
    foreach ($Element in $Input) {
        if ($null -eq $Element) { continue }
        $Text = "`n### Arguments`n" | Add-CommentHeader
        $Text += $($Element.get_ChildNodes() | ForEach-Object {
            Get-Arg $_ -IsDescription
        }) -join "`n" -replace "\n\s*$" | Add-CommentHeader
        "$Text`n"
    }
}
# 戻り値の説明ブロック
function Get-ReturnDescriptions {
    foreach ($Element in $Input) {
        if ($null -eq $Element) { continue }
        $Text = "`n### Returns`n" | Add-CommentHeader
        $Text += $($Element.get_ChildNodes() | ForEach-Object {
            Get-Ret $_ -IsDescription
        }) -join "`n" -replace "\n\s*$" | Add-CommentHeader
        "$Text`n"
    }
}
# Luaアノテーション用関数定義文字列を生成する。
# ---$Description
# ---$ReturnsDescription
# ---$Examples
# ---@param $ArgElement -> $ArgDefinition
# ---@return $ReturnDefinition
# function $FunctionName($ArgNameList -join ", ") end
function Get-FunctionDefinition {
    param(
        [string]$FunctionName,
        [string]$Description,
        [string]$ReturnsDescription,
        [array]$Examples,
        [string]$ReturnsDefinition,
        [System.Xml.XmlNode]$ArgElement)
    $Separator = "`n---`n" | Add-CommentHeader
    $ArgsDescription = $ArgElement | Get-ArgumentDescriptions
    $ArgsDefinition = $ArgElement | Get-AllText
    $ArgsName = $ArgElement | Get-ArgumentNames
    $Text = $Description
    if (-not [string]::IsNullOrEmpty($ArgsDescription)) {
        $Text += $Separator
        $Text += $ArgsDescription
    }
    if (-not [string]::IsNullOrEmpty($ReturnsDescription)) {
        $Text += $Separator
        $Text += $ReturnsDescription
    }
    $Text += $Examples -join ""
    if ($FunctionName -in $OverrideJson.GenericsAdd.PSObject.Properties.Name) {
        $Text += "---@generic $($OverrideJson.GenericsAdd.$FunctionName)`n"
    }
    $Text += $ArgsDefinition # ---@param
    $Text += $ReturnsDefinition # ---@return
    "${Text}function $FunctionName($($ArgsName -join ", ")) end"
}
# JSON.markup の文字列をXMLとして解釈する
function Get-XmlDocPages {
    param([string]$MarkupString)
    $XmlStr = $MarkupString | ConvertFrom-Json | ForEach-Object {
        "<wholepage>$_</wholepage>" `
        -creplace "\t", "  "   <# タブ文字の置換 #> `
        -creplace "^\s+(?=<)"  <# タグ前の行頭スペースを消去 #> `
        -creplace "&", "&amp;" <# & をエスケープ #> `
        <# タグではない<をエスケープ #> `
        -creplace "<(?![A-Za-z0-9_/])", "&lt;" `
        <# タグではない>をエスケープ #> `
        -creplace "(?<![`"']\s+|[A-Za-z0-9_/`"'])>", "&gt;" `
        <# <code>ブロック中の<と>をエスケープ (Case-insensitive replaceじゃないとダメ) #> `
        -replace "(?s)(?<=<code>).+?(?=</code>)", {
            $_ -replace "<", "&lt;" -replace ">", "&gt;"
        } `
        <# 正しいタグを小文字にする (Case-insensitive replaceじゃないとダメ) #> `
        -replace "(?s)<([A-Za-z0-9_-]+)((\s+[A-Za-z0-9_-]+=`".+?`")*)>(?=.*</\1>)", {
            $Name = $_.Groups[1].Value.ToLowerInvariant()
            $Attributes = $_.Groups[2].Value
            "<$Name$Attributes>"
        } `
        <# 閉じタグがないタグをエスケープ #> `
        -replace "(?s)<([\sA-Za-z0-9_-]+)>(?!.*</\1>)", "&lt;`$1&gt;" `
        <# 属性指定の区切りにカンマが入るパターンがあるのを修正 #> `
        -creplace "(?<=<[A-Za-z0-9_-]+\s+([A-Za-z0-9_-]+\s*=\s*`".*`")*),\s*(?=[A-Za-z0-9_-]+\s*=)", " " `
        <# エスケープに失敗している部分の修正 #> `
        -creplace "`"\\`"\\`"`"", "`"&quot;&quot;`"" `
        <# Markdown構文のコードブロックにある<と>をエスケープ #> `
        -replace "(?s)(?<!``{3})((``{3}.*?){2})+(?!``{3})", {
            $_ -replace "<", "&lt;" -replace ">", "&gt;"
        } `
        <# Markdown構文のインラインコードブロックにある<と>をエスケープ #> `
        -replace "(?<!``)((``.*?){2})+(?!``)", { $_ -replace "<", "&lt;" -replace ">", "&gt;" } `
        <# 引用符の中の<と>をエスケープ #> `
        -replace "(?<!')(('.*?){2})+(?!')", { $_ -replace "<", "&lt;" -replace ">", "&gt;" } `
        <# 二重引用符の中の<と>をエスケープ #> `
        -replace "(?<!`")((`".*?){2})+(?!`")", { $_ -replace "<", "&lt;" -replace ">", "&gt;" }
    }
    $global:XmlDocAll = [xml]::new()
    $global:XmlStr = "<root>`n$XmlStr`n</root>"
    $XmlDocAll.LoadXml($global:XmlStr)
    $XmlDocAll.SelectNodes("/root/wholepage")
}
# yqで抽出したマークアップテキストから関数のアノテーションを生成する
# フィルタにselect(.tags | contains("function"))が必要
function Get-FunctionAnnotation {
    param([string]$MarkupString)
    $Lua = @{}
    $FunctionGroupTable = @{}
    $Pages = Get-XmlDocPages $MarkupString
    $NumEntry = $Pages.Count
    $Progress = 0
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $FunctionElement = $_.SelectSingleNode($(XPathByNameInsensitive "function"))
        $ExampleElements = $_.SelectNodes($(XPathByNameInsensitive "example"))
        $DescriptionElement = $FunctionElement.SelectSingleNode($(XPathByNameInsensitive "description"))
        $ArgsElements = $FunctionElement.SelectNodes($(XPathByNameInsensitive "args"))
        $RetsElement = $FunctionElement.SelectSingleNode($(XPathByNameInsensitive "rets"))

        $FunctionName = $FunctionElement.Attributes["name"].Value
        $FunctionType = $FunctionElement.Attributes["type"].Value
        $FunctionParent = $FunctionElement.Attributes["parent"].Value

        # 関数名の生成 ライブラリ関数の場合は : ではなく . で繋ぐ
        if (($FunctionType -eq "classfunc") `
        -or ($FunctionType -eq "panelfunc") `
        -or ($FunctionType -match "hook")) {
            $FunctionFullName = "${FunctionParent}:$FunctionName"
        }
        elseif (($FunctionType.ToLowerInvariant() -eq "libraryfunc") `
           -and ($FunctionParent.ToLowerInvariant() -ne "global")) {
            $FunctionFullName = "${FunctionParent}.$FunctionName"
        }
        else {
            $FunctionFullName = $FunctionName
        }

        # Lua標準関数のアノテーションはしない
        if ($FunctionFullName -notin $BuiltinFunctions) {
            # アノテーション要素の生成
            $Description = $DescriptionElement | Get-AllText
            $ReturnsDescription = $RetsElement | Get-ReturnDescriptions
            $Examples = $ExampleElements | Get-AllText
            $ReturnsDefinition = $RetsElement | Get-AllText

            # 引数定義が複数個ある場合、オーバーロードを生成する
            if ($ArgsElements.Count -gt 0) {
                $Text = $ArgsElements | ForEach-Object {
                    Get-FunctionDefinition `
                        $FunctionFullName `
                        $Description `
                        $ReturnsDescription `
                        $Examples `
                        $ReturnsDefinition `
                        $_
                }
                $Text = $Text -join "`n`n"
            }
            else {
                $Text = Get-FunctionDefinition  `
                    $FunctionFullName `
                    $Description `
                    $ReturnsDescription `
                    $Examples `
                    $ReturnsDefinition `
                    $null
            }

            # ハッシュテーブルにparentをキーとしてまとめる
            if (-not $Lua.ContainsKey($FunctionParent)) {
                $Lua[$FunctionParent] = New-Object System.Collections.ArrayList
            }
            # jit.opt.* などへの対策
            if ($FunctionName -match "\.") {
                $FunctionGroupName = $FunctionParent + "." + $($FunctionName -replace "\..+$")
                if ($null -eq $FunctionGroupTable.$FunctionGroupName) {
                    $FunctionGroupTable.$FunctionGroupName = $true
                    $Lua[$FunctionParent].Add("$FunctionGroupName = $FunctionGroupName or {}")
                }
            }
            [void]$Lua[$FunctionParent].Add($Text)
        }

        # 進捗表示
        $Progress++
        $Percent = $Progress / $NumEntry * 100
        $Status = "$([Math]::Round($Percent)) % | $Progress / $NumEntry"
        [void](Write-Progress -Activity "Generating annotations for functions..." `
            -Status $Status -PercentComplete $Percent)
    }
    return $Lua
}
# yqで抽出したマークアップテキストからVGUIパネルのアノテーションを生成する
# フィルタにselect(.tags | contains("panel"))が必要
function Get-PanelAnnotation {
    param([string]$MarkupString)
    $Lua = @{}
    $Pages = Get-XmlDocPages $MarkupString
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $Title = $_.SelectSingleNode("pagetitle").InnerText
        $PanelElement = $_.SelectSingleNode($(XPathByNameInsensitive "panel"))
        $ParentName = $PanelElement.SelectSingleNode($(XPathByNameInsensitive "parent")).InnerText
        $ExampleElements = $_.SelectNodes($(XPathByNameInsensitive "example"))
        $DescriptionElement = $PanelElement.SelectSingleNode($(XPathByNameInsensitive "description"))

        $Description = $DescriptionElement | Get-AllText
        $Examples = $ExampleElements | Get-AllText

        $NoParent = [string]::IsNullOrEmpty(($ParentName))
        $ParentPrefix = $NoParent ? "" : " : "
        $Text = $Description
        $Text += $Examples -join ""
        $Text += "---@class $Title$ParentPrefix$ParentName`n$Title = {}"
        if ($NoParent) {
            $ParentName = "Global"
        }

        # ハッシュテーブルにparentをキーとしてまとめる
        if (-not $Lua.ContainsKey($ParentName)) {
            $Lua[$ParentName] = New-Object System.Collections.ArrayList
        }
        $Lua[$ParentName].Add($Text)
    }
    return $Lua
}
# yqで抽出したマークアップテキストから型定義のアノテーションを生成する
# フィルタにselect(.tags | contains("type"))が必要
function Get-TypeAnnotation {
    param([string]$MarkupString)
    $Lua = @{}
    $Pages = Get-XmlDocPages $MarkupString
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $TypeElement = $_.SelectSingleNode($(XPathByNameInsensitive "type"))
        $SummaryElement = $TypeElement.SelectSingleNode($(XPathByNameInsensitive "summary"))

        $TypeName = $TypeElement.Attributes["name"].Value
        $TypeParent = $TypeElement.Attributes["parent"].Value

        # 存在するけど使わない属性
        # $TypeCategory = $TypeElement.category # "classfunc" or "hook" or "libraryfunc"
        # $TypeIs = $TypeElement.is # "class" or "library"

        $NoParent = [string]::IsNullOrEmpty(($TypeParent))
        $ParentPrefix = $NoParent ? "" : " : "
        $Text = Get-Comments $SummaryElement
        $Text += "---@class $TypeName$ParentPrefix$TypeParent`n$TypeName = {}"
        if ($NoParent) {
            $TypeParent = "Global"
        }

        # ハッシュテーブルにparentをキーとしてまとめる
        if (-not $Lua.ContainsKey($TypeParent)) {
            $Lua[$TypeParent] = New-Object System.Collections.ArrayList
        }
        $Lua[$TypeParent].Add($Text)
    }
    return $Lua
}
# yqで抽出したマークアップテキストから列挙型のアノテーションを生成する
# フィルタにselect(.tags | contains("enum"))が必要
function Get-EnumAnnotation {
    param([string]$MarkupString)
    $Lua = @{}
    $Pages = Get-XmlDocPages $MarkupString
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $Title = $_.SelectSingleNode("pagetitle").InnerText
        $EnumElement = $_.SelectSingleNode($(XPathByNameInsensitive "enum"))
        $ExampleElements = $_.SelectNodes($(XPathByNameInsensitive "example"))
        $DescriptionElement = $EnumElement.SelectSingleNode($(XPathByNameInsensitive "description"))
        $ItemsElement = $EnumElement.SelectSingleNode($(XPathByNameInsensitive "items"))
        $ItemList = $ItemsElement.SelectNodes($(XPathByNameInsensitive "item"))


        # アノテーション要素の生成
        $Description = $DescriptionElement | Get-AllText
        $Examples = $ExampleElements | Get-AllText
        $Variables = "`n"

        $IsTable = $false
        $ItemList | ForEach-Object {
            $IsTable = $IsTable -or ($_.Attributes["key"].Value -match "\.")
        }
        # エイリアスが必ず展開されて見栄えが悪いので、先頭を空行で埋める
        $Text = ""
        if (-not $IsTable) {
            $Text = "`n`n`n`n`n`n`n`n`n`n" | Add-CommentHeader
        }
        $Text += $Description
        $Text += $Examples -join ""
        if ($IsTable) {
            $Text += "---@enum Enum.$Title`n"
            $Text += "$Title = {`n"
            $ItemList | ForEach-Object {
                $Key = $_.Attributes["key"].Value -replace ".+?\."
                $Key = [regex]::Matches($Key, "^[A-Za-z0-9_]+").Value
                if (-not [string]::IsNullOrEmpty($Key)) {
                    $Value = $_.Attributes["value"].Value
                    if (-not [double]::TryParse($Value, [ref]0.0)) {
                        $Value = "`"$Value`""
                    }
                    $Comments = Get-Comments $_
                    if ($Comments -eq "---`n") { $Comments = "" }
                    $Text += $Comments -replace "(?m)^---", "    ---"
                    $Text += "    $Key = $Value,`n"
                }
            }
            $Text += "}`n"
        }
        else {
            $Text += "---@alias Enum.$Title`n"
            $ItemList | ForEach-Object {
                $Key = $_.Attributes["key"].Value
                $Key = [regex]::Matches($Key, "^[A-Za-z0-9_]+").Value
                if (-not [string]::IsNullOrEmpty($Key)) {
                    $Value = $_.Attributes["value"].Value
                    if (-not [double]::TryParse($Value, [ref]0.0)) {
                        $Value = "`"$Value`""
                    }
                    $Comments = Get-Comments $_
                    if ($Comments -eq "---`n") { $Comments = "" }
                    $Text += $Comments
                    $Text += "---| ``$Key```n"
                    $Variables += $Comments
                    $Variables += "$Key = $Value ---@type Enum.$Title`n"
                }
            }
            $Text += $Variables
        }

        # ハッシュテーブルにparentをキーとしてまとめる
        if (-not $Lua.ContainsKey($Title)) {
            $Lua[$Title] = New-Object System.Collections.ArrayList
        }
        $Lua[$Title].Add($Text)
    }
    return $Lua
}
# yqで抽出したマークアップテキストから構造体のアノテーションを生成する
# フィルタにselect(.tags | contains("struct"))が必要
function Get-StructAnnotation {
    param([string]$MarkupString)
    $Lua = @{
        "Struct" = New-Object System.Collections.ArrayList
        "GameEvent" = New-Object System.Collections.ArrayList
    }
    $Pages = Get-XmlDocPages $MarkupString
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $Title = $_.SelectSingleNode("pagetitle").InnerText
        $StructElement = $_.SelectSingleNode($(XPathByNameInsensitive "structure"))
        $ExampleElements = $_.SelectNodes($(XPathByNameInsensitive "example"))
        $DescriptionElement = $StructElement.SelectSingleNode($(XPathByNameInsensitive "description"))
        $FieldsElement = $StructElement.SelectSingleNode($(XPathByNameInsensitive "fields"))
        $Category = $_.SelectSingleNode($(XPathByNameInsensitive "cat")).InnerText -contains "gameevent" ? "GameEvent" : "Struct"

        $Description = $DescriptionElement | Get-AllText
        $Examples = $ExampleElements | Get-AllText

        $Text = $Description
        $Text += $Examples -join ""
        $Text += "---@class Structure.$Title`n"
        if ($FieldsElement) {
            $FieldsElement.get_ChildNodes() | ForEach-Object {
                $Name = $_.Attributes["name"].Value
                $Name = [regex]::Matches($Name, "^[A-Za-z0-9_]+").Value
                if (-not [string]::IsNullOrEmpty($Name)) {
                    $Type = Get-ElementType $_
                    $Default = $_.Attributes["default"].Value
                    $Comments = Get-Comments $_
                    if (-not ([string]::IsNullOrEmpty($Default) -or ($Default -match "\n"))) { $Type += "?" }
                    if ($Comments -eq "---`n") { $Comments = "" }
                    $Text += $Comments
                    $Text += "---@field $Name $Type`n"
                }
            }
        }

        $Text += "$Title = {}"
        $Lua[$Category].Add($Text)
    }
    return $Lua
}
# yqで抽出したマークアップテキストから構造体のアノテーションを生成する
# フィルタにselect(.tags | contains("event"))が必要
function Get-EventAnnotation {
    param([string]$MarkupString)
    $Lua = Get-FunctionAnnotation $MarkupString
    $Pages = Get-XmlDocPages $MarkupString
    $Pages | ForEach-Object {
        $Page = $_
        $OverrideJson.XPathSubstitution.PSObject.Properties | ForEach-Object {
            $Element = $Page.SelectSingleNode($_.Name)
            if ($null -ne $Element) {
                $Element.Value = $_.Value
            }
        }
        $FunctionElement = $_.SelectSingleNode($(XPathByNameInsensitive "function"))
        $ExampleElements = $_.SelectNodes($(XPathByNameInsensitive "example"))
        $DescriptionElement = $FunctionElement.SelectSingleNode($(XPathByNameInsensitive "description"))
        $ArgsElements = $FunctionElement.SelectNodes($(XPathByNameInsensitive "args"))
        $RetsElements = $FunctionElement.SelectSingleNode($(XPathByNameInsensitive "rets"))

        $FunctionName = $FunctionElement.Attributes["name"].Value
        # $FunctionType = $FunctionElement.Attributes["type"].Value # hook or panelhook
        $FunctionParent = $FunctionElement.Attributes["parent"].Value

        if (($FunctionParent -eq "GM") -or ($FunctionParent -eq "SANDBOX"))
        {
            # アノテーション要素の生成
            $Description = $DescriptionElement | Get-AllText
            $ArgsDescription = $ArgsElements | Get-ArgumentDescriptions
            $ReturnsDescription = $RetsElements | Get-ReturnDescriptions
            $Examples = $ExampleElements | Get-AllText
            $ArgsDefinition = ""
            $ReturnsDefinition = ""
            if ($null -ne $ArgsElements) {
                $ArgsDefinition = $ArgsElements | ForEach-Object {
                    Get-Args $_ -IsCallback
                }
            }
            if ($null -ne $RetsElements) {
                $ReturnsDefinition = $RetsElements | ForEach-Object {
                    Get-Rets $_ -IsCallback
                }
            }
            $Text = $Description
            if (-not [string]::IsNullOrEmpty($ArgsDescription)) {
                $Text += $Separator
                $Text += $ArgsDescription
            }
            if (-not [string]::IsNullOrEmpty($ReturnsDescription)) {
                $Text += $Separator
                $Text += $ReturnsDescription
            }
            $Text += $Examples -join ""
            $Text += "---@param eventName `"$FunctionName`"`n"
            $Text += "---@param identifier any`n"
            $Text += "---@param func fun($ArgsDefinition)"
            if (-not [string]::IsNullOrEmpty($ReturnsDefinition))
            {
                $ReturnsDefinition = $ReturnsDefinition -replace ", ", "?, "
                $Text += ": ${ReturnsDefinition}?"
            }
            $Text += "`nfunction hook.Add(eventName, identifier, func) end"

            $Lua.$FunctionParent += $Text
        }
    }
    return $Lua
}
function Get-AnnotationFromMarkup {
    param([string]$MarkupString, [string]$OutDir)
    switch ($OutDir) {
        "functions" { Get-FunctionAnnotation $MarkupString; break }
        "panels"    { Get-PanelAnnotation    $MarkupString; break }
        "types"     { Get-TypeAnnotation     $MarkupString; break }
        "enums"     { Get-EnumAnnotation     $MarkupString; break }
        "structs"   { Get-StructAnnotation   $MarkupString; break }
        "events"    { Get-EventAnnotation    $MarkupString; break }
    }
}
