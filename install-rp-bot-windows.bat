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
    [ValidateSet("rp-bot", "pulid", "both")]
    [string]$Uninstall,
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
    [switch]$DeleteRpBotData,
    [switch]$DeletePuLIDModels,
    [switch]$ConfirmUninstall,
    [switch]$ConfirmDataDeletion,
    [switch]$ConfirmModelsDeletion,
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
$script:UpdaterLauncherName = "Mettre a jour RP Bot.bat"
$script:SuiteRuntimeDirectory = Join-Path $Root "runtimes\rp-bot-suite"
$script:SuiteLauncherPath = Join-Path $script:SuiteRuntimeDirectory "suite-launcher.mjs"
$script:LauncherManifestReaderName = "read-active-version.ps1"
$script:PuLIDRuntimeRepairerName = "repair-pulid-runtime.ps1"
$script:StateDirectory = Join-Path $Root "state"
$script:DownloadDirectory = Join-Path $script:StateDirectory "downloads"
$script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
$script:TemporaryRoot = $null
$script:Swap = $null
$script:SdxlMode = "skip"
$script:StagedSdxlCheckpoint = $null
$script:SdxlStagingDirectory = $null

function Fail([string]$Message) {
    throw $Message
}

function Write-Section([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Initialize-PermanentDirectories {
    foreach ($relativePath in @(
        "apps\rp-bot", "apps\pulid", "assets\roleplay-backgrounds",
        "runtimes\rp-bot-suite", "state", "state\downloads",
        "state\backups\rp-bot", "logs", "logs\rp-bot", "logs\pulid",
        "data\rp-bot"
    )) {
        New-Item -ItemType Directory -Path (Join-Path $Root $relativePath) -Force | Out-Null
    }
    $dataDirectory = Join-Path $Root "data\rp-bot"
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $icacls = Join-Path $env:SystemRoot "System32\icacls.exe"
    $aclOutput = @(& $icacls $dataDirectory "/inheritance:r" "/grant:r" "${currentIdentity}:(OI)(CI)F" "/grant:r" "*S-1-5-18:(OI)(CI)F" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Impossible de limiter les ACL de $dataDirectory sur ce volume. " + ($aclOutput -join " "))
    }
}

function Install-SuiteRuntime([string]$ReleaseRoot) {
    New-Item -ItemType Directory -Path $script:SuiteRuntimeDirectory -Force | Out-Null
    foreach ($fileName in @("suite-launcher.mjs", "suite-updater.mjs", "update-request-contract.mjs", "safe-extract-windows.ps1")) {
        $sourcePath = Join-Path $ReleaseRoot ("suite-runtime\" + $fileName)
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { Fail "L'artefact RP Bot ne contient pas $fileName." }
        $destinationPath = Join-Path $script:SuiteRuntimeDirectory $fileName
        $temporary = Join-Path $script:SuiteRuntimeDirectory (".{0}.{1}.tmp" -f $fileName, [Guid]::NewGuid())
        $backup = Join-Path $script:SuiteRuntimeDirectory (".{0}.{1}.bak" -f $fileName, [Guid]::NewGuid())
        try {
            Copy-Item -LiteralPath $sourcePath -Destination $temporary
            if (Test-Path -LiteralPath $destinationPath) {
                [IO.File]::Replace($temporary, $destinationPath, $backup, $true)
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            else { [IO.File]::Move($temporary, $destinationPath) }
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-LauncherManifestReader([string]$SuiteRoot) {
    $runtimeDirectory = Join-Path $SuiteRoot "runtimes\rp-bot-suite"
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    $readerPath = Join-Path $runtimeDirectory $script:LauncherManifestReaderName
    $contents = @'
# RP_BOT_MANAGED_MANIFEST_READER
#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("rp-bot", "pulid")]
    [string]$Component,
    [ValidateSet("version", "models-path", "previous-suite-root")]
    [string]$Field = "version",
    [string]$SuiteRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Component -eq "rp-bot") {
        if ($Field -ne "version") { throw "RP Bot exposes only its active version." }
        $version = [string]$manifest.components.rpBot.activeVersion
    }
    else {
        $pulid = $manifest.components.pulid
        if ($null -eq $pulid -or [string]$pulid.installationType -ne "managed-local" -or $null -eq $pulid.managedInstallation) {
            throw "Managed local PuLID is not installed."
        }
        $version = [string]$pulid.managedInstallation.activeVersion
    }
    if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
        throw "The active component version is not valid SemVer."
    }
    $recordedRoot = $null
    if ($Component -eq "pulid" -and $Field -ne "version") {
        $recordedDataPath = [IO.Path]::GetFullPath([string]$manifest.paths.rpBotData)
        $dataDirectory = [IO.Directory]::GetParent($recordedDataPath)
        $candidate = if ($null -eq $dataDirectory) { $null } else { $dataDirectory.Parent }
        if ($null -ne $candidate) {
            $expectedDataPath = [IO.Path]::GetFullPath((Join-Path $candidate.FullName "data\rp-bot"))
            $pathSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            if ([string]::Equals($recordedDataPath.TrimEnd($pathSeparators), $expectedDataPath.TrimEnd($pathSeparators), [StringComparison]::OrdinalIgnoreCase)) {
                $recordedRoot = $candidate.FullName
            }
        }
    }
    if ($Field -eq "version") {
        [Console]::Out.WriteLine($version)
    }
    elseif ($Field -eq "previous-suite-root") {
        if ($null -eq $recordedRoot) { throw "The recorded suite root cannot be inferred." }
        [Console]::Out.WriteLine($recordedRoot)
    }
    else {
        $modelsPath = [IO.Path]::GetFullPath([string]$pulid.modelsPath)
        if (-not [string]::IsNullOrWhiteSpace($SuiteRoot) -and $null -ne $recordedRoot) {
            $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $recordedPrefix = $recordedRoot.TrimEnd($separators) + [IO.Path]::DirectorySeparatorChar
            if ($modelsPath.StartsWith($recordedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $relativeModelsPath = $modelsPath.Substring($recordedPrefix.Length)
                $modelsPath = Join-Path ([IO.Path]::GetFullPath($SuiteRoot)) $relativeModelsPath
            }
        }
        [Console]::Out.WriteLine($modelsPath)
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    $temporary = Join-Path $runtimeDirectory (".{0}.{1}.tmp" -f $script:LauncherManifestReaderName, [Guid]::NewGuid())
    $backup = Join-Path $runtimeDirectory (".{0}.{1}.bak" -f $script:LauncherManifestReaderName, [Guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temporary, $contents, (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $readerPath) {
            [IO.File]::Replace($temporary, $readerPath, $backup, $true)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        else { [IO.File]::Move($temporary, $readerPath) }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Write-PuLIDRuntimeRepairer([string]$SuiteRoot) {
    $runtimeDirectory = Join-Path $SuiteRoot "runtimes\rp-bot-suite"
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    $repairerPath = Join-Path $runtimeDirectory $script:PuLIDRuntimeRepairerName
    $contents = @'
# RP_BOT_MANAGED_PULID_RUNTIME_REPAIRER
#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VenvPath,
    [Parameter(Mandatory = $true)]
    [string]$PreviousSuiteRoot,
    [Parameter(Mandatory = $true)]
    [string]$SuiteRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $pathSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $previousRoot = [IO.Path]::GetFullPath($PreviousSuiteRoot).TrimEnd($pathSeparators)
    $currentRoot = [IO.Path]::GetFullPath($SuiteRoot).TrimEnd($pathSeparators)
    if ([string]::Equals($previousRoot, $currentRoot, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    $configurationPath = Join-Path ([IO.Path]::GetFullPath($VenvPath)) "pyvenv.cfg"
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { exit 0 }
    $contents = [IO.File]::ReadAllText($configurationPath)
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($match) $currentRoot }
    $updated = [Text.RegularExpressions.Regex]::Replace(
        $contents,
        [Text.RegularExpressions.Regex]::Escape($previousRoot),
        $evaluator,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($updated -ne $contents) {
        $temporary = "$configurationPath.$([Guid]::NewGuid()).tmp"
        try {
            [IO.File]::WriteAllText($temporary, $updated, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::Copy($temporary, $configurationPath, $true)
        }
        finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    $temporary = Join-Path $runtimeDirectory (".{0}.{1}.tmp" -f $script:PuLIDRuntimeRepairerName, [Guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($temporary, $contents, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::Copy($temporary, $repairerPath, $true)
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
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

function Get-SdxlCheckpoints([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -File -Filter "*.safetensors" -ErrorAction Stop | Sort-Object Name)
}

function Read-SdxlChoices {
    $checkpointsDirectory = Join-Path $ModelsRoot "checkpoints"
    $checkpoints = @(Get-SdxlCheckpoints $checkpointsDirectory)
    if ($checkpoints.Count -gt 0) {
        $script:SdxlMode = "ask"
        Write-Host "Checkpoint SDXL existant détecté : $($checkpoints[0].FullName)"
        return
    }
    if (-not (Confirm-YesNo "Souhaitez-vous installer un modèle SDXL maintenant ?" $true)) {
        $script:SdxlMode = "skip"
        return
    }
    if (-not (Confirm-YesNo "Avez-vous déjà un modèle SDXL au format .safetensors ?" $false)) {
        $script:SdxlMode = if (Confirm-YesNo "Télécharger le modèle officiel Stable Diffusion XL Base 1.0 (~6,9 Go) ?" $true) { "download" } else { "skip" }
        return
    }

    $stagingDirectory = Join-Path $Root "Modele SDXL temporaire"
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    $script:SdxlStagingDirectory = $stagingDirectory
    Write-Host ""
    Write-Host "Copiez un seul checkpoint SDXL .safetensors dans ce dossier temporaire :"
    Write-Host "  $stagingDirectory"
    Write-Host "Placez-y une copie : le dépôt sera supprimé après son transfert vers PuLID_models."
    Write-Host "Si une étape antérieure échoue, il restera dans RP Bot Suite pour la reprise."
    while ($true) {
        Read-Host "Appuyez sur Entrée lorsque la copie est terminée" | Out-Null
        $stagedCheckpoints = @(Get-SdxlCheckpoints $stagingDirectory)
        if ($stagedCheckpoints.Count -eq 1) {
            $script:SdxlMode = "ask"
            $script:StagedSdxlCheckpoint = $stagedCheckpoints[0].FullName
            return
        }
        Write-Host "Un seul fichier .safetensors est attendu dans $stagingDirectory ; $($stagedCheckpoints.Count) détecté(s)."
    }
}

function Install-StagedSdxlCheckpoint {
    if ([string]::IsNullOrWhiteSpace([string]$script:StagedSdxlCheckpoint)) { return }
    $stagedParent = [IO.Directory]::GetParent([IO.Path]::GetFullPath([string]$script:StagedSdxlCheckpoint))
    if ([string]::IsNullOrWhiteSpace([string]$script:SdxlStagingDirectory) -or $null -eq $stagedParent -or
        -not (Test-NativePathEqual $stagedParent.FullName $script:SdxlStagingDirectory)) {
        Fail "Le checkpoint SDXL temporaire ne provient pas du dossier géré par l'installeur."
    }
    $checkpointsDirectory = Join-Path $ModelsRoot "checkpoints"
    New-Item -ItemType Directory -Path $checkpointsDirectory -Force | Out-Null
    $fileName = [IO.Path]::GetFileName([string]$script:StagedSdxlCheckpoint)
    $destination = Join-Path $checkpointsDirectory $fileName
    if (Test-Path -LiteralPath $destination) { Fail "Un checkpoint SDXL porte déjà ce nom : $destination" }
    $temporaryDestination = Join-Path $checkpointsDirectory (".{0}.{1}.tmp" -f $fileName, [Guid]::NewGuid())
    try {
        Copy-Item -LiteralPath $script:StagedSdxlCheckpoint -Destination $temporaryDestination
        Move-Item -LiteralPath $temporaryDestination -Destination $destination
    }
    finally { Remove-Item -LiteralPath $temporaryDestination -Force -ErrorAction SilentlyContinue }
    try { Remove-Item -LiteralPath $script:StagedSdxlCheckpoint -Force -ErrorAction Stop }
    catch { Write-Warning "La copie temporaire SDXL n'a pas pu être supprimée : $($script:StagedSdxlCheckpoint)" }
    Remove-Item -LiteralPath $script:SdxlStagingDirectory -Force -ErrorAction SilentlyContinue
    $script:StagedSdxlCheckpoint = $null
    $script:SdxlStagingDirectory = $null
    Write-Host "Checkpoint SDXL copié : $destination"
}

function Test-NativePathEqual([string]$Left, [string]$Right) {
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedLeft = [IO.Path]::GetFullPath($Left).TrimEnd($separators)
    $normalizedRight = [IO.Path]::GetFullPath($Right).TrimEnd($separators)
    return [string]::Equals($normalizedLeft, $normalizedRight, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PortableModelsPath($Local) {
    if ($null -eq $Local.components.pulid -or [string]::IsNullOrWhiteSpace([string]$Local.components.pulid.modelsPath)) { return "" }
    $modelsPath = [IO.Path]::GetFullPath([string]$Local.components.pulid.modelsPath)
    $recordedDataPath = [IO.Path]::GetFullPath([string]$Local.paths.rpBotData)
    $dataDirectory = [IO.Directory]::GetParent($recordedDataPath)
    $candidate = if ($null -eq $dataDirectory) { $null } else { $dataDirectory.Parent }
    if ($null -eq $candidate -or -not (Test-NativePathEqual $recordedDataPath (Join-Path $candidate.FullName "data\rp-bot"))) { return $modelsPath }
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $recordedPrefix = $candidate.FullName.TrimEnd($separators) + [IO.Path]::DirectorySeparatorChar
    if (-not $modelsPath.StartsWith($recordedPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $modelsPath }
    return (Join-Path ([IO.Path]::GetFullPath($Root)) $modelsPath.Substring($recordedPrefix.Length))
}

function Assert-SuiteStopped {
    $lockDirectory = Join-Path $Root "state\launcher.lock"
    if (-not (Test-Path -LiteralPath $lockDirectory)) { return }
    $ownerPath = Join-Path $lockDirectory "owner.json"
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
        Fail "Un verrou de lancement incomplet est présent. Fermez RP Bot et PuLID, puis réessayez."
    }
    $owner = Read-JsonStrict $ownerPath "Verrou de lancement"
    if ([string]$owner.manager -ne "rp-bot-suite-launcher" -or $owner.pid -isnot [ValueType] -or [int]$owner.pid -le 0) {
        Fail "Le verrou de lancement est inconnu ; aucun processus ni binaire n'a été modifié."
    }
    if ($null -ne (Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue)) {
        Fail "RP Bot Suite est encore active (gestionnaire PID $($owner.pid)). Fermez-la avant la désinstallation."
    }
}

function Remove-ManagedFile([string]$Path, [string]$Marker, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or -not [IO.File]::ReadAllText($Path).Contains($Marker)) {
        Write-Warning "$Label n'est pas géré par RP Bot et a été conservé : $Path"
        return
    }
    Remove-Item -LiteralPath $Path -Force
    Write-Host "Supprimé : $Label — $Path"
}

function Remove-RpRuntimeFiles([bool]$KeepPuLID) {
    $removed = $false
    foreach ($fileName in @("suite-launcher.mjs", "suite-updater.mjs", "update-request-contract.mjs", "safe-extract-windows.ps1")) {
        $filePath = Join-Path $script:SuiteRuntimeDirectory $fileName
        if (Test-Path -LiteralPath $filePath) { $removed = $true; Remove-Item -LiteralPath $filePath -Force }
    }
    if (-not $KeepPuLID) {
        foreach ($fileName in @($script:LauncherManifestReaderName, $script:PuLIDRuntimeRepairerName)) {
            $filePath = Join-Path $script:SuiteRuntimeDirectory $fileName
            if (Test-Path -LiteralPath $filePath) { $removed = $true; Remove-Item -LiteralPath $filePath -Force }
        }
    }
    if (Test-Path -LiteralPath $script:SuiteRuntimeDirectory -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $script:SuiteRuntimeDirectory -Force)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $script:SuiteRuntimeDirectory -Force }
    }
    if ($removed) { Write-Host "Supprimé : runtime externe RP Bot — $($script:SuiteRuntimeDirectory)" }
}

function Remove-SelectedModels([string]$ModelsPath) {
    if ([string]::IsNullOrWhiteSpace($ModelsPath) -or -not [IO.Path]::IsPathRooted($ModelsPath)) {
        Fail "Le chemin de modèles PuLID enregistré n'est pas un chemin absolu sûr."
    }
    $fullPath = [IO.Path]::GetFullPath($ModelsPath)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ((Test-NativePathEqual $fullPath $pathRoot) -or
        (Test-NativePathEqual $fullPath $Root) -or
        (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and (Test-NativePathEqual $fullPath $env:USERPROFILE))) {
        Fail "Suppression de sécurité refusée pour le dossier de modèles : $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Le dossier de modèles est un lien ou point de jonction ; sa suppression automatique est refusée : $fullPath"
        }
        Remove-Item -LiteralPath $fullPath -Recurse -Force
        Write-Host "Supprimé : modèles PuLID — $fullPath"
    }
    else { Write-Host "Déjà absent : modèles PuLID — $fullPath" }
}

function Uninstall-RpBot([bool]$DeleteData) {
    $local = Read-LocalManifest
    $currentVersion = if ($null -eq $local.components.rpBot) { "" } else { [string]$local.components.rpBot.activeVersion }
    $keepPuLID = $null -ne $local.components.pulid -and [string]$local.components.pulid.installationType -eq "managed-local"
    Set-InterruptedOperation "uninstall" "rp-bot" "installing" $currentVersion "" "Suppression des binaires RP Bot en cours."
    $appsPath = Join-Path $Root "apps\rp-bot"
    if (Test-Path -LiteralPath $appsPath) {
        Remove-Item -LiteralPath $appsPath -Recurse -Force
        Write-Host "Supprimé : binaires RP Bot — $appsPath"
    }
    else { Write-Host "Déjà absent : binaires RP Bot — $appsPath" }
    Remove-ManagedFile (Join-Path $Root $script:UserLauncherName) "rem RP_BOT_MANAGED_LAUNCHER" "lanceur RP Bot"
    Remove-ManagedFile (Join-Path $Root $script:UpdaterLauncherName) "rem RP_BOT_MANAGED_UPDATER_LAUNCHER" "lanceur de mise à jour RP Bot"
    $updateRequestPath = Join-Path $script:StateDirectory "update-request.json"
    if (Test-Path -LiteralPath $updateRequestPath) { Remove-Item -LiteralPath $updateRequestPath -Force }
    $suiteControlPath = Join-Path $script:StateDirectory "suite-control.json"
    if (Test-Path -LiteralPath $suiteControlPath) { Remove-Item -LiteralPath $suiteControlPath -Force }
    Remove-RpRuntimeFiles $keepPuLID
    $dataPath = Join-Path $Root "data\rp-bot"
    if ($DeleteData) {
        if (Test-Path -LiteralPath $dataPath) {
            Remove-Item -LiteralPath $dataPath -Recurse -Force
            Write-Host "Supprimé : données RP Bot — $dataPath"
        }
        else { Write-Host "Déjà absent : données RP Bot — $dataPath" }
    }
    else { Write-Host "Conservé : données RP Bot — $dataPath" }
    $local = Read-LocalManifest
    $local.components.rpBot = $null
    $local.lastHealthCheck = $null
    Write-LocalManifestAtomic $local
    Clear-InterruptedOperation
}

function Uninstall-PuLID([bool]$DeleteModels) {
    $local = Read-LocalManifest
    $currentType = if ($null -eq $local.components.pulid) { "" } else { [string]$local.components.pulid.installationType }
    if ($currentType -and $currentType -ne "managed-local") {
        Fail "PuLID est déclaré $currentType. Une installation externe ou distante n'est jamais désinstallée par RP Bot Suite."
    }
    $currentVersion = if ($null -eq $local.components.pulid) { "" } else { [string]$local.components.pulid.detectedVersion }
    $modelsPath = Get-PortableModelsPath $local
    $keepRpBot = $null -ne $local.components.rpBot
    Set-InterruptedOperation "uninstall" "pulid" "installing" $currentVersion "" "Suppression des binaires PuLID en cours."
    $appsPath = Join-Path $Root "apps\pulid"
    if (Test-Path -LiteralPath $appsPath) {
        Remove-Item -LiteralPath $appsPath -Recurse -Force
        Write-Host "Supprimé : binaires PuLID — $appsPath"
    }
    else { Write-Host "Déjà absent : binaires PuLID — $appsPath" }
    Remove-ManagedFile (Join-Path $Root $script:PuLIDLocalLauncherName) "rem RP_BOT_MANAGED_PULID_LAUNCHER" "lanceur PuLID local"
    Remove-ManagedFile (Join-Path $Root $script:PuLIDNetworkLauncherName) "rem RP_BOT_MANAGED_PULID_LAUNCHER" "lanceur PuLID réseau"
    $repairerPath = Join-Path $script:SuiteRuntimeDirectory $script:PuLIDRuntimeRepairerName
    if (Test-Path -LiteralPath $repairerPath) { Remove-Item -LiteralPath $repairerPath -Force }
    if ($DeleteModels) {
        if ([string]::IsNullOrWhiteSpace($modelsPath)) { Fail "Aucun dossier de modèles PuLID géré n'est enregistré ; suppression refusée." }
        Remove-SelectedModels $modelsPath
    }
    else { Write-Host "Conservé : modèles PuLID — $(if ($modelsPath) { $modelsPath } else { 'aucun dossier géré' })" }
    $local = Read-LocalManifest
    $local.components.pulid = $null
    $local.lastHealthCheck = $null
    Write-LocalManifestAtomic $local
    Clear-InterruptedOperation
    if (-not $keepRpBot) { Remove-RpRuntimeFiles $false }
}

function Invoke-Uninstall {
    if (-not (Test-Path -LiteralPath $script:LocalManifestPath -PathType Leaf)) { Fail "Aucune installation gérée n'a été trouvée : $($script:LocalManifestPath)" }
    $fullSuiteRoot = [IO.Path]::GetFullPath($Root)
    $volumeRoot = [IO.Path]::GetPathRoot($fullSuiteRoot)
    if ((Test-NativePathEqual $fullSuiteRoot $volumeRoot) -or
        (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and (Test-NativePathEqual $fullSuiteRoot $env:USERPROFILE))) {
        Fail "La racine de suite est trop large pour une désinstallation sûre : $fullSuiteRoot"
    }
    Assert-SuiteStopped
    $local = Read-LocalManifest
    $removeRpBot = $Uninstall -in @("rp-bot", "both")
    $removePuLID = $Uninstall -in @("pulid", "both")
    if ($removePuLID -and $null -ne $local.components.pulid -and [string]$local.components.pulid.installationType -ne "managed-local") {
        Fail "PuLID est déclaré $($local.components.pulid.installationType). Une installation externe ou distante n'est jamais désinstallée par RP Bot Suite."
    }
    $currentRp = if ($null -eq $local.components.rpBot) { "déjà absent" } else { [string]$local.components.rpBot.activeVersion }
    $currentPuLID = if ($null -eq $local.components.pulid) { "déjà absent" } else { [string]$local.components.pulid.detectedVersion }
    $modelsPath = if ($null -eq $local.components.pulid) { "aucun dossier géré" } else { Get-PortableModelsPath $local }
    Write-Section "Désinstallation hors ligne"
    if ($removeRpBot) { Write-Host "  RP Bot : $currentRp" }
    if ($removePuLID) { Write-Host "  PuLID  : $currentPuLID" }
    Write-Host "  Les logs et le pack de décors seront conservés."
    if ($removeRpBot -and -not $DeleteRpBotData) { Write-Host "  Les données RP Bot seront conservées." }
    if ($removePuLID -and -not $DeletePuLIDModels) { Write-Host "  Les modèles PuLID seront conservés : $modelsPath" }
    if (-not $ConfirmUninstall -and -not (Confirm-YesNo "Confirmer la désinstallation des binaires sélectionnés ?" $false)) {
        Fail "Désinstallation annulée ; aucun fichier n'a été supprimé."
    }
    if ($DeleteRpBotData -and -not $ConfirmDataDeletion -and -not (Confirm-YesNo "Confirmer séparément la suppression définitive des données RP Bot ($(Join-Path $Root 'data\rp-bot')) ?" $false)) {
        Fail "Suppression des données non confirmée ; aucun fichier n'a été supprimé."
    }
    if ($DeletePuLIDModels -and -not $ConfirmModelsDeletion -and -not (Confirm-YesNo "Confirmer séparément la suppression définitive des modèles PuLID ($modelsPath) ?" $false)) {
        Fail "Suppression des modèles non confirmée ; aucun fichier n'a été supprimé."
    }
    if ($removeRpBot) { Uninstall-RpBot ([bool]$DeleteRpBotData) }
    if ($removePuLID) { Uninstall-PuLID ([bool]$DeletePuLIDModels) }
    Write-Host "Conservé : logs — $(Join-Path $Root 'logs')"
    Write-Host "Conservé : pack de décors — $(Join-Path $Root 'assets\roleplay-backgrounds')"
    Write-Host "État local mis à jour atomiquement : $($script:LocalManifestPath)"
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
    foreach ($required in @("runtime\node.exe", "launcher.mjs", "suite-runtime\suite-launcher.mjs", "suite-runtime\suite-updater.mjs", "suite-runtime\update-request-contract.mjs", "suite-runtime\safe-extract-windows.ps1", "metadata\build.json")) { if (-not (Test-Path -LiteralPath (Join-Path $prepared $required) -PathType Leaf)) { Fail "Artefact RP Bot incomplet : $required" } }
    $buildVersion = Read-RpBotBuildVersion (Join-Path $prepared "metadata\build.json")
    if ($buildVersion -ne $version) { Fail "Version interne de l'artefact RP Bot invalide : $buildVersion, attendu $version." }
    $target = Join-Path $Root "apps\rp-bot\$version"; Start-DirectorySwap $prepared $target $staging
    Install-SuiteRuntime $target
    Activate-RpBot $version $target; Complete-DirectorySwap; Clear-InterruptedOperation
    Write-Host "RP Bot $version installé et activé sans modifier les données utilisateur."
}

function New-PuLIDWindowsCompatInstaller([string]$ReleaseRoot) {
    $sourcePath = Join-Path $ReleaseRoot "install_windows.bat"
    $compatPath = Join-Path $ReleaseRoot ".rp-bot-install-windows-compat.bat"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { Fail "Installateur Windows PuLID absent." }
    $expected = '"%PROJECT_DIR%.venv\Scripts\pulid-install.exe" --models-root "%PULID_MODELS_ROOT%" --sdxl ask'
    $replacement = '"%PROJECT_DIR%.venv\Scripts\pulid-install.exe" --models-root "%PULID_MODELS_ROOT%" --sdxl "%PULID_SDXL_MODE%" --accept-insightface-license'
    $contents = [IO.File]::ReadAllText($sourcePath)
    $first = $contents.IndexOf($expected, [StringComparison]::Ordinal)
    $last = $contents.LastIndexOf($expected, [StringComparison]::Ordinal)
    if ($first -lt 0 -or $first -ne $last) { Fail "L'adaptateur non interactif Windows ne correspond pas exactement à l'installateur PuLID attendu ; aucune exécution effectuée." }
    $updated = $contents.Substring(0, $first) + $replacement + $contents.Substring($first + $expected.Length)
    [IO.File]::WriteAllText($compatPath, $updated, (New-Object Text.UTF8Encoding($false)))
    return $compatPath
}

function Invoke-CmdWithoutInput([string]$BatchPath) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
    $startInfo.Arguments = '/d /s /c ""' + $BatchPath.Replace('"', '""') + '""'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { Fail "Impossible de lancer l'installateur PuLID." }
        $process.StandardInput.Close()
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally { $process.Dispose() }
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
    $previousSdxlMode = $env:PULID_SDXL_MODE
    $previousInstallProfile = $env:PULID_INSTALL_PROFILE
    $compatInstaller = $null
    try {
        $env:PULID_MODELS_ROOT = $ModelsRoot
        $env:PULID_SDXL_MODE = $script:SdxlMode
        $env:PULID_INSTALL_PROFILE = "production"
        $compatInstaller = New-PuLIDWindowsCompatInstaller $target
        $exitCode = Invoke-CmdWithoutInput $compatInstaller
        if ($exitCode -ne 0) { Fail "L'installateur production PuLID a échoué." }
        if (-not (Test-Path -LiteralPath (Join-Path $target ".venv\Scripts\pulid-gen.exe") -PathType Leaf)) { Fail "Le contrôle de santé PuLID n'a pas produit le runtime attendu." }
    } catch { Undo-DirectorySwap; throw }
    finally {
        if ($compatInstaller) { Remove-Item -LiteralPath $compatInstaller -Force -ErrorAction SilentlyContinue }
        $env:PULID_MODELS_ROOT = $previousModels
        $env:PULID_SDXL_MODE = $previousSdxlMode
        $env:PULID_INSTALL_PROFILE = $previousInstallProfile
    }
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
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null
    Write-LauncherManifestReader $SuiteRoot
    $launcherPath = Join-Path $SuiteRoot $script:UserLauncherName
    if (Test-Path -LiteralPath $launcherPath) {
        $existing = [IO.File]::ReadAllText($launcherPath)
        if (-not $existing.Contains("rem RP_BOT_MANAGED_LAUNCHER")) {
            Write-Warning "$launcherPath existe déjà et n'a pas été créé par RP Bot ; il est conservé."
            return
        }
    }
    $lines = @(
        '@echo off',
        'rem RP_BOT_MANAGED_LAUNCHER',
        'setlocal EnableExtensions DisableDelayedExpansion',
        'set "RP_BOT_MANIFEST=%~dp0state\installation.json"',
        'set "RP_BOT_MANIFEST_READER=%~dp0runtimes\rp-bot-suite\read-active-version.ps1"',
        'if not exist "%RP_BOT_MANIFEST%" (',
        '  echo [ERREUR] Installation RP Bot introuvable : %RP_BOT_MANIFEST%',
        '  exit /b 1',
        ')',
        'if not exist "%RP_BOT_MANIFEST_READER%" ( echo [ERREUR] Lecteur du manifeste introuvable. & exit /b 1 )',
        'for /f "usebackq delims=" %%V in (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%RP_BOT_MANIFEST_READER%" -ManifestPath "%RP_BOT_MANIFEST%" -Component rp-bot`) do set "RP_BOT_ACTIVE_VERSION=%%V"',
        'if not defined RP_BOT_ACTIVE_VERSION (',
        '  echo [ERREUR] Aucune version RP Bot active dans le manifeste local.',
        '  exit /b 1',
        ')',
        'set "RP_BOT_DATA_DIR=%~dp0data\rp-bot"',
        'if /i "%~1"=="--self-test" (',
        '  echo Version active : %RP_BOT_ACTIVE_VERSION%',
        '  echo Racine : %~dp0',
        '  echo Donnees : %RP_BOT_DATA_DIR%',
        '  echo Decors : resolution portable par le lanceur de suite',
        '  exit /b 0',
        ')',
        'if not exist "%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" (',
        '  echo [ERREUR] Installation RP Bot incomplete dans %~dp0',
        '  exit /b 1',
        ')',
        'if not exist "%~dp0runtimes\rp-bot-suite\suite-launcher.mjs" (',
        '  echo [ERREUR] Lanceur de suite externe introuvable.',
        '  exit /b 1',
        ')',
        '"%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" "%~dp0runtimes\rp-bot-suite\suite-launcher.mjs" --suite-root "%~dp0." %*',
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

function Write-UpdaterLauncher([string]$SuiteRoot, $Local) {
    if ($null -eq $Local.components.rpBot) { return }
    Assert-SemVer ([string]$Local.components.rpBot.activeVersion) "Lanceur updater.version"
    Write-LauncherManifestReader $SuiteRoot
    $launcherPath = Join-Path $SuiteRoot $script:UpdaterLauncherName
    if (Test-Path -LiteralPath $launcherPath) {
        $existing = [IO.File]::ReadAllText($launcherPath)
        if (-not $existing.Contains("rem RP_BOT_MANAGED_UPDATER_LAUNCHER")) {
            Write-Warning "$launcherPath existe déjà et n'a pas été créé par RP Bot ; il est conservé."
            return
        }
    }
    $lines = @(
        '@echo off',
        'rem RP_BOT_MANAGED_UPDATER_LAUNCHER',
        'setlocal EnableExtensions DisableDelayedExpansion',
        'set "RP_BOT_MANIFEST=%~dp0state\installation.json"',
        'set "RP_BOT_MANIFEST_READER=%~dp0runtimes\rp-bot-suite\read-active-version.ps1"',
        'set "RP_BOT_UPDATE_REQUEST=%~dp0state\update-request.json"',
        'set "RP_BOT_UPDATER=%~dp0runtimes\rp-bot-suite\suite-updater.mjs"',
        'if not exist "%RP_BOT_MANIFEST%" ( echo [ERREUR] Manifeste local introuvable. & exit /b 1 )',
        'if not exist "%RP_BOT_MANIFEST_READER%" ( echo [ERREUR] Lecteur du manifeste introuvable. & exit /b 1 )',
        'for /f "usebackq delims=" %%V in (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%RP_BOT_MANIFEST_READER%" -ManifestPath "%RP_BOT_MANIFEST%" -Component rp-bot`) do set "RP_BOT_ACTIVE_VERSION=%%V"',
        'if not defined RP_BOT_ACTIVE_VERSION ( echo [ERREUR] Aucune version RP Bot active. & exit /b 1 )',
        'if /i "%~1"=="--self-test" (',
        '  echo Version active : %RP_BOT_ACTIVE_VERSION%',
        '  echo Racine : %~dp0',
        '  echo Demande : %RP_BOT_UPDATE_REQUEST%',
        '  echo Updater : %RP_BOT_UPDATER%',
        '  exit /b 0',
        ')',
        'if not exist "%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" ( echo [ERREUR] Runtime RP Bot actif introuvable. & exit /b 1 )',
        'if not exist "%RP_BOT_UPDATER%" ( echo [ERREUR] Updater externe introuvable. & exit /b 1 )',
        'if not exist "%RP_BOT_UPDATE_REQUEST%" ( echo [ERREUR] Aucune demande de mise a jour preparee. & exit /b 1 )',
        '"%~dp0apps\rp-bot\%RP_BOT_ACTIVE_VERSION%\runtime\node.exe" "%RP_BOT_UPDATER%" --suite-root "%~dp0." --request "%RP_BOT_UPDATE_REQUEST%"',
        'exit /b %ERRORLEVEL%',
        ''
    )
    $temporary = Join-Path $SuiteRoot (".updater-launcher.{0}.tmp" -f [Guid]::NewGuid())
    $backup = Join-Path $SuiteRoot (".updater-launcher.{0}.bak" -f [Guid]::NewGuid())
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

function Write-PuLIDLaunchers([string]$SuiteRoot, $Local) {
    if ($null -eq $Local.components.pulid -or
        [string]$Local.components.pulid.installationType -ne "managed-local" -or
        $null -eq $Local.components.pulid.managedInstallation) { return }
    $version = [string]$Local.components.pulid.managedInstallation.activeVersion
    Assert-SemVer $version "Lanceur PuLID.version"
    New-Item -ItemType Directory -Path $SuiteRoot -Force | Out-Null
    Write-LauncherManifestReader $SuiteRoot
    Write-PuLIDRuntimeRepairer $SuiteRoot

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
            ('set "PULID_LAUNCH_MODE=' + $launcher.Mode + '"'),
            'set "PULID_MANIFEST=%~dp0state\installation.json"',
            'set "PULID_MANIFEST_READER=%~dp0runtimes\rp-bot-suite\read-active-version.ps1"',
            'set "PULID_RUNTIME_REPAIRER=%~dp0runtimes\rp-bot-suite\repair-pulid-runtime.ps1"',
            'if not exist "%PULID_MANIFEST%" (',
            '  echo [ERREUR] Installation PuLID introuvable : %PULID_MANIFEST%',
            '  exit /b 1',
            ')',
            'if not exist "%PULID_MANIFEST_READER%" ( echo [ERREUR] Lecteur du manifeste introuvable. & exit /b 1 )',
            'for /f "usebackq delims=" %%V in (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PULID_MANIFEST_READER%" -ManifestPath "%PULID_MANIFEST%" -Component pulid`) do set "PULID_ACTIVE_VERSION=%%V"',
            'for /f "usebackq delims=" %%M in (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PULID_MANIFEST_READER%" -ManifestPath "%PULID_MANIFEST%" -Component pulid -Field models-path -SuiteRoot "%~dp0."`) do set "PULID_MODELS_PATH=%%M"',
            'for /f "usebackq delims=" %%R in (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PULID_MANIFEST_READER%" -ManifestPath "%PULID_MANIFEST%" -Component pulid -Field previous-suite-root`) do set "PULID_PREVIOUS_SUITE_ROOT=%%R"',
            'if not defined PULID_ACTIVE_VERSION (',
            '  echo [ERREUR] Aucune version PuLID locale geree active.',
            '  exit /b 1',
            ')',
            'if not defined PULID_MODELS_PATH ( echo [ERREUR] Dossier de modeles PuLID introuvable. & exit /b 1 )',
            'if not defined PULID_PREVIOUS_SUITE_ROOT ( echo [ERREUR] Ancienne racine de suite introuvable. & exit /b 1 )',
            'if /i "%~1"=="--self-test" (',
            '  echo Version active : %PULID_ACTIVE_VERSION%',
            '  echo Racine : %~dp0',
            '  echo Modeles : %PULID_MODELS_PATH%',
            '  echo Mode : %PULID_LAUNCH_MODE%',
            '  exit /b 0',
            ')',
            'set "PULID_RELEASE=%~dp0apps\pulid\%PULID_ACTIVE_VERSION%"',
            'set "PULID_PYTHON=%PULID_RELEASE%\.venv\Scripts\python.exe"',
            'if not exist "%PULID_RUNTIME_REPAIRER%" ( echo [ERREUR] Reparateur de runtime PuLID introuvable. & exit /b 1 )',
            'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PULID_RUNTIME_REPAIRER%" -VenvPath "%PULID_RELEASE%\.venv" -PreviousSuiteRoot "%PULID_PREVIOUS_SUITE_ROOT%" -SuiteRoot "%~dp0."',
            'if errorlevel 1 ( echo [ERREUR] Impossible de recalculer la venv PuLID. & exit /b 1 )',
            'if not exist "%PULID_PYTHON%" (',
            '  echo [ERREUR] Installation PuLID incomplete dans %~dp0',
            '  exit /b 1',
            ')',
            'set "PULID_PROJECT_ROOT=%PULID_RELEASE%"',
            'set "PULID_MODELS_ROOT=%PULID_MODELS_PATH%"',
            'set "VIRTUAL_ENV=%PULID_RELEASE%\.venv"',
            'set "PULID_TORCH_DLL_DIR=%PULID_RELEASE%\.venv\Lib\site-packages\torch\lib"',
            'set "PATH=%PULID_TORCH_DLL_DIR%;%VIRTUAL_ENV%\Scripts;%PATH%"',
            $(if ($launcher.Mode -eq "local") { 'for %%A in (%*) do if /i "%%~A"=="--network" ( echo [ERREUR] Utilisez Lancer PuLID reseau.bat pour le mode reseau. & exit /b 1 )' } else { 'echo [AVERTISSEMENT] Le port 12693 doit rester limite a un reseau de confiance.' }),
            ('"%PULID_PYTHON%" -m pulid_app.server --host 127.0.0.1 --port 12693 --device cuda --dtype float16 --offload none ' + $launcher.NetworkArgument + '%*'),
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
        $compatRoot = Join-Path $selfTestBase "pulid-compat"
        New-Item -ItemType Directory -Path $compatRoot -Force | Out-Null
        $compatSource = Join-Path $compatRoot "install_windows.bat"
        $compatSourceContents = "@echo off`r`nset `"PROJECT_DIR=%~dp0`"`r`n`"%PROJECT_DIR%.venv\Scripts\pulid-install.exe`" --models-root `"%PULID_MODELS_ROOT%`" --sdxl ask`r`n"
        [IO.File]::WriteAllText($compatSource, $compatSourceContents, (New-Object Text.UTF8Encoding($false)))
        $compatInstaller = New-PuLIDWindowsCompatInstaller $compatRoot
        $compatContents = [IO.File]::ReadAllText($compatInstaller)
        if ([IO.File]::ReadAllText($compatSource) -ne $compatSourceContents -or
            -not $compatContents.Contains('--sdxl "%PULID_SDXL_MODE%" --accept-insightface-license')) {
            Fail "Self-test adaptateur non interactif PuLID Windows en échec."
        }
        $noInputFixture = Join-Path $compatRoot "no-input.bat"
        [IO.File]::WriteAllText($noInputFixture, "@echo off`r`nset answer=`r`nset /p answer=Question interdite : `r`nif defined answer exit /b 1`r`nexit /b 0`r`n", (New-Object Text.UTF8Encoding($false)))
        if ((Invoke-CmdWithoutInput $noInputFixture) -ne 0) { Fail "Self-test fermeture de l'entrée PuLID Windows en échec." }
        $previousModelsRoot = $ModelsRoot
        $previousSdxlMode = $script:SdxlMode
        $previousStagedCheckpoint = $script:StagedSdxlCheckpoint
        $previousSdxlStagingDirectory = $script:SdxlStagingDirectory
        $existingModelsRoot = Join-Path $selfTestRoot "sdxl-existing\PuLID_models"
        $existingCheckpoints = Join-Path $existingModelsRoot "checkpoints"
        New-Item -ItemType Directory -Path $existingCheckpoints -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $existingCheckpoints "existing.safetensors"), "existing")
        $script:ModelsRoot = $existingModelsRoot
        $script:SdxlMode = "skip"
        Read-SdxlChoices
        if ($script:SdxlMode -ne "ask") { Fail "Self-test détection du checkpoint SDXL existant en échec." }
        $stagedModelsRoot = Join-Path $selfTestRoot "sdxl-staged\PuLID_models"
        $stagingDirectory = Join-Path $selfTestRoot "Modele SDXL temporaire"
        New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
        $stagedCheckpoint = Join-Path $stagingDirectory "custom.safetensors"
        [IO.File]::WriteAllText($stagedCheckpoint, "custom")
        $script:ModelsRoot = $stagedModelsRoot
        $script:StagedSdxlCheckpoint = $stagedCheckpoint
        $script:SdxlStagingDirectory = $stagingDirectory
        Install-StagedSdxlCheckpoint
        if (-not (Test-Path -LiteralPath (Join-Path $stagedModelsRoot "checkpoints\custom.safetensors") -PathType Leaf) -or
            (Test-Path -LiteralPath $stagedCheckpoint) -or (Test-Path -LiteralPath $stagingDirectory)) {
            Fail "Self-test copie temporaire du checkpoint SDXL en échec."
        }
        $script:ModelsRoot = $previousModelsRoot
        $script:SdxlMode = $previousSdxlMode
        $script:StagedSdxlCheckpoint = $previousStagedCheckpoint
        $script:SdxlStagingDirectory = $previousSdxlStagingDirectory
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
                    modelsPath = (Join-Path $selfTestRoot "models\PuLID_models")
                    managedInstallation = [pscustomobject]@{ activeVersion = "0.1.0" }
                }
                roleplayBackgrounds = [pscustomobject]@{ activeContentVersion = "1.0.0"; activeFormatVersion = "1.0.0" }
            }
            paths = [pscustomobject]@{ rpBotData = (Join-Path $selfTestRoot "data\rp-bot") }
        }
        $launcherStateDirectory = Join-Path $selfTestRoot "state"
        $launcherManifestPath = Join-Path $launcherStateDirectory "installation.json"
        $script:StateDirectory = $launcherStateDirectory
        $script:LocalManifestPath = $launcherManifestPath
        Write-LocalManifestAtomic $launcherLocal
        Write-UserLauncher $selfTestRoot $launcherLocal
        Write-UpdaterLauncher $selfTestRoot $launcherLocal
        Write-PuLIDLaunchers $selfTestRoot $launcherLocal
        $fixtureVenv = Join-Path $selfTestRoot "apps\pulid\0.1.0\.venv"
        $fixturePythonHome = Join-Path $selfTestRoot "models\PuLID_models\other\uv-python-windows\cpython-3.11"
        New-Item -ItemType Directory -Path $fixtureVenv -Force | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $fixtureVenv "pyvenv.cfg"),
            ("home = $fixturePythonHome`r`nexecutable = $fixturePythonHome\python.exe`r`n"),
            (New-Object Text.UTF8Encoding($false))
        )
        $launcherPath = Join-Path $selfTestRoot $script:UserLauncherName
        $launcherContents = [IO.File]::ReadAllText($launcherPath)
        if (-not $launcherContents.Contains('set "RP_BOT_DATA_DIR=%~dp0data\rp-bot"') -or
            -not $launcherContents.Contains('runtimes\rp-bot-suite\suite-launcher.mjs') -or
            -not $launcherContents.Contains('--suite-root "%~dp0."')) {
            Fail "Self-test chemins relatifs du lanceur Windows en échec."
        }
        $launcherOutput = @(& $launcherPath --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $launcherOutput -notlike "*Version active : 0.2.0-beta.1*" -or $launcherOutput -notlike "*Donnees : $selfTestRoot\data\rp-bot*") {
            Fail ("Self-test exécution du lanceur Windows en échec.`r`n" + $launcherOutput)
        }
        $updaterLauncher = Join-Path $selfTestRoot $script:UpdaterLauncherName
        $updaterOutput = @(& $updaterLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $updaterOutput -notlike "*Version active : 0.2.0-beta.1*" -or $updaterOutput -notlike "*Demande : $selfTestRoot\state\update-request.json*") {
            Fail ("Self-test lanceur updater Windows en échec.`r`n" + $updaterOutput)
        }
        $pulidLocalLauncher = Join-Path $selfTestRoot $script:PuLIDLocalLauncherName
        $pulidNetworkLauncher = Join-Path $selfTestRoot $script:PuLIDNetworkLauncherName
        $pulidLocalContents = [IO.File]::ReadAllText($pulidLocalLauncher)
        $pulidNetworkContents = [IO.File]::ReadAllText($pulidNetworkLauncher)
        if (-not $pulidLocalContents.Contains('"%PULID_PYTHON%" -m pulid_app.server') -or
            $pulidLocalContents.Contains('--offload none --network %*') -or
            -not $pulidNetworkContents.Contains('--offload none --network %*')) {
            Fail "Self-test arguments des lanceurs PuLID en échec."
        }
        $pulidLocalOutput = @(& $pulidLocalLauncher --self-test 2>&1) -join "`n"
        $pulidLocalExitCode = $LASTEXITCODE
        $pulidNetworkOutput = @(& $pulidNetworkLauncher --self-test 2>&1) -join "`n"
        $pulidNetworkExitCode = $LASTEXITCODE
        if ($pulidLocalExitCode -ne 0 -or $pulidLocalOutput -notlike "*Version active : 0.1.0*" -or $pulidLocalOutput -notlike "*Mode : local*") {
            Fail ("Self-test lanceur PuLID local en échec.`r`n" + $pulidLocalOutput)
        }
        if ($pulidNetworkExitCode -ne 0 -or $pulidNetworkOutput -notlike "*Version active : 0.1.0*" -or $pulidNetworkOutput -notlike "*Mode : reseau*") {
            Fail ("Self-test lanceur PuLID réseau en échec.`r`n" + $pulidNetworkOutput)
        }
        Copy-Item -LiteralPath $selfTestRoot -Destination $movedRoot -Recurse
        $movedLauncher = Join-Path $movedRoot $script:UserLauncherName
        $movedOutput = @(& $movedLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $movedOutput -notlike "*Donnees : $movedRoot\data\rp-bot*") {
            Fail ("Self-test déplacement de la suite Windows en échec.`r`n" + $movedOutput)
        }
        $movedPulidNetworkLauncher = Join-Path $movedRoot $script:PuLIDNetworkLauncherName
        $movedPulidNetworkOutput = @(& $movedPulidNetworkLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $movedPulidNetworkOutput -notlike "*Racine : $movedRoot\*") {
            Fail ("Self-test déplacement du lanceur PuLID réseau en échec.`r`n" + $movedPulidNetworkOutput)
        }
        if ($movedPulidNetworkOutput -notlike "*Modeles : $movedRoot\models\PuLID_models*") {
            Fail ("Self-test rebase des modèles PuLID Windows en échec.`r`n" + $movedPulidNetworkOutput)
        }
        $movedVenv = Join-Path $movedRoot "apps\pulid\0.1.0\.venv"
        $movedRepairer = Join-Path $movedRoot "runtimes\rp-bot-suite\$($script:PuLIDRuntimeRepairerName)"
        $repairOutput = @(
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $movedRepairer `
                -VenvPath $movedVenv -PreviousSuiteRoot $selfTestRoot -SuiteRoot $movedRoot 2>&1
        ) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            Fail ("Self-test réparation de la venv PuLID Windows en échec.`r`n" + $repairOutput)
        }
        $movedVenvConfiguration = [IO.File]::ReadAllText((Join-Path $movedVenv "pyvenv.cfg"))
        if ($movedVenvConfiguration.IndexOf($movedRoot, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $movedVenvConfiguration.IndexOf($selfTestRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail "Self-test recalage de pyvenv.cfg Windows en échec."
        }
        $movedUpdaterLauncher = Join-Path $movedRoot $script:UpdaterLauncherName
        $movedUpdaterOutput = @(& $movedUpdaterLauncher --self-test 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $movedUpdaterOutput -notlike "*Racine : $movedRoot\*" -or $movedUpdaterOutput -notlike "*Demande : $movedRoot\state\update-request.json*") {
            Fail ("Self-test déplacement du lanceur updater Windows en échec.`r`n" + $movedUpdaterOutput)
        }
        $repairRoot = Join-Path $selfTestRoot "repair-swap"
        $repairTarget = Join-Path $repairRoot "target"
        $repairPrepared = Join-Path $repairRoot "prepared"
        $repairPersistent = Join-Path $repairRoot "persistent"
        New-Item -ItemType Directory -Path $repairTarget, $repairPrepared, (Join-Path $repairPersistent "data"), (Join-Path $repairPersistent "models") -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $repairTarget "value"), "old")
        [IO.File]::WriteAllText((Join-Path $repairPrepared "value"), "repaired")
        [IO.File]::WriteAllText((Join-Path $repairPersistent "data\preserved"), "data")
        [IO.File]::WriteAllText((Join-Path $repairPersistent "models\preserved"), "model")
        Start-DirectorySwap $repairPrepared $repairTarget (Join-Path $repairRoot "staging")
        Complete-DirectorySwap
        if ([IO.File]::ReadAllText((Join-Path $repairTarget "value")) -ne "repaired" -or
            -not (Test-Path -LiteralPath (Join-Path $repairPersistent "data\preserved")) -or
            -not (Test-Path -LiteralPath (Join-Path $repairPersistent "models\preserved"))) {
            Fail "Self-test réparation avec conservation des données et modèles en échec."
        }
        $previousRoot = $script:Root
        $previousSuiteRuntimeDirectory = $script:SuiteRuntimeDirectory
        $uninstallRoot = Join-Path $selfTestBase "RP Bot Suite uninstall"
        try {
            $script:Root = $uninstallRoot
            $script:StateDirectory = Join-Path $uninstallRoot "state"
            $script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
            $script:SuiteRuntimeDirectory = Join-Path $uninstallRoot "runtimes\rp-bot-suite"
            $uninstallModels = Join-Path $uninstallRoot "models\PuLID_models"
            $uninstallData = Join-Path $uninstallRoot "data\rp-bot"
            $uninstallLogs = Join-Path $uninstallRoot "logs\rp-bot"
            $uninstallBackgrounds = Join-Path $uninstallRoot "assets\roleplay-backgrounds\1.0.0-format-1.0.0"
            foreach ($directory in @(
                (Join-Path $uninstallRoot "apps\rp-bot\0.2.0-beta.1"),
                (Join-Path $uninstallRoot "apps\pulid\0.1.0"),
                $uninstallModels, $uninstallData, $uninstallLogs, $uninstallBackgrounds,
                $script:StateDirectory, $script:SuiteRuntimeDirectory
            )) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            [IO.File]::WriteAllText((Join-Path $uninstallModels "preserved"), "model")
            [IO.File]::WriteAllText((Join-Path $uninstallData "preserved"), "data")
            [IO.File]::WriteAllText((Join-Path $uninstallLogs "preserved"), "log")
            [IO.File]::WriteAllText((Join-Path $uninstallBackgrounds "preserved"), "background")
            $uninstallManifest = [pscustomobject]@{
                schemaVersion = 1; suiteId = "rp-bot-suite"; updateChannel = "beta"
                components = [pscustomobject]@{
                    rpBot = [pscustomobject]@{
                        id = "rp-bot"; installedVersion = "0.2.0-beta.1"; activeVersion = "0.2.0-beta.1"
                        releases = @([pscustomobject]@{ version = "0.2.0-beta.1"; releasePath = (Join-Path $uninstallRoot "apps\rp-bot\0.2.0-beta.1"); installedAt = "2026-08-31T00:00:00.000Z" })
                    }
                    pulid = [pscustomobject]@{
                        id = "pulid"; installationType = "managed-local"; detectedVersion = "0.1.0"; endpoint = "http://127.0.0.1:12693"; modelsPath = $uninstallModels
                        managedInstallation = [pscustomobject]@{
                            id = "pulid"; installedVersion = "0.1.0"; activeVersion = "0.1.0"
                            releases = @([pscustomobject]@{ version = "0.1.0"; releasePath = (Join-Path $uninstallRoot "apps\pulid\0.1.0"); installedAt = "2026-08-31T00:00:00.000Z" })
                        }
                    }
                    roleplayBackgrounds = [pscustomobject]@{
                        id = "roleplay-backgrounds"; installedContentVersion = "1.0.0"; installedFormatVersion = "1.0.0"; activeContentVersion = "1.0.0"; activeFormatVersion = "1.0.0"; activePath = $uninstallBackgrounds
                        releases = @([pscustomobject]@{ contentVersion = "1.0.0"; formatVersion = "1.0.0"; releasePath = $uninstallBackgrounds; installedAt = "2026-08-31T00:00:00.000Z" })
                    }
                }
                paths = [pscustomobject]@{ rpBotData = $uninstallData }
                lastHealthCheck = $null; interruptedOperation = $null
            }
            Write-LocalManifestAtomic $uninstallManifest
            [IO.File]::WriteAllText((Join-Path $uninstallRoot $script:UserLauncherName), "@echo off`r`nrem RP_BOT_MANAGED_LAUNCHER`r`n")
            [IO.File]::WriteAllText((Join-Path $uninstallRoot $script:UpdaterLauncherName), "@echo off`r`nrem RP_BOT_MANAGED_UPDATER_LAUNCHER`r`n")
            [IO.File]::WriteAllText((Join-Path $uninstallRoot $script:PuLIDLocalLauncherName), "@echo off`r`nrem RP_BOT_MANAGED_PULID_LAUNCHER`r`n")
            [IO.File]::WriteAllText((Join-Path $uninstallRoot $script:PuLIDNetworkLauncherName), "@echo off`r`nrem RP_BOT_MANAGED_PULID_LAUNCHER`r`n")
            Uninstall-RpBot $false
            $afterRpUninstall = Read-LocalManifest
            if ($null -ne $afterRpUninstall.components.rpBot -or
                (Test-Path -LiteralPath (Join-Path $uninstallRoot "apps\rp-bot")) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallData "preserved")) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallLogs "preserved"))) {
                Fail "Self-test désinstallation RP Bot avec conservation des données en échec."
            }
            Uninstall-PuLID $false
            $afterPuLIDUninstall = Read-LocalManifest
            if ($null -ne $afterPuLIDUninstall.components.pulid -or
                (Test-Path -LiteralPath (Join-Path $uninstallRoot "apps\pulid")) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallModels "preserved")) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallBackgrounds "preserved"))) {
                Fail "Self-test désinstallation PuLID avec conservation des modèles et décors en échec."
            }
            Activate-RpBot "0.2.0-beta.1" (Join-Path $uninstallRoot "apps\rp-bot\0.2.0-beta.1")
            Activate-PuLID "0.1.0" (Join-Path $uninstallRoot "apps\pulid\0.1.0") $uninstallModels
            New-Item -ItemType Directory -Path (Join-Path $uninstallRoot "apps\rp-bot\0.2.0-beta.1") -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $uninstallRoot "apps\pulid\0.1.0") -Force | Out-Null
            Uninstall-RpBot $true
            Uninstall-PuLID $true
            if ((Test-Path -LiteralPath $uninstallData) -or (Test-Path -LiteralPath $uninstallModels) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallLogs "preserved")) -or
                -not (Test-Path -LiteralPath (Join-Path $uninstallBackgrounds "preserved"))) {
                Fail "Self-test suppressions persistantes explicitement confirmées en échec."
            }
            $unownedLauncher = Join-Path $uninstallRoot $script:UserLauncherName
            [IO.File]::WriteAllText($unownedLauncher, "@echo off`r`nrem lanceur utilisateur`r`n")
            Remove-ManagedFile $unownedLauncher "rem RP_BOT_MANAGED_LAUNCHER" "lanceur RP Bot"
            if (-not (Test-Path -LiteralPath $unownedLauncher -PathType Leaf)) { Fail "Self-test conservation d'un lanceur non géré en échec." }
        }
        finally {
            $script:Root = $previousRoot
            $script:SuiteRuntimeDirectory = $previousSuiteRuntimeDirectory
            $script:StateDirectory = Join-Path $selfTestRoot "state"
            $script:LocalManifestPath = Join-Path $script:StateDirectory "installation.json"
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
    if ($Select -and $Uninstall) { Fail "-Select et -Uninstall sont mutuellement exclusifs." }
    if ($DeleteRpBotData -and $Uninstall -notin @("rp-bot", "both")) { Fail "-DeleteRpBotData exige -Uninstall rp-bot ou both." }
    if ($DeletePuLIDModels -and $Uninstall -notin @("pulid", "both")) { Fail "-DeletePuLIDModels exige -Uninstall pulid ou both." }
    if (($ConfirmUninstall -or $ConfirmDataDeletion -or $ConfirmModelsDeletion) -and -not $Uninstall) {
        Fail "Les confirmations de désinstallation exigent -Uninstall."
    }
    if ($Uninstall) {
        Write-Host "Dossier de suite : $Root"
        Invoke-Uninstall
        return
    }
    $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("rp-bot-installer." + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    Initialize-PermanentDirectories
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
        if (-not $ModelsRoot -and $null -ne $local.components.pulid) { $script:ModelsRoot = Get-PortableModelsPath $local }
        if (-not $ModelsRoot) {
            $defaultModels = Join-Path $Root "models\PuLID_models"
            if (Confirm-YesNo "Utiliser $defaultModels pour les modèles PuLID ?" $true) { $script:ModelsRoot = $defaultModels }
            else { $script:ModelsRoot = Read-Host "Chemin absolu du dossier PuLID_models (SSD externe accepté)" }
        }
        if (-not [IO.Path]::IsPathRooted($ModelsRoot)) { Fail "Le dossier de modèles doit être absolu." }
        Write-Host ""; Write-Host "Licence InsightFace/AntelopeV2 : poids réservés à la recherche non commerciale."
        Write-Host "https://github.com/deepinsight/insightface/blob/master/server/LICENSING.md"
        if (-not (Confirm-YesNo "Acceptez-vous explicitement ces conditions avant tout téléchargement de modèle ?" $false)) { Fail "Licence InsightFace refusée ; PuLID n'a pas été installé." }
        Read-SdxlChoices
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
    Write-Section "Configuration terminée — l'installation se poursuit sans autre question"
    Write-Section "Préflight matériel, disque, ports et réseau"; Run-Preflight $manifest $installRp $installPulid $installBackgrounds
    if ($installRp) { Install-RpBot $manifest $currentRp }
    if ($installBackgrounds) { Install-Backgrounds $manifest }
    if ($installPulid) {
        Install-StagedSdxlCheckpoint
        Install-PuLID $manifest $currentPulid
    }
    $installedLocal = Read-LocalManifest
    if ($null -ne $installedLocal.components.rpBot) {
        Write-UserLauncher $Root $installedLocal
        Write-UpdaterLauncher $Root $installedLocal
    }
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
