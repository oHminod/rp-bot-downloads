@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "_rpbot_self=%~f0"
set "_rpbot_installer_dir=%~dp0"
set "_rpbot_ps1=%TEMP%\rp-bot-installer-%RANDOM%-%RANDOM%.ps1"
powershell.exe -NoLogo -NoProfile -Command "$content=[IO.File]::ReadAllText($env:_rpbot_self);$marker='# RP_BOT_POWERSHELL_PAYLOAD';$index=$content.LastIndexOf($marker,[StringComparison]::Ordinal);if($index -lt 0){exit 2};[IO.File]::WriteAllText($env:_rpbot_ps1,$content.Substring($index),(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_rpbot_ps1%" %*
set "_rpbot_exit=%ERRORLEVEL%"
del /q "%_rpbot_ps1%" >nul 2>&1
exit /b %_rpbot_exit%
# RP_BOT_POWERSHELL_PAYLOAD
#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("stable", "beta")]
    [string]$Channel = "beta",
    [ValidateSet("rp-bot", "pulid", "both")]
    [string]$Select,
    [string]$Root = $(
        if ([string]::IsNullOrWhiteSpace($env:_rpbot_installer_dir)) {
            Join-Path $PSScriptRoot "RP Bot Suite"
        }
        else { Join-Path $env:_rpbot_installer_dir "RP Bot Suite" }
    ),
    [string]$ModelsRoot,
    [ValidateSet("yes", "no", "ask")]
    [string]$Backgrounds = "ask",
    [switch]$AcceptUnsignedMvp,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# RP_BOT_INSTALLER_SECURITY:HTTPS_ONLY
# RP_BOT_INSTALLER_SECURITY:SIZE_AND_SHA256
# RP_BOT_INSTALLER_SECURITY:SAFE_EXTRACTION
# RP_BOT_INSTALLER_SECURITY:ATOMIC_LOCAL_MANIFEST
# RP_BOT_INSTALLER_SECURITY:NO_IMPLICIT_UNINSTALL

$script:PublicRepository = "oHminod/rp-bot-downloads"
$script:PublicRawBase = "https://raw.githubusercontent.com/$($script:PublicRepository)/main"
$script:UserLauncherName = "Lancer RP Bot.bat"
$script:PuLIDLocalLauncherName = "Lancer PuLID local.bat"
$script:PuLIDNetworkLauncherName = "Lancer PuLID reseau.bat"
$script:StateDirectory = Join-Path $Root "state"
$script:DownloadDirectory = Join-Path $script:StateDirectory "downloads"
$script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
$script:TemporaryRoot = $null
$script:Swap = $null

function Fail([string]$Message) {
    throw $Message
}

function Write-Section([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-ExactProperties($Value, [string[]]$Expected, [string]$Label) {
    if ($null -eq $Value -or $Value -isnot [psobject]) { Fail "$Label doit être un objet." }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join "`0") -ne ($wanted -join "`0")) {
        Fail "$Label contient des propriétés inconnues ou manquantes. Attendu : $($wanted -join ', ')."
    }
}

function Assert-Text($Value, [string]$Label) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { Fail "$Label doit être un texte non vide." }
}

function Assert-SemVer($Value, [string]$Label) {
    Assert-Text $Value $Label
    if ($Value -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
        Fail "$Label doit être une version SemVer."
    }
}

function Assert-PositiveInteger($Value, [string]$Label, [bool]$AllowZero = $false) {
    if ($Value -isnot [ValueType]) { Fail "$Label doit être un entier." }
    $number = [int64]$Value
    if (($AllowZero -and $number -lt 0) -or (-not $AllowZero -and $number -le 0)) { Fail "$Label doit être un entier valide." }
}

function Assert-Https($Value, [string]$Label) {
    Assert-Text $Value $Label
    $uri = [Uri]$Value
    if ($uri.Scheme -ne "https") { Fail "$Label doit utiliser HTTPS." }
}

function Assert-FileName($Value, [string]$Label) {
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$') { Fail "$Label doit être un nom de fichier sûr." }
}

function Assert-Sha256($Value, [string]$Label) {
    if ($Value -isnot [string] -or $Value -notmatch '^[a-f0-9]{64}$') { Fail "$Label doit être une empreinte SHA-256 minuscule." }
}

function Assert-Signature($Value, [string]$Label) {
    if ($Value.status -eq "unsigned-mvp") {
        Assert-ExactProperties $Value @("status", "reason") $Label
        Assert-Text $Value.reason "$Label.reason"
        return
    }
    if ($Value.status -eq "signed") {
        Assert-ExactProperties $Value @("status", "algorithm", "url", "keyId") $Label
        if ($Value.algorithm -ne "minisign-ed25519") { Fail "$Label.algorithm non pris en charge." }
        Assert-Https $Value.url "$Label.url"
        Assert-Text $Value.keyId "$Label.keyId"
        return
    }
    Fail "$Label.status non pris en charge."
}

function Assert-Artifact($Value, [string]$Label) {
    Assert-ExactProperties $Value @("component", "platform", "architecture", "fileName", "url", "sizeBytes", "sha256", "signature") $Label
    if ($Value.component -notin @("rp-bot", "pulid", "roleplay-backgrounds")) { Fail "$Label.component invalide." }
    if ($Value.platform -notin @("macos", "windows", "any")) { Fail "$Label.platform invalide." }
    if ($Value.architecture -notin @("arm64", "x64", "any")) { Fail "$Label.architecture invalide." }
    Assert-FileName $Value.fileName "$Label.fileName"
    Assert-Https $Value.url "$Label.url"
    Assert-PositiveInteger $Value.sizeBytes "$Label.sizeBytes"
    Assert-Sha256 $Value.sha256 "$Label.sha256"
    Assert-Signature $Value.signature "$Label.signature"
    if (-not $Value.url.EndsWith("/" + $Value.fileName, [StringComparison]::Ordinal)) { Fail "$Label.url ne se termine pas par le nom déclaré." }
    if ($Value.signature.status -eq "signed" -and -not $Value.signature.url.EndsWith("/" + $Value.fileName + ".sig", [StringComparison]::Ordinal)) { Fail "$Label.signature.url est incohérente." }
}

function Assert-Requirement($Value, [string]$Label) {
    Assert-ExactProperties $Value @("selection", "variant", "platform", "architecture", "minimumOsVersion", "requiredMemoryBytes", "requiredFreeDiskBytes", "cpuRequirement", "gpuRequirement") $Label
    if ($Value.selection -notin @("rp-bot", "pulid", "pulid-models", "roleplay-backgrounds")) { Fail "$Label.selection invalide." }
    if ($Value.platform -notin @("macos", "windows") -or $Value.architecture -notin @("arm64", "x64")) { Fail "$Label cible invalide." }
    Assert-Text $Value.variant "$Label.variant"
    Assert-PositiveInteger $Value.requiredMemoryBytes "$Label.requiredMemoryBytes" $true
    Assert-PositiveInteger $Value.requiredFreeDiskBytes "$Label.requiredFreeDiskBytes" $true
    if ($Value.gpuRequirement.required -eq $false) {
        Assert-ExactProperties $Value.gpuRequirement @("required") "$Label.gpuRequirement"
    } else {
        Assert-ExactProperties $Value.gpuRequirement @("required", "vendor", "acceleration", "minimumVramBytes", "minimumDriverVersion", "cudaMajorVersion") "$Label.gpuRequirement"
        if ($Value.selection -ne "pulid") { Fail "Seule la sélection PuLID peut imposer un GPU." }
    }
}

function Read-JsonStrict([string]$Path, [string]$Label) {
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Fail "$Label n'est pas un JSON valide : $($_.Exception.Message)" }
}

function Read-RpBotBuildVersion([string]$Path) {
    $parsed = @(Read-JsonStrict $Path "Métadonnées RP Bot")
    if (@($parsed).Count -ne 1) { Fail "Métadonnées RP Bot ambiguës : un objet JSON unique est requis." }
    $build = $parsed[0]
    Assert-ExactProperties $build @("schemaVersion", "application", "version", "buildId", "builtAt", "target", "nodeRuntimeVersion", "signed") "Métadonnées RP Bot"
    if ($build.schemaVersion -ne 1 -or $build.application -ne "rp-bot") { Fail "Métadonnées RP Bot non prises en charge." }
    Assert-SemVer $build.version "Métadonnées RP Bot.version"
    Assert-SemVer $build.nodeRuntimeVersion "Métadonnées RP Bot.nodeRuntimeVersion"
    Assert-Text $build.buildId "Métadonnées RP Bot.buildId"
    Assert-Text $build.builtAt "Métadonnées RP Bot.builtAt"
    Assert-ExactProperties $build.target @("platform", "arch") "Métadonnées RP Bot.target"
    if ($build.target.platform -ne "windows" -or $build.target.arch -ne "x64") { Fail "Cible interne de l'artefact RP Bot invalide." }
    if ($build.signed -isnot [bool]) { Fail "Métadonnées RP Bot.signed doit être un booléen." }
    return [string]$build.version
}

function Read-ChannelPointer([string]$Path) {
    $pointer = Read-JsonStrict $Path "Pointeur de canal"
    Assert-ExactProperties $pointer @("schemaVersion", "channel", "updatedAt", "suiteVersion", "manifest", "channelSignature") "Pointeur"
    if ($pointer.schemaVersion -ne 1 -or $pointer.channel -ne $Channel) { Fail "Pointeur de canal non pris en charge." }
    Assert-SemVer $pointer.suiteVersion "Pointeur.suiteVersion"
    if ($Channel -eq "stable" -and $pointer.suiteVersion -notmatch '^\d+\.\d+\.\d+$') { Fail "Version stable invalide." }
    if ($Channel -eq "beta" -and $pointer.suiteVersion -notmatch '^\d+\.\d+\.\d+-beta\.(0|[1-9]\d*)$') { Fail "Version bêta invalide." }
    Assert-ExactProperties $pointer.manifest @("fileName", "url", "sizeBytes", "sha256", "signature") "Pointeur.manifest"
    Assert-FileName $pointer.manifest.fileName "Pointeur.manifest.fileName"
    Assert-Https $pointer.manifest.url "Pointeur.manifest.url"
    Assert-PositiveInteger $pointer.manifest.sizeBytes "Pointeur.manifest.sizeBytes"
    Assert-Sha256 $pointer.manifest.sha256 "Pointeur.manifest.sha256"
    Assert-Signature $pointer.manifest.signature "Pointeur.manifest.signature"
    Assert-Signature $pointer.channelSignature "Pointeur.channelSignature"
    $expected = "rp-bot-suite-manifest-$($pointer.suiteVersion).json"
    if ($pointer.manifest.fileName -ne $expected -or -not $pointer.manifest.url.EndsWith("/$expected", [StringComparison]::Ordinal)) { Fail "Nom public de manifeste incohérent." }
    if ($Channel -eq "stable" -and ($pointer.manifest.signature.status -ne "signed" -or $pointer.channelSignature.status -ne "signed")) { Fail "Le canal stable doit être signé." }
    return $pointer
}

function Read-SuiteManifest([string]$Path) {
    $manifest = Read-JsonStrict $Path "Manifeste public de suite"
    Assert-ExactProperties $manifest @("schemaVersion", "releaseChannel", "suiteVersion", "publishedAt", "releaseNotesUrl", "rpBot", "pulid", "roleplayBackgrounds", "artifacts", "installationRequirements", "blockingIncompatibilities", "manifestSignature") "Manifeste"
    if ($manifest.schemaVersion -ne 1 -or $manifest.releaseChannel -ne $Channel) { Fail "Manifeste public non pris en charge." }
    Assert-SemVer $manifest.suiteVersion "Manifeste.suiteVersion"
    if ($Channel -eq "stable" -and $manifest.suiteVersion -notmatch '^\d+\.\d+\.\d+$') { Fail "Version stable invalide." }
    if ($Channel -eq "beta" -and $manifest.suiteVersion -notmatch '^\d+\.\d+\.\d+-beta\.(0|[1-9]\d*)$') { Fail "Version bêta invalide." }
    Assert-Https $manifest.releaseNotesUrl "Manifeste.releaseNotesUrl"
    Assert-ExactProperties $manifest.rpBot @("version", "nodeRuntimeVersion", "sqliteSchemaVersion") "Manifeste.rpBot"
    Assert-SemVer $manifest.rpBot.version "Manifeste.rpBot.version"
    Assert-SemVer $manifest.rpBot.nodeRuntimeVersion "Manifeste.rpBot.nodeRuntimeVersion"
    Assert-PositiveInteger $manifest.rpBot.sqliteSchemaVersion "Manifeste.rpBot.sqliteSchemaVersion" $true
    if ($manifest.rpBot.version -ne $manifest.suiteVersion) { Fail "La version RP Bot doit être celle de la suite." }
    Assert-ExactProperties $manifest.pulid @("compatibleVersion", "apiContractVersion") "Manifeste.pulid"
    Assert-SemVer $manifest.pulid.compatibleVersion "Manifeste.pulid.compatibleVersion"
    Assert-SemVer $manifest.pulid.apiContractVersion "Manifeste.pulid.apiContractVersion"
    Assert-ExactProperties $manifest.roleplayBackgrounds @("contentVersion", "formatVersion", "minimumRpBotVersion", "maximumRpBotVersionExclusive") "Manifeste.roleplayBackgrounds"
    Assert-SemVer $manifest.roleplayBackgrounds.contentVersion "Manifeste.roleplayBackgrounds.contentVersion"
    Assert-SemVer $manifest.roleplayBackgrounds.formatVersion "Manifeste.roleplayBackgrounds.formatVersion"
    Assert-SemVer $manifest.roleplayBackgrounds.minimumRpBotVersion "Manifeste.roleplayBackgrounds.minimumRpBotVersion"
    if ($null -ne $manifest.roleplayBackgrounds.maximumRpBotVersionExclusive) { Assert-SemVer $manifest.roleplayBackgrounds.maximumRpBotVersionExclusive "Manifeste.roleplayBackgrounds.maximumRpBotVersionExclusive" }
    if (@($manifest.artifacts).Count -ne 4) { Fail "L'inventaire doit contenir exactement les quatre artefacts MVP." }
    for ($index = 0; $index -lt @($manifest.artifacts).Count; $index++) { Assert-Artifact $manifest.artifacts[$index] "Manifeste.artifacts[$index]" }
    for ($index = 0; $index -lt @($manifest.installationRequirements).Count; $index++) { Assert-Requirement $manifest.installationRequirements[$index] "Manifeste.installationRequirements[$index]" }
    Assert-Signature $manifest.manifestSignature "Manifeste.manifestSignature"
    if ($manifest.blockingIncompatibilities -isnot [array] -and $null -eq $manifest.blockingIncompatibilities) { Fail "Incompatibilités invalides." }
    for ($index = 0; $index -lt @($manifest.blockingIncompatibilities).Count; $index++) {
        $incompatibility = $manifest.blockingIncompatibilities[$index]
        Assert-ExactProperties $incompatibility @("code", "message", "affectedComponents", "affectedTargets") "Manifeste.blockingIncompatibilities[$index]"
        Assert-Text $incompatibility.code "Incompatibilité.code"; Assert-Text $incompatibility.message "Incompatibilité.message"
        foreach ($target in $incompatibility.affectedTargets) { Assert-ExactProperties $target @("platform", "architecture") "Incompatibilité.affectedTarget" }
    }
    if ($Channel -eq "stable" -and ($manifest.manifestSignature.status -ne "signed" -or @($manifest.artifacts | Where-Object { $_.signature.status -ne "signed" }).Count -gt 0)) { Fail "Une release stable doit être entièrement signée." }

    $expectedArtifacts = @{
        "rp-bot:macos:arm64" = "rp-bot-macos-arm64-$($manifest.suiteVersion).tar.gz"
        "rp-bot:windows:x64" = "rp-bot-windows-x64-$($manifest.suiteVersion).zip"
        "pulid:any:any" = "pulid-$($manifest.pulid.compatibleVersion).tar.gz"
        "roleplay-backgrounds:any:any" = "rp-bot-roleplay-backgrounds-$($manifest.roleplayBackgrounds.contentVersion)-format-$($manifest.roleplayBackgrounds.formatVersion).zip"
    }
    foreach ($key in $expectedArtifacts.Keys) {
        $parts = $key.Split(":")
        $found = @($manifest.artifacts | Where-Object { $_.component -eq $parts[0] -and $_.platform -eq $parts[1] -and $_.architecture -eq $parts[2] })
        if (@($found).Count -ne 1 -or $found[0].fileName -ne $expectedArtifacts[$key]) { Fail "Artefact obligatoire absent ou mal nommé : $key." }
    }
    if (@($manifest.installationRequirements).Count -ne 8) { Fail "Les huit lignes de prérequis MVP sont obligatoires." }
    foreach ($selectionName in @("rp-bot", "pulid", "pulid-models", "roleplay-backgrounds")) {
        foreach ($target in @(@("macos", "arm64"), @("windows", "x64"))) {
            $found = @($manifest.installationRequirements | Where-Object { $_.selection -eq $selectionName -and $_.platform -eq $target[0] -and $_.architecture -eq $target[1] })
            if (@($found).Count -ne 1) { Fail "Prérequis absent ou ambigu pour $selectionName/$($target[0])-$($target[1])." }
        }
    }
    return $manifest
}

function Get-Artifact($Manifest, [string]$Component) {
    if ($Component -eq "rp-bot") {
        $found = @($Manifest.artifacts | Where-Object { $_.component -eq $Component -and $_.platform -eq "windows" -and $_.architecture -eq "x64" })
    } else {
        $found = @($Manifest.artifacts | Where-Object { $_.component -eq $Component -and $_.platform -eq "any" -and $_.architecture -eq "any" })
    }
    if (@($found).Count -ne 1) { Fail "Artefact absent ou ambigu pour $Component." }
    return $found[0]
}

function Get-Requirement($Manifest, [string]$SelectionName) {
    $found = @($Manifest.installationRequirements | Where-Object { $_.selection -eq $SelectionName -and $_.platform -eq "windows" -and $_.architecture -eq "x64" })
    if (@($found).Count -ne 1) { Fail "Prérequis absent ou ambigu pour $SelectionName." }
    return $found[0]
}

function Assert-AllowedUrl([string]$Component, [string]$Url) {
    Assert-Https $Url "URL $Component"
    $uri = [Uri]$Url
    $valid = $false
    switch ($Component) {
        "pointer" { $valid = $uri.Host -eq "raw.githubusercontent.com" -and $uri.AbsolutePath.StartsWith("/oHminod/rp-bot-downloads/main/latest-") }
        "manifest" { $valid = $uri.Host -eq "github.com" -and $uri.AbsolutePath.StartsWith("/oHminod/rp-bot-downloads/releases/download/") }
        "rp-bot" { $valid = $uri.Host -eq "github.com" -and $uri.AbsolutePath.StartsWith("/oHminod/rp-bot-downloads/releases/download/") }
        "roleplay-backgrounds" { $valid = $uri.Host -eq "github.com" -and $uri.AbsolutePath.StartsWith("/oHminod/rp-bot-downloads/releases/download/") }
        "pulid" { $valid = $uri.Host -eq "github.com" -and $uri.AbsolutePath.StartsWith("/oHminod/PuLID/releases/download/") }
        "signature" { $valid = $uri.Host -in @("github.com", "raw.githubusercontent.com") }
    }
    if (-not $valid) { Fail "Hôte ou chemin de téléchargement non autorisé pour $Component : $Url" }
}

function Invoke-Curl([string[]]$Arguments, [string]$Failure) {
    & "$env:SystemRoot\System32\curl.exe" @Arguments
    if ($LASTEXITCODE -ne 0) { Fail $Failure }
}

function Download-Small([string]$Component, [string]$Url, [string]$Destination) {
    Assert-AllowedUrl $Component $Url
    Invoke-Curl @("--proto", "=https", "--tlsv1.2", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--connect-timeout", "15", "--max-time", "120", "--output", $Destination, $Url) "Téléchargement impossible : $Url"
    if ((Get-Item -LiteralPath $Destination).Length -le 0) { Fail "Téléchargement vide : $Url" }
}

function Test-VerifiedFile([string]$Path, [int64]$ExpectedSize, [string]$ExpectedSha) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $ExpectedSize) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedSha
}

function Verify-Signature([string]$Path, $Signature) {
    if ($Signature.status -ne "signed") { return }
    Fail "Cette release signée exige le futur installateur Windows signé avec son vérificateur Minisign épinglé. Le wrapper MVP refuse de continuer."
}

function Download-Verified([string]$Component, $Artifact) {
    Assert-AllowedUrl $Component $Artifact.url
    $final = Join-Path $script:DownloadDirectory $Artifact.fileName
    $partial = "$final.part"
    if (Test-VerifiedFile $final ([int64]$Artifact.sizeBytes) $Artifact.sha256) {
        Write-Host "Téléchargement vérifié déjà présent : $($Artifact.fileName)"
        Verify-Signature $final $Artifact.signature
        return $final
    }
    if (Test-Path -LiteralPath $final) { Move-Item -LiteralPath $final -Destination $partial -Force }
    Write-Section "Téléchargement de $($Artifact.fileName)"
    Invoke-Curl @("--proto", "=https", "--tlsv1.2", "--fail", "--location", "--retry", "3", "--connect-timeout", "20", "--continue-at", "-", "--output", $partial, $Artifact.url) "Téléchargement interrompu. Le fichier partiel est conservé : $partial"
    if (-not (Test-VerifiedFile $partial ([int64]$Artifact.sizeBytes) $Artifact.sha256)) { Fail "Taille ou SHA-256 invalide. Le fichier partiel est conservé : $partial" }
    Move-Item -LiteralPath $partial -Destination $final -Force
    Verify-Signature $final $Artifact.signature
    return $final
}

function Test-SafeArchiveEntry([string]$Name) {
    if ([string]::IsNullOrEmpty($Name) -or $Name.Contains("`0") -or $Name.Contains("\") -or $Name.StartsWith("/") -or $Name -match '^[A-Za-z]:') { return $false }
    return @($Name.Split("/") | Where-Object { $_ -eq ".." }).Count -eq 0
}

function Expand-SafeZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd("\") + "\"
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not (Test-SafeArchiveEntry $entry.FullName)) { Fail "Entrée ZIP dangereuse refusée : $($entry.FullName)" }
            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) { Fail "Lien symbolique ZIP refusé : $($entry.FullName)" }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and $target.TrimEnd("\") -ne $Destination.TrimEnd("\")) { Fail "Entrée ZIP hors racine : $($entry.FullName)" }
            if ([string]::IsNullOrEmpty($entry.Name)) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            $input = $entry.Open()
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Expand-SafeTar([string]$Archive, [string]$Destination) {
    $names = & "$env:SystemRoot\System32\tar.exe" -tzf $Archive
    if ($LASTEXITCODE -ne 0) { Fail "Inventaire TAR illisible : $Archive" }
    foreach ($name in $names) { if (-not (Test-SafeArchiveEntry $name)) { Fail "Entrée TAR dangereuse refusée : $name" } }
    $details = & "$env:SystemRoot\System32\tar.exe" -tvzf $Archive
    if ($LASTEXITCODE -ne 0 -or @($details | Where-Object { $_ -match '^[lh]' }).Count -gt 0) { Fail "Liens physiques ou symboliques interdits dans l'archive TAR." }
    & "$env:SystemRoot\System32\tar.exe" -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) { Fail "Extraction TAR impossible : $Archive" }
}

function Expand-SafeArchive([string]$Archive, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if ($Archive.EndsWith(".zip", [StringComparison]::OrdinalIgnoreCase)) { Expand-SafeZip $Archive $Destination; return }
    if ($Archive.EndsWith(".tar.gz", [StringComparison]::OrdinalIgnoreCase)) { Expand-SafeTar $Archive $Destination; return }
    Fail "Format d'archive non pris en charge : $Archive"
}

function Get-SingleArchiveRoot([string]$Staging) {
    $entries = @(Get-ChildItem -LiteralPath $Staging -Force)
    if (@($entries).Count -ne 1 -or -not $entries[0].PSIsContainer) { Fail "L'archive doit contenir exactement un dossier racine." }
    return $entries[0].FullName
}

function Assert-SafeManagedPath([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd("\") + "\"
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Fail "Chemin géré hors racine refusé : $Path" }
}

function Start-DirectorySwap([string]$Prepared, [string]$Target, [string]$Staging) {
    $parent = [IO.Path]::GetDirectoryName($Target)
    Assert-SafeManagedPath $Target $parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $backup = $null
    if (Test-Path -LiteralPath $Target) {
        $backup = "$Target.backup.$([Guid]::NewGuid())"
        Move-Item -LiteralPath $Target -Destination $backup
    }
    try { Move-Item -LiteralPath $Prepared -Destination $Target }
    catch {
        if ($backup) { Move-Item -LiteralPath $backup -Destination $Target }
        throw
    }
    $script:Swap = [pscustomobject]@{ Target = $Target; Backup = $backup; Staging = $Staging }
}

function Complete-DirectorySwap {
    if ($script:Swap.Backup -and (Test-Path -LiteralPath $script:Swap.Backup)) { Remove-Item -LiteralPath $script:Swap.Backup -Recurse -Force }
    if (Test-Path -LiteralPath $script:Swap.Staging) { Remove-Item -LiteralPath $script:Swap.Staging -Recurse -Force }
    $script:Swap = $null
}

function Undo-DirectorySwap {
    if ($null -eq $script:Swap) { return }
    if (Test-Path -LiteralPath $script:Swap.Target) { Remove-Item -LiteralPath $script:Swap.Target -Recurse -Force }
    if ($script:Swap.Backup -and (Test-Path -LiteralPath $script:Swap.Backup)) { Move-Item -LiteralPath $script:Swap.Backup -Destination $script:Swap.Target }
    if (Test-Path -LiteralPath $script:Swap.Staging) { Remove-Item -LiteralPath $script:Swap.Staging -Recurse -Force }
    $script:Swap = $null
}

function New-EmptyLocalManifest {
    return [pscustomobject]@{
        schemaVersion = 1; suiteId = "rp-bot-suite"; updateChannel = $Channel
        components = [pscustomobject]@{ rpBot = $null; pulid = $null; roleplayBackgrounds = $null }
        paths = [pscustomobject]@{ rpBotData = (Join-Path $Root "data\rp-bot") }
        lastHealthCheck = $null; interruptedOperation = $null
    }
}

function Read-LocalManifest {
    if (-not (Test-Path -LiteralPath $script:LocalManifestPath)) { return New-EmptyLocalManifest }
    $local = Read-JsonStrict $script:LocalManifestPath "Manifeste local"
    Assert-ExactProperties $local @("schemaVersion", "suiteId", "updateChannel", "components", "paths", "lastHealthCheck", "interruptedOperation") "Manifeste local"
    if ($local.schemaVersion -ne 1 -or $local.suiteId -ne "rp-bot-suite") { Fail "Manifeste local non pris en charge ; aucune écriture effectuée." }
    Assert-ExactProperties $local.components @("rpBot", "pulid", "roleplayBackgrounds") "Manifeste local.components"
    Assert-ExactProperties $local.paths @("rpBotData") "Manifeste local.paths"
    Assert-Text $local.paths.rpBotData "Manifeste local.paths.rpBotData"
    if ($null -ne $local.components.rpBot) {
        $component = $local.components.rpBot
        Assert-ExactProperties $component @("id", "installedVersion", "activeVersion", "releases") "Manifeste local.components.rpBot"
        if ($component.id -ne "rp-bot" -or $component.installedVersion -ne $component.activeVersion) { Fail "État RP Bot local incohérent." }
        foreach ($release in $component.releases) { Assert-ExactProperties $release @("version", "releasePath", "installedAt") "Release RP Bot locale" }
        if (@($component.releases | Where-Object { $_.version -eq $component.activeVersion }).Count -ne 1) { Fail "La release RP Bot active est absente du manifeste local." }
    }
    if ($null -ne $local.components.pulid) {
        $pulid = $local.components.pulid
        Assert-ExactProperties $pulid @("id", "installationType", "detectedVersion", "endpoint", "modelsPath", "managedInstallation") "Manifeste local.components.pulid"
        if ($pulid.id -ne "pulid" -or $pulid.installationType -notin @("managed-local", "external-local", "remote")) { Fail "État PuLID local incohérent." }
        if ($pulid.installationType -eq "managed-local") {
            if ($null -eq $pulid.managedInstallation -or -not $pulid.modelsPath) { Fail "Installation PuLID gérée incomplète." }
            Assert-ExactProperties $pulid.managedInstallation @("id", "installedVersion", "activeVersion", "releases") "Installation PuLID gérée"
            foreach ($release in $pulid.managedInstallation.releases) { Assert-ExactProperties $release @("version", "releasePath", "installedAt") "Release PuLID locale" }
        } elseif ($null -ne $pulid.managedInstallation) { Fail "Une installation PuLID externe ou distante ne doit pas contenir de releases gérées." }
    }
    if ($null -ne $local.components.roleplayBackgrounds) {
        $backgrounds = $local.components.roleplayBackgrounds
        Assert-ExactProperties $backgrounds @("id", "installedContentVersion", "installedFormatVersion", "activeContentVersion", "activeFormatVersion", "activePath", "releases") "Manifeste local.components.roleplayBackgrounds"
        foreach ($release in $backgrounds.releases) { Assert-ExactProperties $release @("contentVersion", "formatVersion", "releasePath", "installedAt") "Release de décors locale" }
        if (@($backgrounds.releases | Where-Object { $_.contentVersion -eq $backgrounds.activeContentVersion -and $_.formatVersion -eq $backgrounds.activeFormatVersion -and $_.releasePath -eq $backgrounds.activePath }).Count -ne 1) { Fail "Le pack de décors actif est absent du manifeste local." }
    }
    if ($null -ne $local.interruptedOperation) {
        Assert-ExactProperties $local.interruptedOperation @("id", "kind", "component", "stage", "startedAt", "updatedAt", "fromVersion", "toVersion", "checkpoint", "recoveryActions") "Manifeste local.interruptedOperation"
    }
    return $local
}

function Write-LocalManifestAtomic($Local) {
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    $temporary = Join-Path $script:StateDirectory (".installation.json.{0}.tmp" -f [Guid]::NewGuid())
    $backup = Join-Path $script:StateDirectory (".installation.json.{0}.bak" -f [Guid]::NewGuid())
    $json = $Local | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($temporary, $json + "`r`n", (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:LocalManifestPath) {
        [IO.File]::Replace($temporary, $script:LocalManifestPath, $backup, $true)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    else { [IO.File]::Move($temporary, $script:LocalManifestPath) }
}

function Set-InterruptedOperation([string]$Kind, [string]$Component, [string]$Stage, [string]$FromVersion, [string]$ToVersion, [string]$Checkpoint) {
    $local = Read-LocalManifest
    $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $started = $now; $id = [Guid]::NewGuid().ToString()
    if ($null -ne $local.interruptedOperation -and $local.interruptedOperation.component -eq $Component) { $started = $local.interruptedOperation.startedAt; $id = $local.interruptedOperation.id }
    $local.interruptedOperation = [pscustomobject]@{ id = $id; kind = $Kind; component = $Component; stage = $Stage; startedAt = $started; updatedAt = $now; fromVersion = $(if ($FromVersion) { $FromVersion } else { $null }); toVersion = $(if ($ToVersion) { $ToVersion } else { $null }); checkpoint = $Checkpoint; recoveryActions = @("resume", "cancel") }
    Write-LocalManifestAtomic $local
}

function Clear-InterruptedOperation {
    $local = Read-LocalManifest; $local.interruptedOperation = $null; Write-LocalManifestAtomic $local
}

function Activate-RpBot([string]$Version, [string]$ReleasePath) {
    $local = Read-LocalManifest; $old = $local.components.rpBot; $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $releases = if ($null -eq $old) { @() } else { @($old.releases) }
    $next = [pscustomobject]@{ version = $Version; releasePath = $ReleasePath; installedAt = $now }
    $updatedReleases = New-Object Collections.Generic.List[object]
    foreach ($release in @($releases)) {
        if ([string]$release.version -ne $Version) { $updatedReleases.Add($release) | Out-Null }
    }
    $updatedReleases.Add($next) | Out-Null
    $local.components.rpBot = [pscustomobject]@{ id = "rp-bot"; installedVersion = $Version; activeVersion = $Version; releases = @($updatedReleases.ToArray()) }
    $local.updateChannel = $Channel; Write-LocalManifestAtomic $local
}

function Activate-PuLID([string]$Version, [string]$ReleasePath, [string]$ModelPath) {
    $local = Read-LocalManifest; $old = $local.components.pulid; $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $releases = if ($null -eq $old -or $null -eq $old.managedInstallation) { @() } else { @($old.managedInstallation.releases) }
    $next = [pscustomobject]@{ version = $Version; releasePath = $ReleasePath; installedAt = $now }
    $updatedReleases = New-Object Collections.Generic.List[object]
    foreach ($release in @($releases)) {
        if ([string]$release.version -ne $Version) { $updatedReleases.Add($release) | Out-Null }
    }
    $updatedReleases.Add($next) | Out-Null
    $managed = [pscustomobject]@{ id = "pulid"; installedVersion = $Version; activeVersion = $Version; releases = @($updatedReleases.ToArray()) }
    $local.components.pulid = [pscustomobject]@{ id = "pulid"; installationType = "managed-local"; detectedVersion = $Version; endpoint = "http://127.0.0.1:12693"; modelsPath = $ModelPath; managedInstallation = $managed }
    $local.updateChannel = $Channel; Write-LocalManifestAtomic $local
}

function Activate-Backgrounds([string]$ContentVersion, [string]$FormatVersion, [string]$ReleasePath) {
    $local = Read-LocalManifest; $old = $local.components.roleplayBackgrounds; $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $releases = if ($null -eq $old) { @() } else { @($old.releases) }
    $next = [pscustomobject]@{ contentVersion = $ContentVersion; formatVersion = $FormatVersion; releasePath = $ReleasePath; installedAt = $now }
    $updatedReleases = New-Object Collections.Generic.List[object]
    foreach ($release in @($releases)) {
        if ([string]$release.contentVersion -ne $ContentVersion -or [string]$release.formatVersion -ne $FormatVersion) { $updatedReleases.Add($release) | Out-Null }
    }
    $updatedReleases.Add($next) | Out-Null
    $local.components.roleplayBackgrounds = [pscustomobject]@{ id = "roleplay-backgrounds"; installedContentVersion = $ContentVersion; installedFormatVersion = $FormatVersion; activeContentVersion = $ContentVersion; activeFormatVersion = $FormatVersion; activePath = $ReleasePath; releases = @($updatedReleases.ToArray()) }
    $local.updateChannel = $Channel; Write-LocalManifestAtomic $local
}

function Confirm-YesNo([string]$Prompt, [bool]$DefaultYes) {
    while ($true) {
        $suffix = if ($DefaultYes) { " [O/n]" } else { " [o/N]" }
        $answer = (Read-Host ($Prompt + $suffix)).Trim().ToLowerInvariant()
        if (-not $answer) { return $DefaultYes }
        if ($answer -in @("o", "oui", "y", "yes")) { return $true }
        if ($answer -in @("n", "non", "no")) { return $false }
        Write-Host "Répondez oui ou non."
    }
}

function Require-WritableDirectory([string]$Directory) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $probe = Join-Path $Directory (".rp-bot-write-test." + [Guid]::NewGuid())
    [IO.File]::WriteAllText($probe, "test")
    Remove-Item -LiteralPath $probe -Force
}

function Get-FreeBytes([string]$Path) {
    $rootPath = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    return [int64]([IO.DriveInfo]::new($rootPath).AvailableFreeSpace)
}

function Require-Disk([string]$Path, [int64]$Required, [string]$Label) {
    $available = Get-FreeBytes $Path
    if ($available -lt $Required) { Fail "Espace insuffisant pour $Label : $Required octets requis, $available disponibles sur $Path." }
}

function Require-Port([int]$Port, [string]$Label) {
    $occupied = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($occupied) { Fail "Le port $Port requis par $Label est occupé. Arrêtez le processus concerné puis relancez l'installateur." }
}

function Require-Connectivity([string]$Label, [string]$Url) {
    try { Invoke-Curl @("--proto", "=https", "--tlsv1.2", "--fail", "--location", "--silent", "--show-error", "--range", "0-0", "--connect-timeout", "10", "--max-time", "30", "--output", "NUL", $Url) "Connexion impossible vers $Label ($Url)." }
    catch { Fail "Connexion impossible vers $Label ($Url). Vérifiez le réseau, le proxy ou le pare-feu." }
}

function Get-NvidiaCudaMajorFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?im)\bCUDA(?:\s+UMD)?\s+Version\s*:\s*(?<major>\d+)(?:\.\d+)?\b')
    if (-not $match.Success) { return $null }
    return [int]$match.Groups["major"].Value
}

function Get-NvidiaCudaMajorFromXml([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $document = [xml]$Text }
    catch { return $null }
    $nodes = @($document.SelectNodes("//*[local-name()='cuda_version' or local-name()='cuda_umd_version']"))
    foreach ($node in $nodes) {
        $major = Get-NvidiaCudaMajorFromText ("CUDA Version: " + [string]$node.InnerText)
        if ($null -ne $major) { return $major }
    }
    return $null
}

function Format-NvidiaSmiDiagnostic([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "<sortie vide>" }
    $summary = [regex]::Replace($Text, '\s+', ' ').Trim()
    if ($summary.Length -gt 500) { return $summary.Substring(0, 500) + "…" }
    return $summary
}

function Run-Preflight($Manifest, [bool]$InstallRp, [bool]$InstallPulid, [bool]$InstallBackgrounds) {
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -notin @("AMD64", "x86")) { Fail "Le MVP Windows exige Windows 11 x64." }
    if ([Environment]::OSVersion.Version.Build -lt 22000) { Fail "Windows 11 ou plus récent est requis." }
    Require-WritableDirectory $Root; Require-WritableDirectory $script:StateDirectory; Require-WritableDirectory $script:DownloadDirectory
    [int64]$appDisk = 0; [int64]$modelDisk = 0; [int64]$memory = 0
    if ($InstallRp) { $requirement = Get-Requirement $Manifest "rp-bot"; $appDisk += [int64]$requirement.requiredFreeDiskBytes; $memory = [Math]::Max($memory, [int64]$requirement.requiredMemoryBytes); Require-Port 8800 "RP Bot" }
    if ($InstallPulid) {
        $runtime = Get-Requirement $Manifest "pulid"; $models = Get-Requirement $Manifest "pulid-models"
        $appDisk += [int64]$runtime.requiredFreeDiskBytes; $modelDisk += [int64]$models.requiredFreeDiskBytes; $memory = [Math]::Max($memory, [int64]$runtime.requiredMemoryBytes); Require-Port 12693 "PuLID"
        $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" })
        if (@($gpus).Count -eq 0) { Fail "PuLID sous Windows exige un GPU NVIDIA." }
        $cudaRequired = [int]$runtime.gpuRequirement.cudaMajorVersion
        $smiCommands = @(Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue)
        if (@($smiCommands).Count -eq 0) { Fail "nvidia-smi est introuvable. Installez un pilote NVIDIA compatible CUDA $cudaRequired." }
        $smiPath = [string]$smiCommands[0].Path
        if ([string]::IsNullOrWhiteSpace($smiPath)) { Fail "Le chemin de nvidia-smi est introuvable. Réinstallez le pilote NVIDIA." }
        $xmlLines = @(& $smiPath "--query" "--xml-format" 2>&1)
        $xmlExitCode = $LASTEXITCODE
        $xmlText = @($xmlLines | ForEach-Object { [string]$_ }) -join "`n"
        $cudaMajor = if ($xmlExitCode -eq 0) { Get-NvidiaCudaMajorFromXml $xmlText } else { $null }
        $bannerText = ""
        $bannerExitCode = $null
        if ($null -eq $cudaMajor) {
            $bannerLines = @(& $smiPath 2>&1)
            $bannerExitCode = $LASTEXITCODE
            $bannerText = @($bannerLines | ForEach-Object { [string]$_ }) -join "`n"
            if ($bannerExitCode -eq 0) { $cudaMajor = Get-NvidiaCudaMajorFromText $bannerText }
        }
        if ($null -eq $cudaMajor) {
            $diagnosticText = if (-not [string]::IsNullOrWhiteSpace($bannerText)) { $bannerText } else { $xmlText }
            $exitDetails = "XML=$xmlExitCode" + $(if ($null -ne $bannerExitCode) { ", bannière=$bannerExitCode" } else { "" })
            Fail "La version CUDA maximale du pilote NVIDIA n'a pas pu être détectée ($exitDetails). Sortie nvidia-smi : $(Format-NvidiaSmiDiagnostic $diagnosticText)"
        }
        if ($cudaMajor -lt $cudaRequired) { Fail "Le pilote NVIDIA annonce CUDA $cudaMajor, CUDA $cudaRequired minimum est requis." }
    }
    if ($InstallBackgrounds) { $appDisk += [int64](Get-Requirement $Manifest "roleplay-backgrounds").requiredFreeDiskBytes }
    Require-Disk $Root $appDisk "les applications et décors sélectionnés"
    if ($InstallPulid) { Require-WritableDirectory $ModelsRoot; Require-Disk $ModelsRoot $modelDisk "les modèles PuLID" }
    $physicalMemory = [int64](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($physicalMemory -lt $memory) { Fail "Mémoire insuffisante : $memory octets requis, $physicalMemory détectés." }
    Require-Connectivity "GitHub" "https://github.com/"
    if ($InstallPulid) {
        Require-Connectivity "Hugging Face" "https://huggingface.co/"
        Require-Connectivity "PyTorch CUDA 13" "https://download.pytorch.org/whl/cu130"
        Require-Connectivity "Astral/uv" "https://astral.sh/uv/install.ps1"
        Require-Connectivity "llama-cpp-python CUDA 13" "https://abetlen.github.io/llama-cpp-python/whl/cu130"
        Require-Connectivity "PyPI" "https://pypi.org/simple"
    }
    $selected = @()
    if ($InstallRp) { $selected += "rp-bot" }
    if ($InstallPulid) { $selected += @("pulid", "pulid-models") }
    if ($InstallBackgrounds) { $selected += "roleplay-backgrounds" }
    foreach ($incompatibility in $Manifest.blockingIncompatibilities) {
        $targeted = @($incompatibility.affectedTargets | Where-Object { $_.platform -eq "windows" -and $_.architecture -eq "x64" }).Count -gt 0
        $affected = @($incompatibility.affectedComponents | Where-Object { $_ -in $selected }).Count -gt 0
        if (-not $targeted -or -not $affected) { continue }
        if ($incompatibility.code -eq "WINDOWS_PULID_REQUIRES_NVIDIA_CUDA13" -and $InstallPulid) { continue }
        Fail ("Incompatibilité bloquante " + $incompatibility.code + " : " + $incompatibility.message)
    }
}

function Install-RpBot($Manifest, [string]$CurrentVersion) {
    $version = $Manifest.rpBot.version; $artifact = Get-Artifact $Manifest "rp-bot"; $kind = if (-not $CurrentVersion) { "install" } elseif ($CurrentVersion -eq $version) { "repair" } else { "update" }
    Set-InterruptedOperation $kind "rp-bot" "downloading" $CurrentVersion $version "Téléchargement RP Bot en cours."
    $archive = Download-Verified "rp-bot" $artifact
    Set-InterruptedOperation $kind "rp-bot" "installing" $CurrentVersion $version "Artefact RP Bot vérifié ; extraction en cours."
    $staging = Join-Path $Root ("apps\rp-bot\.staging." + [Guid]::NewGuid()); Expand-SafeArchive $archive $staging
    $prepared = Get-SingleArchiveRoot $staging
    foreach ($required in @("runtime\node.exe", "launcher.mjs", "metadata\build.json")) { if (-not (Test-Path -LiteralPath (Join-Path $prepared $required) -PathType Leaf)) { Fail "Artefact RP Bot incomplet : $required" } }
    $buildVersion = Read-RpBotBuildVersion (Join-Path $prepared "metadata\build.json")
    if ($buildVersion -ne $version) { Fail "Version interne de l'artefact RP Bot invalide : $buildVersion, attendu $version." }
    $target = Join-Path $Root "apps\rp-bot\$version"; Start-DirectorySwap $prepared $target $staging
    Activate-RpBot $version $target; Complete-DirectorySwap; Clear-InterruptedOperation
    Write-Host "RP Bot $version installé et activé sans modifier les données utilisateur."
}

function Install-PuLID($Manifest, [string]$CurrentVersion) {
    $version = $Manifest.pulid.compatibleVersion; $artifact = Get-Artifact $Manifest "pulid"; $kind = if (-not $CurrentVersion) { "install" } elseif ($CurrentVersion -eq $version) { "repair" } else { "update" }
    Set-InterruptedOperation $kind "pulid" "downloading" $CurrentVersion $version "Téléchargement PuLID en cours."
    $archive = Download-Verified "pulid" $artifact
    Set-InterruptedOperation $kind "pulid" "installing" $CurrentVersion $version "Archive PuLID vérifiée ; installation du runtime privé en cours."
    $staging = Join-Path $Root ("apps\pulid\.staging." + [Guid]::NewGuid()); Expand-SafeArchive $archive $staging
    $prepared = Get-SingleArchiveRoot $staging
    foreach ($required in @("pyproject.toml", "install_production_windows.bat", "install_windows.bat", "start_windows.bat")) { if (-not (Test-Path -LiteralPath (Join-Path $prepared $required) -PathType Leaf)) { Fail "Archive PuLID incomplète : $required" } }
    $target = Join-Path $Root "apps\pulid\$version"; Start-DirectorySwap $prepared $target $staging
    $previousModels = $env:PULID_MODELS_ROOT
    try {
        $env:PULID_MODELS_ROOT = $ModelsRoot
        & "$env:SystemRoot\System32\cmd.exe" /d /c (Join-Path $target "install_production_windows.bat")
        if ($LASTEXITCODE -ne 0) { Fail "L'installateur production PuLID a échoué." }
        if (-not (Test-Path -LiteralPath (Join-Path $target ".venv\Scripts\pulid-gen.exe") -PathType Leaf)) { Fail "Le contrôle de santé PuLID n'a pas produit le runtime attendu." }
    } catch { Undo-DirectorySwap; throw }
    finally { $env:PULID_MODELS_ROOT = $previousModels }
    Activate-PuLID $version $target $ModelsRoot; Complete-DirectorySwap; Clear-InterruptedOperation
    Write-Host "PuLID $version installé avec Python privé ; modèles conservés dans $ModelsRoot."
}

function Verify-BackgroundTree([string]$Directory, $ExpectedVersions) {
    $manifestPath = Join-Path $Directory "roleplay-backgrounds.manifest.json"
    $inventory = Read-JsonStrict $manifestPath "Inventaire des décors"
    Assert-ExactProperties $inventory @("schemaVersion", "packId", "contentVersion", "formatVersion", "rpBotCompatibility", "fileCount", "totalSizeBytes", "sourceTreeSha256", "files") "Inventaire des décors"
    if ($inventory.schemaVersion -ne 1 -or $inventory.packId -ne "roleplay-backgrounds" -or $inventory.contentVersion -ne $ExpectedVersions.contentVersion -or $inventory.formatVersion -ne $ExpectedVersions.formatVersion) { Fail "Versions de l'inventaire des décors incohérentes." }
    Assert-SemVer $inventory.contentVersion "Inventaire.contentVersion"; Assert-SemVer $inventory.formatVersion "Inventaire.formatVersion"
    Assert-ExactProperties $inventory.rpBotCompatibility @("minimumVersion", "maximumVersionExclusive") "Inventaire.rpBotCompatibility"
    Assert-SemVer $inventory.rpBotCompatibility.minimumVersion "Inventaire.rpBotCompatibility.minimumVersion"
    if ($null -ne $inventory.rpBotCompatibility.maximumVersionExclusive) { Assert-SemVer $inventory.rpBotCompatibility.maximumVersionExclusive "Inventaire.rpBotCompatibility.maximumVersionExclusive" }
    Assert-PositiveInteger $inventory.fileCount "Inventaire.fileCount"; Assert-PositiveInteger $inventory.totalSizeBytes "Inventaire.totalSizeBytes"; Assert-Sha256 $inventory.sourceTreeSha256 "Inventaire.sourceTreeSha256"
    if (@($inventory.files).Count -ne [int]$inventory.fileCount) { Fail "Nombre de fichiers de décors incohérent." }
    [int64]$total = 0
    foreach ($file in $inventory.files) {
        Assert-ExactProperties $file @("fileName", "sizeBytes", "sha256") "Inventaire.files"
        Assert-FileName $file.fileName "Inventaire.files.fileName"; Assert-Sha256 $file.sha256 "Inventaire.files.sha256"
        $filePath = Join-Path $Directory $file.fileName
        if (-not (Test-VerifiedFile $filePath ([int64]$file.sizeBytes) $file.sha256)) { Fail "Fichier de décor invalide : $($file.fileName)" }
        $total += [int64]$file.sizeBytes
    }
    if ($total -ne [int64]$inventory.totalSizeBytes) { Fail "Taille totale des décors incohérente." }
    if (@(Get-ChildItem -LiteralPath $Directory -Recurse -Force -File).Count -ne ([int]$inventory.fileCount + 1)) { Fail "L'archive de décors contient des fichiers non déclarés." }
    if (@(Get-ChildItem -LiteralPath $Directory -Recurse -Force -Directory).Count -ne 0) { Fail "Les sous-dossiers sont interdits dans le pack de décors v1." }
}

function Install-Backgrounds($Manifest) {
    $versions = $Manifest.roleplayBackgrounds; $artifact = Get-Artifact $Manifest "roleplay-backgrounds"
    Set-InterruptedOperation "install" "roleplay-backgrounds" "downloading" "" $versions.contentVersion "Téléchargement du pack de décors en cours."
    $archive = Download-Verified "roleplay-backgrounds" $artifact
    $staging = Join-Path $Root ("assets\roleplay-backgrounds\.staging." + [Guid]::NewGuid()); Expand-SafeArchive $archive $staging; Verify-BackgroundTree $staging $versions
    $target = Join-Path $Root "assets\roleplay-backgrounds\$($versions.contentVersion)-format-$($versions.formatVersion)"
    Start-DirectorySwap $staging $target $staging; Activate-Backgrounds $versions.contentVersion $versions.formatVersion $target; Complete-DirectorySwap; Clear-InterruptedOperation
    Write-Host "Pack de décors $($versions.contentVersion) (format $($versions.formatVersion)) vérifié et activé."
}

function Write-UserLauncher([string]$SuiteRoot, $Local) {
    if ($null -eq $Local.components.rpBot) { return }
    $version = [string]$Local.components.rpBot.activeVersion
    Assert-SemVer $version "Lanceur RP Bot.version"
    $backgroundsSuffix = $null
    if ($null -ne $Local.components.roleplayBackgrounds) {
        $content = [string]$Local.components.roleplayBackgrounds.activeContentVersion
        $format = [string]$Local.components.roleplayBackgrounds.activeFormatVersion
        Assert-SemVer $content "Lanceur RP Bot.backgrounds.contentVersion"
        Assert-SemVer $format "Lanceur RP Bot.backgrounds.formatVersion"
        $backgroundsSuffix = "assets\roleplay-backgrounds\$content-format-$format"
    }
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null
    $launcherPath = Join-Path $SuiteRoot $script:UserLauncherName
    if (Test-Path -LiteralPath $launcherPath) {
        $existing = [IO.File]::ReadAllText($launcherPath)
        if (-not $existing.Contains("rem RP_BOT_MANAGED_LAUNCHER")) {
            Write-Warning "$launcherPath existe déjà et n'a pas été créé par RP Bot ; il est conservé."
            return
        }
    }
    $backgroundsLine = if ($backgroundsSuffix) {
        'set "RP_BOT_ROLEPLAY_BACKGROUNDS_DIR=%~dp0' + $backgroundsSuffix + '"'
    }
    else { 'set "RP_BOT_ROLEPLAY_BACKGROUNDS_DIR="' }
    $lines = @(
        '@echo off',
        'rem RP_BOT_MANAGED_LAUNCHER',
        'setlocal EnableExtensions DisableDelayedExpansion',
        'set "RP_BOT_DATA_DIR=%~dp0data\rp-bot"',
        $backgroundsLine,
        ('set "RP_BOT_ACTIVE_VERSION=' + $version + '"'),
        'if /i "%~1"=="--self-test" (',
        '  echo Version active : %RP_BOT_ACTIVE_VERSION%',
        '  echo Racine : %~dp0',
        '  echo Donnees : %RP_BOT_DATA_DIR%',
        '  echo Decors : %RP_BOT_ROLEPLAY_BACKGROUNDS_DIR%',
        '  exit /b 0',
        ')',
        'if not exist "%RP_BOT_DATA_DIR%" mkdir "%RP_BOT_DATA_DIR%"',
        'if not exist "%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" (',
        '  echo [ERREUR] Installation RP Bot incomplete dans %~dp0',
        '  exit /b 1',
        ')',
        'start "" /b powershell.exe -NoLogo -NoProfile -Command "$url=''http://127.0.0.1:8800'';for($attempt=0;$attempt -lt 60;$attempt++){try{$response=Invoke-WebRequest -UseBasicParsing -Uri ($url + ''/api/health'') -TimeoutSec 1;if($response.StatusCode -eq 200){Start-Process $url;exit 0}}catch{};Start-Sleep -Milliseconds 500}" >nul 2>&1',
        '"%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" "%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\launcher.mjs"',
        'exit /b %ERRORLEVEL%',
        ''
    )
    $temporary = Join-Path $SuiteRoot (".rp-bot-launcher.{0}.tmp" -f [Guid]::NewGuid())
    $backup = Join-Path $SuiteRoot (".rp-bot-launcher.{0}.bak" -f [Guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temporary, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $launcherPath) {
            [IO.File]::Replace($temporary, $launcherPath, $backup, $true)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        else { [IO.File]::Move($temporary, $launcherPath) }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Lanceur créé : $launcherPath"
    Write-Host "Vous pouvez déplacer le dossier RP Bot Suite complet."
}

function Write-PuLIDLaunchers([string]$SuiteRoot, $Local) {
    if ($null -eq $Local.components.pulid -or
        [string]$Local.components.pulid.installationType -ne "managed-local" -or
        $null -eq $Local.components.pulid.managedInstallation) { return }
    $version = [string]$Local.components.pulid.managedInstallation.activeVersion
    Assert-SemVer $version "Lanceur PuLID.version"
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null

    foreach ($launcher in @(
        [pscustomobject]@{ Name = $script:PuLIDLocalLauncherName; Mode = "local"; NetworkArgument = "" },
        [pscustomobject]@{ Name = $script:PuLIDNetworkLauncherName; Mode = "reseau"; NetworkArgument = "--network " }
    )) {
        $launcherPath = Join-Path $SuiteRoot $launcher.Name
        if (Test-Path -LiteralPath $launcherPath) {
            $existing = [IO.File]::ReadAllText($launcherPath)
            if (-not $existing.Contains("rem RP_BOT_MANAGED_PULID_LAUNCHER")) {
                Write-Warning "$launcherPath existe déjà et n'a pas été créé par RP Bot ; il est conservé."
                continue
            }
        }
        $lines = @(
            '@echo off',
            'rem RP_BOT_MANAGED_PULID_LAUNCHER',
            'setlocal EnableExtensions DisableDelayedExpansion',
            ('set "PULID_ACTIVE_VERSION=' + $version + '"'),
            ('set "PULID_LAUNCH_MODE=' + $launcher.Mode + '"'),
            'if /i "%~1"=="--self-test" (',
            '  echo Version active : %PULID_ACTIVE_VERSION%',
            '  echo Racine : %~dp0',
            '  echo Mode : %PULID_LAUNCH_MODE%',
            '  exit /b 0',
            ')',
            'set "PULID_START=%~dp0apps\pulid\%PULID_ACTIVE_VERSION%\start_windows.bat"',
            'if not exist "%PULID_START%" (',
            '  echo [ERREUR] Installation PuLID incomplete dans %~dp0',
            '  exit /b 1',
            ')',
            ('call "%PULID_START%" ' + $launcher.NetworkArgument + '%*'),
            'exit /b %ERRORLEVEL%',
            ''
        )
        $temporary = Join-Path $SuiteRoot (".pulid-launcher.{0}.tmp" -f [Guid]::NewGuid())
        $backup = Join-Path $SuiteRoot (".pulid-launcher.{0}.bak" -f [Guid]::NewGuid())
        try {
            [IO.File]::WriteAllText($temporary, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $launcherPath) {
                [IO.File]::Replace($temporary, $launcherPath, $backup, $true)
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            else { [IO.File]::Move($temporary, $launcherPath) }
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Lanceur créé : $launcherPath"
    }
    Write-Host "Le lanceur réseau écoute sur le LAN ; limitez le port 12693 au réseau de confiance dans le pare-feu Windows."
}

function Invoke-SelfTest {
    if (-not (Test-SafeArchiveEntry "folder/file.txt")) { Fail "Self-test archive sûr en échec." }
    if (Test-SafeArchiveEntry "../escape") { Fail "Self-test traversée en échec." }
    if (Test-SafeArchiveEntry "/absolute") { Fail "Self-test chemin absolu en échec." }
    if (Test-SafeArchiveEntry "C:\escape") { Fail "Self-test chemin Windows en échec." }
    $accented = "Téléchargement vérifié"
    $expectedAccented = "T" + [char]0x00E9 + "l" + [char]0x00E9 + "chargement v" + [char]0x00E9 + "rifi" + [char]0x00E9
    if (-not [string]::Equals($accented, $expectedAccented, [StringComparison]::Ordinal)) { Fail "Self-test encodage UTF-8 accentué en échec." }
    $cudaBannerFixture = "| NVIDIA-SMI 580.65 | Driver Version: 580.65 | CUDA Version: 13.0 |"
    if ((Get-NvidiaCudaMajorFromText $cudaBannerFixture) -ne 13) { Fail "Self-test bannière nvidia-smi CUDA en échec." }
    $cudaQueryFixture = "CUDA UMD Version : 13.1"
    if ((Get-NvidiaCudaMajorFromText $cudaQueryFixture) -ne 13) { Fail "Self-test sortie détaillée nvidia-smi CUDA en échec." }
    $cudaXmlFixture = '<?xml version="1.0" ?><nvidia_smi_log><cuda_umd_version>13.1</cuda_umd_version></nvidia_smi_log>'
    if ((Get-NvidiaCudaMajorFromXml $cudaXmlFixture) -ne 13) { Fail "Self-test XML nvidia-smi CUDA en échec." }
    $cudaUnavailableFixture = '<?xml version="1.0" ?><nvidia_smi_log><cuda_version>N/A</cuda_version></nvidia_smi_log>'
    if ($null -ne (Get-NvidiaCudaMajorFromXml $cudaUnavailableFixture)) { Fail "Self-test indisponibilité nvidia-smi CUDA en échec." }
    $singleArtifact = [pscustomobject]@{ component = "rp-bot"; platform = "windows"; architecture = "x64"; fileName = "rp-bot-single.zip" }
    $singleManifest = [pscustomobject]@{ artifacts = @($singleArtifact) }
    $selectedArtifact = Get-Artifact $singleManifest "rp-bot"
    if ($selectedArtifact.fileName -ne $singleArtifact.fileName) { Fail "Self-test artefact unique en échec." }
    $selfTestBase = Join-Path ([IO.Path]::GetTempPath()) ("rp-bot-installer-launcher-test." + [Guid]::NewGuid())
    $selfTestRoot = Join-Path $selfTestBase "RP Bot Suite test"
    $movedRoot = Join-Path $selfTestBase "RP Bot Suite moved"
    $previousStateDirectory = $script:StateDirectory
    $previousLocalManifestPath = $script:LocalManifestPath
    try {
        $script:StateDirectory = Join-Path $selfTestRoot "state"
        $script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
        Write-LocalManifestAtomic ([pscustomobject]@{ marker = "first" })
        Write-LocalManifestAtomic ([pscustomobject]@{ marker = "second" })
        $written = [IO.File]::ReadAllText($script:LocalManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($written.marker -ne "second") { Fail "Self-test remplacement atomique du manifeste local en échec." }
        if (@(Get-ChildItem -LiteralPath $script:StateDirectory -Force | Where-Object { $_.Name -ne "installation.json" }).Count -ne 0) { Fail "Self-test nettoyage du remplacement atomique en échec." }
        $script:StateDirectory = Join-Path $selfTestRoot "activation-state"
        $script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
        $activationManifest = [pscustomobject]@{
            schemaVersion = 1; suiteId = "rp-bot-suite"; updateChannel = "beta"
            components = [pscustomobject]@{ rpBot = $null; pulid = $null; roleplayBackgrounds = $null }
            paths = [pscustomobject]@{ rpBotData = (Join-Path $selfTestRoot "data\rp-bot") }
            lastHealthCheck = $null
            interruptedOperation = [pscustomobject]@{
                id = "self-test-operation"; kind = "install"; component = "rp-bot"; stage = "extract"
                startedAt = "2026-08-29T00:00:00.000Z"; updatedAt = "2026-08-29T00:00:01.000Z"
                fromVersion = $null; toVersion = "0.2.0-beta.1"; checkpoint = "Self-test"; recoveryActions = @("resume", "cancel")
            }
        }
        Write-LocalManifestAtomic $activationManifest
        Activate-RpBot "0.2.0-beta.1" "C:\rp-bot-old"
        Activate-RpBot "0.2.0-beta.1" "C:\rp-bot-new"
        $activatedLocal = Read-LocalManifest
        if (@($activatedLocal.components.rpBot.releases).Count -ne 1 -or $activatedLocal.components.rpBot.releases[0].releasePath -ne "C:\rp-bot-new") {
            Fail "Self-test activation répétée de RP Bot en échec."
        }
        Activate-RpBot "0.2.0-beta.2" "C:\rp-bot-next"
        $activatedLocal = Read-LocalManifest
        if (@($activatedLocal.components.rpBot.releases).Count -ne 2) { Fail "Self-test ajout d'une release RP Bot en échec." }
        Activate-PuLID "0.1.0" "C:\pulid-old" "C:\models-old"
        Activate-PuLID "0.1.0" "C:\pulid-new" "C:\models-new"
        $activatedLocal = Read-LocalManifest
        if (@($activatedLocal.components.pulid.managedInstallation.releases).Count -ne 1 -or $activatedLocal.components.pulid.managedInstallation.releases[0].releasePath -ne "C:\pulid-new") {
            Fail "Self-test activation répétée de PuLID en échec."
        }
        Activate-Backgrounds "1.0.0" "1.0.0" "C:\backgrounds-old"
        Activate-Backgrounds "1.0.0" "1.0.0" "C:\backgrounds-new"
        $activatedLocal = Read-LocalManifest
        if (@($activatedLocal.components.roleplayBackgrounds.releases).Count -ne 1 -or $activatedLocal.components.roleplayBackgrounds.releases[0].releasePath -ne "C:\backgrounds-new") {
            Fail "Self-test activation répétée des décors en échec."
        }
        $buildFixturePath = Join-Path $selfTestRoot "build.json"
        $buildFixture = [pscustomobject]@{
            schemaVersion = 1; application = "rp-bot"; version = "0.2.0-beta.1"
            buildId = "self-test-build"; builtAt = "2026-08-29T00:00:00.000Z"
            target = [pscustomobject]@{ platform = "windows"; arch = "x64" }
            nodeRuntimeVersion = "24.5.0"; signed = $false
        }
        [IO.File]::WriteAllText($buildFixturePath, (($buildFixture | ConvertTo-Json -Depth 5) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
        $parsedBuildVersion = Read-RpBotBuildVersion $buildFixturePath
        if ($parsedBuildVersion -ne "0.2.0-beta.1") {
            Fail "Self-test lecture des métadonnées RP Bot en échec."
        }
        $launcherLocal = [pscustomobject]@{
            components = [pscustomobject]@{
                rpBot = [pscustomobject]@{ activeVersion = "0.2.0-beta.1" }
                pulid = [pscustomobject]@{
                    installationType = "managed-local"
                    managedInstallation = [pscustomobject]@{ activeVersion = "0.1.0" }
                }
                roleplayBackgrounds = [pscustomobject]@{ activeContentVersion = "1.0.0"; activeFormatVersion = "1.0.0" }
            }
        }
        Write-UserLauncher $selfTestRoot $launcherLocal
        Write-PuLIDLaunchers $selfTestRoot $launcherLocal
        $launcherPath = Join-Path $selfTestRoot $script:UserLauncherName
        $launcherContents = [IO.File]::ReadAllText($launcherPath)
        if (-not $launcherContents.Contains('set "RP_BOT_DATA_DIR=%~dp0data\rp-bot"') -or
            -not $launcherContents.Contains('set "RP_BOT_ROLEPLAY_BACKGROUNDS_DIR=%~dp0assets\roleplay-backgrounds\1.0.0-format-1.0.0"')) {
            Fail "Self-test chemins relatifs du lanceur Windows en échec."
        }
        $launcherOutput = @(& $launcherPath --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launcherOutput -notlike "*Version active : 0.2.0-beta.1*" -or $launcherOutput -notlike "*Donnees : $selfTestRoot\data\rp-bot*") {
            Fail "Self-test exécution du lanceur Windows en échec."
        }
        $pulidLocalLauncher = Join-Path $selfTestRoot $script:PuLIDLocalLauncherName
        $pulidNetworkLauncher = Join-Path $selfTestRoot $script:PuLIDNetworkLauncherName
        $pulidLocalContents = [IO.File]::ReadAllText($pulidLocalLauncher)
        $pulidNetworkContents = [IO.File]::ReadAllText($pulidNetworkLauncher)
        if (-not $pulidLocalContents.Contains('call "%PULID_START%" %*') -or
            -not $pulidNetworkContents.Contains('call "%PULID_START%" --network %*')) {
            Fail "Self-test arguments des lanceurs PuLID en échec."
        }
        $pulidLocalOutput = @(& $pulidLocalLauncher --self-test 2>&1) -join "`n"
        $pulidLocalExitCode = $LASTEXITCODE
        $pulidNetworkOutput = @(& $pulidNetworkLauncher --self-test 2>&1) -join "`n"
        $pulidNetworkExitCode = $LASTEXITCODE
        if ($pulidLocalExitCode -ne 0 -or $pulidLocalOutput -notlike "*Version active : 0.1.0*" -or $pulidLocalOutput -notlike "*Mode : local*") {
            Fail "Self-test lanceur PuLID local en échec."
        }
        if ($pulidNetworkExitCode -ne 0 -or $pulidNetworkOutput -notlike "*Version active : 0.1.0*" -or $pulidNetworkOutput -notlike "*Mode : reseau*") {
            Fail "Self-test lanceur PuLID réseau en échec."
        }
        Copy-Item -LiteralPath $selfTestRoot -Destination $movedRoot -Recurse
        $movedLauncher = Join-Path $movedRoot $script:UserLauncherName
        $movedOutput = @(& $movedLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $movedOutput -notlike "*Donnees : $movedRoot\data\rp-bot*") {
            Fail "Self-test déplacement de la suite Windows en échec."
        }
        $movedPulidNetworkLauncher = Join-Path $movedRoot $script:PuLIDNetworkLauncherName
        $movedPulidNetworkOutput = @(& $movedPulidNetworkLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $movedPulidNetworkOutput -notlike "*Racine : $movedRoot\*") {
            Fail "Self-test déplacement du lanceur PuLID réseau en échec."
        }
    } finally {
        $script:StateDirectory = $previousStateDirectory
        $script:LocalManifestPath = $previousLocalManifestPath
        if (Test-Path -LiteralPath $selfTestBase) { Remove-Item -LiteralPath $selfTestBase -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "Self-test installateur Windows : OK"
}

function Main {
    if ($SelfTest) { Invoke-SelfTest; return }
    if (-not [IO.Path]::IsPathRooted($Root)) { Fail "-Root doit être un chemin absolu." }
    $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("rp-bot-installer." + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $script:DownloadDirectory -Force | Out-Null
    Write-Host "Dossier de suite : $Root"

    Write-Section "Lecture du canal $Channel"
    $pointerUrl = "$($script:PublicRawBase)/latest-$Channel.json"; $pointerPath = Join-Path $script:TemporaryRoot "latest-$Channel.json"
    Download-Small "pointer" $pointerUrl $pointerPath; $pointer = Read-ChannelPointer $pointerPath
    Verify-Signature $pointerPath $pointer.channelSignature
    $manifestArtifact = [pscustomobject]@{ fileName = $pointer.manifest.fileName; url = $pointer.manifest.url; sizeBytes = $pointer.manifest.sizeBytes; sha256 = $pointer.manifest.sha256; signature = $pointer.manifest.signature }
    $manifestPath = Download-Verified "manifest" $manifestArtifact; $manifest = Read-SuiteManifest $manifestPath
    $local = Read-LocalManifest
    $currentRp = if ($null -eq $local.components.rpBot) { "" } else { [string]$local.components.rpBot.activeVersion }
    $currentPulid = if ($null -eq $local.components.pulid) { "" } else { [string]$local.components.pulid.detectedVersion }
    $pulidInstallationType = if ($null -eq $local.components.pulid) { "" } else { [string]$local.components.pulid.installationType }
    $currentBgContent = if ($null -eq $local.components.roleplayBackgrounds) { "" } else { [string]$local.components.roleplayBackgrounds.activeContentVersion }
    $currentBgFormat = if ($null -eq $local.components.roleplayBackgrounds) { "" } else { [string]$local.components.roleplayBackgrounds.activeFormatVersion }
    Write-Host ""; Write-Host "État détecté"
    if ($currentRp) {
        $rpAction = if ($currentRp -eq $manifest.rpBot.version) { "[Réparer]" } else { "[Mettre à jour]" }
        Write-Host "  RP Bot   installé — $currentRp   $rpAction"
    } else { Write-Host "  RP Bot   non installé             [Installer]" }
    if ($currentPulid) {
        $pulidAction = if ($pulidInstallationType -ne "managed-local") { "[Information uniquement]" } elseif ($currentPulid -eq $manifest.pulid.compatibleVersion) { "[Réparer]" } else { "[Mettre à jour]" }
        Write-Host "  PuLID    installé — $currentPulid ($pulidInstallationType)   $pulidAction"
    } else { Write-Host "  PuLID    non installé             [Installer]" }
    Write-Host "  Une ligne non sélectionnée sera conservée sans modification."
    if ($null -ne $local.interruptedOperation) { Write-Warning ("Opération interrompue détectée : " + $local.interruptedOperation.checkpoint + " Le relancement revalidera le téléchargement avant de reprendre.") }

    if (-not $Select) {
        Write-Host ""; Write-Host "1. RP Bot"; Write-Host "2. PuLID"; Write-Host "3. RP Bot et PuLID"
        do { $choice = Read-Host "Choix [1-3]" } until ($choice -in @("1", "2", "3"))
        $script:Select = @{ "1" = "rp-bot"; "2" = "pulid"; "3" = "both" }[$choice]
    }
    $installRp = $Select -in @("rp-bot", "both"); $installPulid = $Select -in @("pulid", "both"); $installBackgrounds = $false
    if ($installPulid -and $pulidInstallationType -and $pulidInstallationType -ne "managed-local") { Fail "PuLID est déclaré $pulidInstallationType. L'installateur ne modifie jamais une installation externe ou distante." }
    if ($installRp) {
        if ($currentBgContent -eq $manifest.roleplayBackgrounds.contentVersion -and $currentBgFormat -eq $manifest.roleplayBackgrounds.formatVersion) { Write-Host "Le pack de décors compatible est déjà installé ; aucun téléchargement." }
        elseif ($Backgrounds -eq "yes" -or ($Backgrounds -eq "ask" -and (Confirm-YesNo "Installer le pack de décors recommandé ($((Get-Artifact $manifest 'roleplay-backgrounds').sizeBytes) octets) ?" $true))) { $installBackgrounds = $true }
    }
    if ($installPulid) {
        if (-not $ModelsRoot -and $null -ne $local.components.pulid) { $script:ModelsRoot = [string]$local.components.pulid.modelsPath }
        if (-not $ModelsRoot) {
            $defaultModels = Join-Path $Root "models\PuLID_models"
            if (Confirm-YesNo "Utiliser $defaultModels pour les modèles PuLID ?" $true) { $script:ModelsRoot = $defaultModels }
            else { $script:ModelsRoot = Read-Host "Chemin absolu du dossier PuLID_models (SSD externe accepté)" }
        }
        if (-not [IO.Path]::IsPathRooted($ModelsRoot)) { Fail "Le dossier de modèles doit être absolu." }
        Write-Host ""; Write-Host "Licence InsightFace/AntelopeV2 : poids réservés à la recherche non commerciale."
        Write-Host "https://github.com/deepinsight/insightface/blob/master/server/LICENSING.md"
        if (-not (Confirm-YesNo "Acceptez-vous explicitement ces conditions avant tout téléchargement de modèle ?" $false)) { Fail "Licence InsightFace refusée ; PuLID n'a pas été installé." }
    }

    $unsigned = New-Object Collections.Generic.List[string]
    if ($pointer.channelSignature.status -eq "unsigned-mvp") { $unsigned.Add("Pointeur : " + $pointer.channelSignature.reason) }
    if ($manifest.manifestSignature.status -eq "unsigned-mvp") { $unsigned.Add("Manifeste : " + $manifest.manifestSignature.reason) }
    foreach ($artifact in $manifest.artifacts) { if ($artifact.signature.status -eq "unsigned-mvp") { $unsigned.Add($artifact.component + " : " + $artifact.signature.reason) } }
    if ($unsigned.Count -gt 0) {
        Write-Host ""; Write-Warning "Prerelease MVP non signée"; $unsigned | ForEach-Object { Write-Host "  $_" }
        Write-Host "HTTPS, taille et SHA-256 seront vérifiés. Aucune mise à jour silencieuse ne sera effectuée."
        if (-not $AcceptUnsignedMvp -and -not (Confirm-YesNo "Continuer avec cette release non signée ?" $false)) { Fail "Installation annulée avant les gros téléchargements." }
    }
    Write-Section "Préflight matériel, disque, ports et réseau"; Run-Preflight $manifest $installRp $installPulid $installBackgrounds
    if ($installRp) { Install-RpBot $manifest $currentRp }
    if ($installPulid) { Install-PuLID $manifest $currentPulid }
    if ($installBackgrounds) { Install-Backgrounds $manifest }
    $installedLocal = Read-LocalManifest
    if ($null -ne $installedLocal.components.rpBot) { Write-UserLauncher $Root $installedLocal }
    if ($null -ne $installedLocal.components.pulid) { Write-PuLIDLaunchers $Root $installedLocal }
    Write-Section "Installation terminée"
    Write-Host "Manifeste local : $($script:LocalManifestPath)"
    Write-Host "Les composants non sélectionnés, les données RP Bot et les modèles PuLID n'ont pas été supprimés."
}

try { Main }
catch {
    if ($null -ne $script:Swap) { Undo-DirectorySwap }
    $location = $_.InvocationInfo.PositionMessage
    Write-Error ($_.Exception.Message + $(if ($location) { "`r`n$location" } else { "" }))
    exit 1
}
finally { if ($script:TemporaryRoot -and (Test-Path -LiteralPath $script:TemporaryRoot)) { Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue } }
