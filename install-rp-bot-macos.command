#!/bin/zsh

emulate -L zsh
set -eu
setopt pipefail
umask 077

# RP_BOT_INSTALLER_SECURITY:HTTPS_ONLY
# RP_BOT_INSTALLER_SECURITY:SIZE_AND_SHA256
# RP_BOT_INSTALLER_SECURITY:SAFE_EXTRACTION
# RP_BOT_INSTALLER_SECURITY:ATOMIC_LOCAL_MANIFEST
# RP_BOT_INSTALLER_SECURITY:NO_IMPLICIT_UNINSTALL

readonly PUBLIC_REPOSITORY="oHminod/rp-bot-downloads"
readonly PUBLIC_RAW_BASE="https://raw.githubusercontent.com/${PUBLIC_REPOSITORY}/main"
readonly DEFAULT_SUITE_ROOT="${HOME}/Library/Application Support/RP Bot Suite"
readonly PULID_ENDPOINT="http://127.0.0.1:12693"
readonly RP_BOT_PORT=8800
readonly PULID_PORT=12693

CHANNEL="beta"
SUITE_ROOT="${DEFAULT_SUITE_ROOT}"
MODELS_ROOT=""
SELECTION=""
BACKGROUNDS_CHOICE="ask"
ACCEPT_UNSIGNED=0
SELF_TEST=0
TEMPORARY_ROOT=""
LOCAL_MANIFEST=""
STATE_DIRECTORY=""
DOWNLOAD_DIRECTORY=""
MANIFEST_PATH=""

die() {
  print -u2 -- "[ERREUR] $*"
  exit 1
}

notice() {
  print -- "\n==> $*"
}

cleanup() {
  if [[ -n "${SWAP_TARGET:-}" ]]; then
    rollback_swap || true
  fi
  if [[ -n "${TEMPORARY_ROOT}" && -d "${TEMPORARY_ROOT}" ]]; then
    /bin/rm -rf -- "${TEMPORARY_ROOT}"
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Usage : install-rp-bot-macos.command [options]

  --channel stable|beta        Canal de mise à jour (beta par défaut pour le MVP)
  --select rp-bot|pulid|both   Composants à installer ou réparer
  --root CHEMIN                Racine de RP Bot Suite
  --models-root CHEMIN         Dossier permanent PuLID_models
  --backgrounds yes|no|ask     Pack de décors recommandé avec RP Bot
  --accept-unsigned-mvp        Confirme une prerelease MVP non signée
  --self-test                  Contrôles locaux sans réseau ni installation
  --help                       Affiche cette aide

Une sélection absente ne désinstalle jamais un composant existant.
EOF
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --channel)
        (( $# >= 2 )) || die "Valeur manquante pour --channel."
        CHANNEL="$2"
        shift 2
        ;;
      --select)
        (( $# >= 2 )) || die "Valeur manquante pour --select."
        SELECTION="$2"
        shift 2
        ;;
      --root)
        (( $# >= 2 )) || die "Valeur manquante pour --root."
        SUITE_ROOT="$2"
        shift 2
        ;;
      --models-root)
        (( $# >= 2 )) || die "Valeur manquante pour --models-root."
        MODELS_ROOT="$2"
        shift 2
        ;;
      --backgrounds)
        (( $# >= 2 )) || die "Valeur manquante pour --backgrounds."
        BACKGROUNDS_CHOICE="$2"
        shift 2
        ;;
      --accept-unsigned-mvp)
        ACCEPT_UNSIGNED=1
        shift
        ;;
      --self-test)
        SELF_TEST=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *) die "Option inconnue : $1" ;;
    esac
  done

  [[ "${CHANNEL}" == "stable" || "${CHANNEL}" == "beta" ]] ||
    die "--channel doit valoir stable ou beta."
  [[ -z "${SELECTION}" || "${SELECTION}" == "rp-bot" || "${SELECTION}" == "pulid" || "${SELECTION}" == "both" ]] ||
    die "--select doit valoir rp-bot, pulid ou both."
  [[ "${BACKGROUNDS_CHOICE}" == "yes" || "${BACKGROUNDS_CHOICE}" == "no" || "${BACKGROUNDS_CHOICE}" == "ask" ]] ||
    die "--backgrounds doit valoir yes, no ou ask."
  [[ "${SUITE_ROOT}" == /* ]] || die "--root doit être un chemin absolu."
  if [[ -n "${MODELS_ROOT}" ]]; then
    [[ "${MODELS_ROOT}" == /* ]] || die "--models-root doit être un chemin absolu."
  fi
}

json_helper() {
  /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import("Foundation");

function fail(message) { throw new Error(message); }
function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(label + " doit être un objet.");
  return value;
}
function exact(value, keys, label) {
  object(value, label);
  const actual = Object.keys(value).sort().join("\u0000");
  const expected = keys.slice().sort().join("\u0000");
  if (actual !== expected) fail(label + " contient des propriétés inconnues ou manquantes.");
}
function text(value, label) {
  if (typeof value !== "string" || value.trim() === "") fail(label + " doit être un texte non vide.");
  return value;
}
function integer(value, label, positive) {
  if (!Number.isSafeInteger(value) || value < (positive ? 1 : 0)) fail(label + " doit être un entier valide.");
}
function semver(value, label) {
  text(value, label);
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(value)) fail(label + " doit être une version SemVer.");
}
function sha(value, label) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) fail(label + " doit être une empreinte SHA-256 minuscule.");
}
function https(value, label) {
  text(value, label);
  if (!value.startsWith("https://")) fail(label + " doit utiliser HTTPS.");
}
function fileName(value, label) {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/.test(value)) fail(label + " doit être un nom de fichier sûr.");
}
function readJson(filePath, label) {
  const contents = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(filePath), $.NSUTF8StringEncoding, null));
  if (contents === undefined) fail("Lecture impossible : " + filePath);
  try { return JSON.parse(contents); } catch (error) { fail(label + " n'est pas un JSON valide : " + error.message); }
}
function signature(value, label) {
  object(value, label);
  if (value.status === "unsigned-mvp") {
    exact(value, ["status", "reason"], label);
    text(value.reason, label + ".reason");
  } else if (value.status === "signed") {
    exact(value, ["status", "algorithm", "url", "keyId"], label);
    if (value.algorithm !== "minisign-ed25519") fail(label + ".algorithm non pris en charge.");
    https(value.url, label + ".url");
    text(value.keyId, label + ".keyId");
  } else fail(label + ".status non pris en charge.");
  return value;
}
function artifact(value, label) {
  exact(value, ["component", "platform", "architecture", "fileName", "url", "sizeBytes", "sha256", "signature"], label);
  if (!["rp-bot", "pulid", "roleplay-backgrounds"].includes(value.component)) fail(label + ".component invalide.");
  if (!["macos", "windows", "any"].includes(value.platform)) fail(label + ".platform invalide.");
  if (!["arm64", "x64", "any"].includes(value.architecture)) fail(label + ".architecture invalide.");
  fileName(value.fileName, label + ".fileName");
  https(value.url, label + ".url");
  integer(value.sizeBytes, label + ".sizeBytes", true);
  sha(value.sha256, label + ".sha256");
  signature(value.signature, label + ".signature");
  if (!value.url.endsWith("/" + value.fileName)) fail(label + ".url ne se termine pas par le nom déclaré.");
  if (value.signature.status === "signed" && !value.signature.url.endsWith("/" + value.fileName + ".sig")) fail(label + ".signature.url est incohérente.");
}
function requirement(value, label) {
  exact(value, ["selection", "variant", "platform", "architecture", "minimumOsVersion", "requiredMemoryBytes", "requiredFreeDiskBytes", "cpuRequirement", "gpuRequirement"], label);
  if (!["rp-bot", "pulid", "pulid-models", "roleplay-backgrounds"].includes(value.selection)) fail(label + ".selection invalide.");
  text(value.variant, label + ".variant");
  if (!["macos", "windows"].includes(value.platform)) fail(label + ".platform invalide.");
  if (!["arm64", "x64"].includes(value.architecture)) fail(label + ".architecture invalide.");
  if (value.minimumOsVersion !== null) text(value.minimumOsVersion, label + ".minimumOsVersion");
  integer(value.requiredMemoryBytes, label + ".requiredMemoryBytes", false);
  integer(value.requiredFreeDiskBytes, label + ".requiredFreeDiskBytes", false);
  if (value.cpuRequirement !== null) text(value.cpuRequirement, label + ".cpuRequirement");
  object(value.gpuRequirement, label + ".gpuRequirement");
  if (value.gpuRequirement.required === false) exact(value.gpuRequirement, ["required"], label + ".gpuRequirement");
  else {
    exact(value.gpuRequirement, ["required", "vendor", "acceleration", "minimumVramBytes", "minimumDriverVersion", "cudaMajorVersion"], label + ".gpuRequirement");
    if (value.gpuRequirement.required !== true) fail(label + ".gpuRequirement.required invalide.");
    if (!["apple", "nvidia"].includes(value.gpuRequirement.vendor)) fail(label + ".gpuRequirement.vendor invalide.");
    if (!["mps", "cuda"].includes(value.gpuRequirement.acceleration)) fail(label + ".gpuRequirement.acceleration invalide.");
    if (value.gpuRequirement.minimumVramBytes !== null) integer(value.gpuRequirement.minimumVramBytes, label + ".gpuRequirement.minimumVramBytes", true);
    if (value.gpuRequirement.minimumDriverVersion !== null) text(value.gpuRequirement.minimumDriverVersion, label + ".gpuRequirement.minimumDriverVersion");
    if (value.gpuRequirement.cudaMajorVersion !== null) integer(value.gpuRequirement.cudaMajorVersion, label + ".gpuRequirement.cudaMajorVersion", true);
  }
}
function validatePointer(value, requestedChannel) {
  exact(value, ["schemaVersion", "channel", "updatedAt", "suiteVersion", "manifest", "channelSignature"], "Pointeur");
  if (value.schemaVersion !== 1) fail("Pointeur.schemaVersion non pris en charge.");
  if (value.channel !== requestedChannel) fail("Le pointeur ne correspond pas au canal demandé.");
  semver(value.suiteVersion, "Pointeur.suiteVersion");
  if (requestedChannel === "stable" && !/^\d+\.\d+\.\d+$/.test(value.suiteVersion)) fail("Version stable invalide.");
  if (requestedChannel === "beta" && !/^\d+\.\d+\.\d+-beta\.(0|[1-9]\d*)$/.test(value.suiteVersion)) fail("Version bêta invalide.");
  exact(value.manifest, ["fileName", "url", "sizeBytes", "sha256", "signature"], "Pointeur.manifest");
  fileName(value.manifest.fileName, "Pointeur.manifest.fileName");
  https(value.manifest.url, "Pointeur.manifest.url");
  integer(value.manifest.sizeBytes, "Pointeur.manifest.sizeBytes", true);
  sha(value.manifest.sha256, "Pointeur.manifest.sha256");
  signature(value.manifest.signature, "Pointeur.manifest.signature");
  signature(value.channelSignature, "Pointeur.channelSignature");
  const expected = "rp-bot-suite-manifest-" + value.suiteVersion + ".json";
  if (value.manifest.fileName !== expected || !value.manifest.url.endsWith("/" + expected)) fail("Le nom public du manifeste est incohérent.");
  if (requestedChannel === "stable" && (value.manifest.signature.status !== "signed" || value.channelSignature.status !== "signed")) fail("Le canal stable doit être signé.");
  return value;
}
function validateManifest(value, requestedChannel) {
  exact(value, ["schemaVersion", "releaseChannel", "suiteVersion", "publishedAt", "releaseNotesUrl", "rpBot", "pulid", "roleplayBackgrounds", "artifacts", "installationRequirements", "blockingIncompatibilities", "manifestSignature"], "Manifeste");
  if (value.schemaVersion !== 1) fail("Manifeste.schemaVersion non pris en charge.");
  if (value.releaseChannel !== requestedChannel) fail("Le manifeste ne correspond pas au canal demandé.");
  semver(value.suiteVersion, "Manifeste.suiteVersion");
  if (requestedChannel === "stable" && !/^\d+\.\d+\.\d+$/.test(value.suiteVersion)) fail("Version stable invalide.");
  if (requestedChannel === "beta" && !/^\d+\.\d+\.\d+-beta\.(0|[1-9]\d*)$/.test(value.suiteVersion)) fail("Version bêta invalide.");
  https(value.releaseNotesUrl, "Manifeste.releaseNotesUrl");
  exact(value.rpBot, ["version", "nodeRuntimeVersion", "sqliteSchemaVersion"], "Manifeste.rpBot");
  semver(value.rpBot.version, "Manifeste.rpBot.version");
  semver(value.rpBot.nodeRuntimeVersion, "Manifeste.rpBot.nodeRuntimeVersion");
  integer(value.rpBot.sqliteSchemaVersion, "Manifeste.rpBot.sqliteSchemaVersion", false);
  if (value.rpBot.version !== value.suiteVersion) fail("La version RP Bot doit être celle de la suite.");
  exact(value.pulid, ["compatibleVersion", "apiContractVersion"], "Manifeste.pulid");
  semver(value.pulid.compatibleVersion, "Manifeste.pulid.compatibleVersion");
  semver(value.pulid.apiContractVersion, "Manifeste.pulid.apiContractVersion");
  exact(value.roleplayBackgrounds, ["contentVersion", "formatVersion", "minimumRpBotVersion", "maximumRpBotVersionExclusive"], "Manifeste.roleplayBackgrounds");
  semver(value.roleplayBackgrounds.contentVersion, "Manifeste.roleplayBackgrounds.contentVersion");
  semver(value.roleplayBackgrounds.formatVersion, "Manifeste.roleplayBackgrounds.formatVersion");
  semver(value.roleplayBackgrounds.minimumRpBotVersion, "Manifeste.roleplayBackgrounds.minimumRpBotVersion");
  if (value.roleplayBackgrounds.maximumRpBotVersionExclusive !== null) semver(value.roleplayBackgrounds.maximumRpBotVersionExclusive, "Manifeste.roleplayBackgrounds.maximumRpBotVersionExclusive");
  if (!Array.isArray(value.artifacts) || value.artifacts.length !== 4) fail("L'inventaire doit contenir exactement les quatre artefacts MVP.");
  value.artifacts.forEach((item, index) => artifact(item, "Manifeste.artifacts[" + index + "]"));
  const expectedArtifacts = [
    ["rp-bot", "macos", "arm64", "rp-bot-macos-arm64-" + value.suiteVersion + ".tar.gz"],
    ["rp-bot", "windows", "x64", "rp-bot-windows-x64-" + value.suiteVersion + ".zip"],
    ["pulid", "any", "any", "pulid-" + value.pulid.compatibleVersion + ".tar.gz"],
    ["roleplay-backgrounds", "any", "any", "rp-bot-roleplay-backgrounds-" + value.roleplayBackgrounds.contentVersion + "-format-" + value.roleplayBackgrounds.formatVersion + ".zip"]
  ];
  expectedArtifacts.forEach((expected) => {
    const found = value.artifacts.filter((item) => item.component === expected[0] && item.platform === expected[1] && item.architecture === expected[2]);
    if (found.length !== 1 || found[0].fileName !== expected[3]) fail("Artefact obligatoire absent ou mal nommé : " + expected.slice(0, 3).join(":"));
  });
  if (!Array.isArray(value.installationRequirements) || value.installationRequirements.length !== 8) fail("Les huit lignes de prérequis MVP sont obligatoires.");
  value.installationRequirements.forEach((item, index) => requirement(item, "Manifeste.installationRequirements[" + index + "]"));
  ["rp-bot", "pulid", "pulid-models", "roleplay-backgrounds"].forEach((selection) => {
    [["macos", "arm64"], ["windows", "x64"]].forEach((target) => {
      const found = value.installationRequirements.filter((item) => item.selection === selection && item.platform === target[0] && item.architecture === target[1]);
      if (found.length !== 1) fail("Prérequis absent ou ambigu pour " + selection + "/" + target.join("-"));
    });
  });
  if (!Array.isArray(value.blockingIncompatibilities)) fail("Incompatibilités invalides.");
  value.blockingIncompatibilities.forEach((item, index) => {
    exact(item, ["code", "message", "affectedComponents", "affectedTargets"], "Manifeste.blockingIncompatibilities[" + index + "]");
    text(item.code, "code"); text(item.message, "message");
    if (!Array.isArray(item.affectedComponents) || !Array.isArray(item.affectedTargets)) fail("Incompatibilité incomplète.");
    item.affectedTargets.forEach((target) => exact(target, ["platform", "architecture"], "affectedTarget"));
  });
  signature(value.manifestSignature, "Manifeste.manifestSignature");
  if (requestedChannel === "stable" && (value.manifestSignature.status !== "signed" || value.artifacts.some((item) => item.signature.status !== "signed"))) fail("Une release stable doit être entièrement signée.");
  return value;
}
function chooseArtifact(manifest, component, platform, architecture) {
  const found = manifest.artifacts.filter((item) => item.component === component && ((item.platform === platform && item.architecture === architecture) || (item.platform === "any" && item.architecture === "any")));
  if (found.length !== 1) fail("Artefact absent ou ambigu pour " + component + ".");
  return found[0];
}
function chooseRequirement(manifest, selection, platform, architecture) {
  const found = manifest.installationRequirements.filter((item) => item.selection === selection && item.platform === platform && item.architecture === architecture);
  if (found.length !== 1) fail("Prérequis absent ou ambigu pour " + selection + ".");
  return found[0];
}
function artifactSummary(value) {
  return { fileName: value.fileName, url: value.url, sizeBytes: value.sizeBytes, sha256: value.sha256, signature: value.signature };
}
function requirementSummary(value) {
  return { requiredMemoryBytes: value.requiredMemoryBytes, requiredFreeDiskBytes: value.requiredFreeDiskBytes, minimumOsVersion: value.minimumOsVersion, cpuRequirement: value.cpuRequirement, gpuRequirement: value.gpuRequirement };
}
function validateLocal(value) {
  exact(value, ["schemaVersion", "suiteId", "updateChannel", "components", "paths", "lastHealthCheck", "interruptedOperation"], "Manifeste local");
  if (value.schemaVersion !== 1 || value.suiteId !== "rp-bot-suite") fail("Manifeste local non pris en charge.");
  if (!["stable", "beta"].includes(value.updateChannel)) fail("Canal local invalide.");
  exact(value.components, ["rpBot", "pulid", "roleplayBackgrounds"], "Manifeste local.components");
  exact(value.paths, ["rpBotData"], "Manifeste local.paths");
  text(value.paths.rpBotData, "Manifeste local.paths.rpBotData");
  if (value.components.rpBot !== null) {
    const component = value.components.rpBot;
    exact(component, ["id", "installedVersion", "activeVersion", "releases"], "Manifeste local.components.rpBot");
    if (component.id !== "rp-bot" || component.installedVersion !== component.activeVersion || !Array.isArray(component.releases)) fail("État RP Bot local incohérent.");
    component.releases.forEach((item) => exact(item, ["version", "releasePath", "installedAt"], "Release RP Bot locale"));
    if (component.releases.filter((item) => item.version === component.activeVersion).length !== 1) fail("La release RP Bot active est absente du manifeste local.");
  }
  if (value.components.pulid !== null) {
    const pulid = value.components.pulid;
    exact(pulid, ["id", "installationType", "detectedVersion", "endpoint", "modelsPath", "managedInstallation"], "Manifeste local.components.pulid");
    if (pulid.id !== "pulid" || !["managed-local", "external-local", "remote"].includes(pulid.installationType)) fail("État PuLID local incohérent.");
    if (pulid.installationType === "managed-local") {
      if (!pulid.modelsPath || pulid.managedInstallation === null) fail("Installation PuLID gérée incomplète.");
      exact(pulid.managedInstallation, ["id", "installedVersion", "activeVersion", "releases"], "Installation PuLID gérée");
      pulid.managedInstallation.releases.forEach((item) => exact(item, ["version", "releasePath", "installedAt"], "Release PuLID locale"));
    } else if (pulid.managedInstallation !== null) fail("Une installation PuLID externe ou distante ne doit pas contenir de releases gérées.");
  }
  if (value.components.roleplayBackgrounds !== null) {
    const backgrounds = value.components.roleplayBackgrounds;
    exact(backgrounds, ["id", "installedContentVersion", "installedFormatVersion", "activeContentVersion", "activeFormatVersion", "activePath", "releases"], "Manifeste local.components.roleplayBackgrounds");
    backgrounds.releases.forEach((item) => exact(item, ["contentVersion", "formatVersion", "releasePath", "installedAt"], "Release de décors locale"));
    if (backgrounds.releases.filter((item) => item.contentVersion === backgrounds.activeContentVersion && item.formatVersion === backgrounds.activeFormatVersion && item.releasePath === backgrounds.activePath).length !== 1) fail("Le pack de décors actif est absent du manifeste local.");
  }
  if (value.interruptedOperation !== null) exact(value.interruptedOperation, ["id", "kind", "component", "stage", "startedAt", "updatedAt", "fromVersion", "toVersion", "checkpoint", "recoveryActions"], "Manifeste local.interruptedOperation");
  return value;
}
function emptyLocal(root, channel) {
  return { schemaVersion: 1, suiteId: "rp-bot-suite", updateChannel: channel, components: { rpBot: null, pulid: null, roleplayBackgrounds: null }, paths: { rpBotData: root + "/data/rp-bot" }, lastHealthCheck: null, interruptedOperation: null };
}
function readLocal(filePath, root, channel) {
  if (!$.NSFileManager.defaultManager.fileExistsAtPath($(filePath))) return emptyLocal(root, channel);
  return validateLocal(readJson(filePath, "Manifeste local"));
}
function release(version, releasePath, installedAt) { return { version: version, releasePath: releasePath, installedAt: installedAt }; }
function upsertRelease(releases, next, keys) {
  const kept = releases.filter((item) => keys.some((key) => item[key] !== next[key]));
  kept.push(next); return kept;
}
function main(argv) {
  const action = argv[0];
  if (action === "pointer-summary") {
    const pointer = validatePointer(readJson(argv[1], "Pointeur"), argv[2]);
    return JSON.stringify({ suiteVersion: pointer.suiteVersion, manifest: pointer.manifest, channelSignature: pointer.channelSignature });
  }
  if (action === "manifest-summary") {
    const manifest = validateManifest(readJson(argv[1], "Manifeste"), argv[2]);
    const platform = argv[3], architecture = argv[4];
    return JSON.stringify({
      suiteVersion: manifest.suiteVersion,
      rpBotVersion: manifest.rpBot.version,
      pulidVersion: manifest.pulid.compatibleVersion,
      backgrounds: manifest.roleplayBackgrounds,
      manifestSignature: manifest.manifestSignature,
      artifacts: {
        rpBot: artifactSummary(chooseArtifact(manifest, "rp-bot", platform, architecture)),
        pulid: artifactSummary(chooseArtifact(manifest, "pulid", platform, architecture)),
        roleplayBackgrounds: artifactSummary(chooseArtifact(manifest, "roleplay-backgrounds", platform, architecture))
      },
      requirements: {
        rpBot: requirementSummary(chooseRequirement(manifest, "rp-bot", platform, architecture)),
        pulid: requirementSummary(chooseRequirement(manifest, "pulid", platform, architecture)),
        pulidModels: requirementSummary(chooseRequirement(manifest, "pulid-models", platform, architecture)),
        roleplayBackgrounds: requirementSummary(chooseRequirement(manifest, "roleplay-backgrounds", platform, architecture))
      }
    });
  }
  if (action === "unsigned-lines") {
    const pointer = validatePointer(readJson(argv[1], "Pointeur"), argv[3]);
    const manifest = validateManifest(readJson(argv[2], "Manifeste"), argv[3]);
    const lines = [];
    if (pointer.channelSignature.status === "unsigned-mvp") lines.push("Pointeur : " + pointer.channelSignature.reason);
    if (manifest.manifestSignature.status === "unsigned-mvp") lines.push("Manifeste : " + manifest.manifestSignature.reason);
    manifest.artifacts.forEach((item) => { if (item.signature.status === "unsigned-mvp") lines.push(item.component + " : " + item.signature.reason); });
    return lines.join("\n");
  }
  if (action === "blocking-lines") {
    const manifest = validateManifest(readJson(argv[1], "Manifeste"), argv[2]);
    const platform = argv[3], architecture = argv[4], selected = argv[5].split(",");
    return manifest.blockingIncompatibilities.filter((item) =>
      item.affectedTargets.some((target) => target.platform === platform && target.architecture === architecture) &&
      item.affectedComponents.some((component) => selected.includes(component))
    ).map((item) => item.code + "\t" + item.message).join("\n");
  }
  if (action === "local-summary") {
    const local = readLocal(argv[1], argv[2], argv[3]);
    return JSON.stringify({
      rpBotVersion: local.components.rpBot ? local.components.rpBot.activeVersion : "",
      pulidVersion: local.components.pulid ? local.components.pulid.detectedVersion : "",
      pulidInstallationType: local.components.pulid ? local.components.pulid.installationType : "",
      backgroundsContentVersion: local.components.roleplayBackgrounds ? local.components.roleplayBackgrounds.activeContentVersion : "",
      backgroundsFormatVersion: local.components.roleplayBackgrounds ? local.components.roleplayBackgrounds.activeFormatVersion : "",
      modelsPath: local.components.pulid ? (local.components.pulid.modelsPath || "") : "",
      interruptedCheckpoint: local.interruptedOperation ? local.interruptedOperation.checkpoint : ""
    });
  }
  if (action === "local-update") {
    const filePath = argv[1], root = argv[2], channel = argv[3], update = argv[4];
    const local = readLocal(filePath, root, channel); local.updateChannel = channel;
    const now = argv[5];
    if (update === "operation") {
      const previous = local.interruptedOperation;
      local.interruptedOperation = { id: previous && previous.component === argv[7] ? previous.id : argv[6], kind: argv[6 + 2], component: argv[7], stage: argv[9], startedAt: previous && previous.component === argv[7] ? previous.startedAt : now, updatedAt: now, fromVersion: argv[10] === "-" ? null : argv[10], toVersion: argv[11] === "-" ? null : argv[11], checkpoint: argv[12], recoveryActions: argv[13].split(",") };
    } else if (update === "clear-operation") local.interruptedOperation = null;
    else if (update === "activate-rp") {
      const version = argv[6], releasePath = argv[7], old = local.components.rpBot;
      const releases = upsertRelease(old ? old.releases : [], release(version, releasePath, now), ["version"]);
      local.components.rpBot = { id: "rp-bot", installedVersion: version, activeVersion: version, releases: releases };
    } else if (update === "activate-pulid") {
      const version = argv[6], releasePath = argv[7], modelsPath = argv[8], old = local.components.pulid && local.components.pulid.managedInstallation;
      const releases = upsertRelease(old ? old.releases : [], release(version, releasePath, now), ["version"]);
      local.components.pulid = { id: "pulid", installationType: "managed-local", detectedVersion: version, endpoint: "http://127.0.0.1:12693", modelsPath: modelsPath, managedInstallation: { id: "pulid", installedVersion: version, activeVersion: version, releases: releases } };
    } else if (update === "activate-backgrounds") {
      const content = argv[6], format = argv[7], releasePath = argv[8], old = local.components.roleplayBackgrounds;
      const next = { contentVersion: content, formatVersion: format, releasePath: releasePath, installedAt: now };
      const releases = upsertRelease(old ? old.releases : [], next, ["contentVersion", "formatVersion"]);
      local.components.roleplayBackgrounds = { id: "roleplay-backgrounds", installedContentVersion: content, installedFormatVersion: format, activeContentVersion: content, activeFormatVersion: format, activePath: releasePath, releases: releases };
    } else fail("Mise à jour locale inconnue.");
    return JSON.stringify(local, null, 2);
  }
  if (action === "build-version") {
    const metadata = readJson(argv[1], "Métadonnées RP Bot");
    exact(metadata, ["schemaVersion", "application", "version", "buildId", "builtAt", "target", "nodeRuntimeVersion", "signed"], "Métadonnées RP Bot");
    if (metadata.schemaVersion !== 1 || metadata.application !== "rp-bot") fail("Artefact RP Bot non reconnu.");
    semver(metadata.version, "Métadonnées RP Bot.version");
    return metadata.version;
  }
  if (action === "background-inventory") {
    const manifest = readJson(argv[1], "Inventaire des décors");
    exact(manifest, ["schemaVersion", "packId", "contentVersion", "formatVersion", "rpBotCompatibility", "fileCount", "totalSizeBytes", "sourceTreeSha256", "files"], "Inventaire des décors");
    if (manifest.schemaVersion !== 1 || manifest.packId !== "roleplay-backgrounds") fail("Inventaire des décors non pris en charge.");
    semver(manifest.contentVersion, "Inventaire.contentVersion"); semver(manifest.formatVersion, "Inventaire.formatVersion");
    exact(manifest.rpBotCompatibility, ["minimumVersion", "maximumVersionExclusive"], "Inventaire.rpBotCompatibility");
    semver(manifest.rpBotCompatibility.minimumVersion, "Inventaire.rpBotCompatibility.minimumVersion");
    if (manifest.rpBotCompatibility.maximumVersionExclusive !== null) semver(manifest.rpBotCompatibility.maximumVersionExclusive, "Inventaire.rpBotCompatibility.maximumVersionExclusive");
    integer(manifest.fileCount, "Inventaire.fileCount", true); integer(manifest.totalSizeBytes, "Inventaire.totalSizeBytes", true); sha(manifest.sourceTreeSha256, "Inventaire.sourceTreeSha256");
    if (!Array.isArray(manifest.files) || manifest.files.length !== manifest.fileCount) fail("Nombre de fichiers de décors incohérent.");
    let total = 0;
    const lines = manifest.files.map((item, index) => {
      exact(item, ["fileName", "sizeBytes", "sha256"], "Inventaire.files[" + index + "]");
      fileName(item.fileName, "Inventaire.files[" + index + "].fileName"); integer(item.sizeBytes, "sizeBytes", true); sha(item.sha256, "sha256"); total += item.sizeBytes;
      return item.fileName + "\t" + item.sizeBytes + "\t" + item.sha256;
    });
    if (total !== manifest.totalSizeBytes) fail("Taille totale des décors incohérente.");
    return lines.join("\n");
  }
  fail("Action JSON inconnue : " + action);
}
function run(argv) { return main(argv); }
JXA
}

json_get() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || return 1
}

file_size() {
  /usr/bin/stat -f %z "$1"
}

file_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

is_safe_archive_entry() {
  local entry="$1"
  [[ -n "${entry}" && "${entry}" != /* && "${entry}" != *\\* && ! "${entry}" =~ '(^|/)\.\.(/|$)' && ! "${entry}" =~ '^[A-Za-z]:' ]]
}

assert_allowed_url() {
  local component="$1"
  local url="$2"
  [[ "${url}" == https://* ]] || die "URL non HTTPS refusée pour ${component}."
  case "${component}" in
    pointer) [[ "${url}" == "${PUBLIC_RAW_BASE}/latest-"*".json" ]] ;;
    manifest|rp-bot|roleplay-backgrounds)
      [[ "${url}" == https://github.com/oHminod/rp-bot-downloads/releases/download/* ]]
      ;;
    pulid) [[ "${url}" == https://github.com/oHminod/PuLID/releases/download/* ]] ;;
    signature) [[ "${url}" == https://github.com/* || "${url}" == https://raw.githubusercontent.com/* ]] ;;
    *) return 1 ;;
  esac || die "Hôte ou chemin de téléchargement non autorisé pour ${component}: ${url}"
}

download_small() {
  local component="$1" url="$2" destination="$3"
  assert_allowed_url "${component}" "${url}"
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 3 --connect-timeout 15 --max-time 120 --output "${destination}" "${url}" ||
    die "Téléchargement impossible : ${url}"
  [[ -s "${destination}" ]] || die "Le téléchargement est vide : ${url}"
}

verify_download() {
  local file_path="$1" expected_size="$2" expected_sha="$3"
  local actual_size actual_sha
  actual_size="$(file_size "${file_path}")"
  [[ "${actual_size}" == "${expected_size}" ]] || return 1
  actual_sha="$(file_sha256 "${file_path}")"
  [[ "${actual_sha}" == "${expected_sha}" ]]
}

verify_signature() {
  local file_path="$1" status="$2" signature_url="$3"
  [[ "${status}" == "signed" ]] || return 0
  local minisign_bin="${RP_BOT_MINISIGN_BIN:-}"
  local public_key="${RP_BOT_MINISIGN_PUBLIC_KEY:-}"
  if [[ -z "${minisign_bin}" || ! -x "${minisign_bin}" || -z "${public_key}" ]]; then
    die "Cette release signée exige l'installateur stable signé. Le script MVP ne possède pas le vérificateur Minisign épinglé."
  fi
  local signature_path="${file_path}.sig"
  download_small signature "${signature_url}" "${signature_path}"
  "${minisign_bin}" -V -H -P "${public_key}" -m "${file_path}" -x "${signature_path}" >/dev/null ||
    die "Signature invalide pour $(/usr/bin/basename "${file_path}")."
}

download_verified() {
  local component="$1" file_name="$2" url="$3" expected_size="$4" expected_sha="$5" signature_status="$6" signature_url="$7"
  local final_path="${DOWNLOAD_DIRECTORY}/${file_name}"
  local partial_path="${final_path}.part"
  assert_allowed_url "${component}" "${url}"
  if [[ -f "${final_path}" ]] && verify_download "${final_path}" "${expected_size}" "${expected_sha}"; then
    print -- "Téléchargement vérifié déjà présent : ${file_name}"
    verify_signature "${final_path}" "${signature_status}" "${signature_url}"
    REPLY="${final_path}"
    return
  fi
  [[ ! -f "${final_path}" ]] || /bin/mv -f -- "${final_path}" "${partial_path}"
  notice "Téléchargement de ${file_name}"
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
    --connect-timeout 20 --continue-at - --output "${partial_path}" "${url}" ||
    die "Téléchargement interrompu. Le fichier partiel est conservé : ${partial_path}"
  verify_download "${partial_path}" "${expected_size}" "${expected_sha}" ||
    die "Taille ou SHA-256 invalide. Le fichier partiel est conservé pour diagnostic : ${partial_path}"
  /bin/mv -f -- "${partial_path}" "${final_path}"
  verify_signature "${final_path}" "${signature_status}" "${signature_url}"
  REPLY="${final_path}"
}

assert_archive_safe() {
  local archive="$1"
  local kind="$2"
  local entry
  if [[ "${archive}" == *.zip ]]; then
    while IFS= read -r entry; do
      is_safe_archive_entry "${entry}" || die "Entrée ZIP dangereuse refusée : ${entry}"
    done < <(/usr/bin/zipinfo -1 "${archive}")
    /usr/bin/zipinfo -l "${archive}" | /usr/bin/awk 'NR > 3 && $1 ~ /^l/ { bad=1 } END { exit bad }' ||
      die "Les liens symboliques sont interdits dans l'archive ${kind}."
  elif [[ "${archive}" == *.tar.gz ]]; then
    while IFS= read -r entry; do
      is_safe_archive_entry "${entry}" || die "Entrée TAR dangereuse refusée : ${entry}"
    done < <(/usr/bin/tar -tzf "${archive}")
    /usr/bin/tar -tvzf "${archive}" | /usr/bin/awk '$1 ~ /^[lh]/ { bad=1 } END { exit bad }' ||
      die "Les liens physiques ou symboliques sont interdits dans l'archive ${kind}."
  else
    die "Format d'archive non pris en charge : ${archive}"
  fi
}

extract_archive() {
  local archive="$1" staging="$2" kind="$3"
  assert_archive_safe "${archive}" "${kind}"
  /bin/mkdir -p "${staging}"
  if [[ "${archive}" == *.zip ]]; then
    /usr/bin/ditto -x -k -- "${archive}" "${staging}"
  else
    /usr/bin/tar -xzf "${archive}" -C "${staging}"
  fi
}

single_archive_root() {
  local staging="$1"
  local -a entries
  entries=("${staging}"/*(N) "${staging}"/.*(N))
  entries=(${entries:#${staging}/.})
  entries=(${entries:#${staging}/..})
  (( ${#entries[@]} == 1 )) || die "L'archive doit contenir exactement un dossier racine."
  [[ -d "${entries[1]}" ]] || die "La racine de l'archive n'est pas un dossier."
  REPLY="${entries[1]}"
}

safe_remove_tree() {
  local target="$1" allowed_parent="$2"
  [[ -n "${target}" && "${target}" == "${allowed_parent}"/* && "${target}" != "${allowed_parent}" ]] ||
    die "Suppression de sécurité refusée : ${target}"
  /bin/rm -rf -- "${target}"
}

swap_in_directory() {
  local prepared="$1" target="$2" staging="$3"
  local parent backup=""
  parent="${target:h}"
  /bin/mkdir -p "${parent}"
  if [[ -e "${target}" ]]; then
    backup="${target}.backup.$(/usr/bin/uuidgen)"
    /bin/mv -- "${target}" "${backup}"
  fi
  if ! /bin/mv -- "${prepared}" "${target}"; then
    [[ -z "${backup}" ]] || /bin/mv -- "${backup}" "${target}"
    die "Activation du dossier impossible : ${target}"
  fi
  SWAP_TARGET="${target}"
  SWAP_BACKUP="${backup}"
  SWAP_STAGING="${staging}"
}

commit_swap() {
  if [[ -n "${SWAP_BACKUP:-}" && -e "${SWAP_BACKUP}" ]]; then
    safe_remove_tree "${SWAP_BACKUP}" "${SWAP_TARGET:h}"
  fi
  if [[ -n "${SWAP_STAGING:-}" && -e "${SWAP_STAGING}" ]]; then
    safe_remove_tree "${SWAP_STAGING}" "${SWAP_STAGING:h}"
  fi
  SWAP_TARGET="" SWAP_BACKUP="" SWAP_STAGING=""
}

rollback_swap() {
  if [[ -n "${SWAP_TARGET:-}" && -e "${SWAP_TARGET}" ]]; then
    safe_remove_tree "${SWAP_TARGET}" "${SWAP_TARGET:h}"
  fi
  if [[ -n "${SWAP_BACKUP:-}" && -e "${SWAP_BACKUP}" ]]; then
    /bin/mv -- "${SWAP_BACKUP}" "${SWAP_TARGET}"
  fi
  if [[ -n "${SWAP_STAGING:-}" && -e "${SWAP_STAGING}" ]]; then
    safe_remove_tree "${SWAP_STAGING}" "${SWAP_STAGING:h}"
  fi
  SWAP_TARGET="" SWAP_BACKUP="" SWAP_STAGING=""
}

atomic_local_update() {
  local timestamp temporary
  timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
  temporary="${STATE_DIRECTORY}/.installation.json.$$.${RANDOM}.tmp"
  json_helper local-update "${LOCAL_MANIFEST}" "${SUITE_ROOT}" "${CHANNEL}" "$1" "${timestamp}" "${@:2}" > "${temporary}" || {
    /bin/rm -f -- "${temporary}"
    die "Le manifeste local existant est invalide ; aucune écriture n'a été effectuée."
  }
  /usr/bin/plutil -lint "${temporary}" >/dev/null || die "Écriture JSON locale invalide."
  /bin/chmod 600 "${temporary}"
  /bin/mv -f -- "${temporary}" "${LOCAL_MANIFEST}"
  /bin/sync
}

set_operation() {
  local kind="$1" component="$2" stage="$3" from_version="$4" to_version="$5" checkpoint="$6"
  atomic_local_update operation "$(/usr/bin/uuidgen)" "${component}" "${kind}" "${stage}" "${from_version:-}" "${to_version:-}" "${checkpoint}" "resume,cancel"
}

require_writable_directory() {
  local directory="$1" probe
  /bin/mkdir -p "${directory}" || die "Impossible de créer ${directory}."
  probe="${directory}/.rp-bot-write-test.$$"
  : > "${probe}" || die "Droits d'écriture insuffisants : ${directory}"
  /bin/rm -f -- "${probe}"
}

available_bytes() {
  local directory="$1"
  /bin/mkdir -p "${directory}"
  /bin/df -Pk "${directory}" | /usr/bin/awk 'NR==2 { printf "%.0f\n", $4 * 1024 }'
}

require_disk_space() {
  local directory="$1" required="$2" label="$3" available
  available="$(available_bytes "${directory}")"
  (( available >= required )) || die "Espace insuffisant pour ${label}: ${required} octets requis, ${available} disponibles sur ${directory}."
}

require_port_available() {
  local port="$1" label="$2"
  if /usr/sbin/lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    die "Le port ${port} requis par ${label} est déjà occupé. Arrêtez le processus concerné puis relancez l'installateur."
  fi
}

require_connectivity() {
  local label="$1" url="$2"
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --range 0-0 --connect-timeout 10 --max-time 30 --output /dev/null "${url}" ||
    die "Connexion impossible vers ${label} (${url}). Vérifiez le réseau, le proxy ou le pare-feu."
}

prompt_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "${default}" == "yes" ]]; then
      read -r "answer?${prompt} [O/n] "
      answer="${answer:-o}"
    else
      read -r "answer?${prompt} [o/N] "
      answer="${answer:-n}"
    fi
    case "${answer:l}" in
      o|oui|y|yes) return 0 ;;
      n|non|no) return 1 ;;
      *) print -- "Répondez oui ou non." ;;
    esac
  done
}

display_status() {
  local local_summary="$1" latest_rp="$2" latest_pulid="$3"
  local current_rp current_pulid current_pulid_type interrupted_checkpoint
  current_rp="$(json_get "${local_summary}" rpBotVersion || true)"
  current_pulid="$(json_get "${local_summary}" pulidVersion || true)"
  current_pulid_type="$(json_get "${local_summary}" pulidInstallationType || true)"
  interrupted_checkpoint="$(json_get "${local_summary}" interruptedCheckpoint || true)"
  print -- "\nÉtat détecté"
  if [[ -n "${current_rp}" ]]; then
    [[ "${current_rp}" == "${latest_rp}" ]] &&
      print -- "  RP Bot   installé — ${current_rp}   [Réparer]" ||
      print -- "  RP Bot   installé — ${current_rp}   [Mettre à jour vers ${latest_rp}]"
  else
    print -- "  RP Bot   non installé             [Installer]"
  fi
  if [[ -n "${current_pulid}" ]]; then
    if [[ "${current_pulid_type}" != "managed-local" ]]; then
      print -- "  PuLID    installé — ${current_pulid} (${current_pulid_type})   [Information uniquement]"
    elif [[ "${current_pulid}" == "${latest_pulid}" ]]; then
      print -- "  PuLID    installé — ${current_pulid}   [Réparer]"
    else
      print -- "  PuLID    installé — ${current_pulid}   [Mettre à jour vers ${latest_pulid}]"
    fi
  else
    print -- "  PuLID    non installé             [Installer]"
  fi
  print -- "  Une ligne non sélectionnée sera conservée sans modification."
  if [[ -n "${interrupted_checkpoint}" ]]; then
    print -- "  AVERTISSEMENT : opération interrompue — ${interrupted_checkpoint}"
    print -- "  Le relancement revalidera le téléchargement avant de reprendre."
  fi
}

choose_selection() {
  [[ -n "${SELECTION}" ]] && return
  local answer
  print -- "\nQue souhaitez-vous installer ou réparer ?"
  print -- "  1. RP Bot"
  print -- "  2. PuLID"
  print -- "  3. RP Bot et PuLID"
  while true; do
    read -r "answer?Choix [1-3] : "
    case "${answer}" in
      1) SELECTION="rp-bot"; return ;;
      2) SELECTION="pulid"; return ;;
      3) SELECTION="both"; return ;;
      *) print -- "Choisissez 1, 2 ou 3." ;;
    esac
  done
}

artifact_value() {
  json_get "$1" "artifacts.$2.$3"
}

requirement_value() {
  json_get "$1" "requirements.$2.$3"
}

prepare_preflight() {
  local summary="$1" install_rp="$2" install_pulid="$3" install_backgrounds="$4"
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || die "Le MVP macOS exige un Mac Apple Silicon arm64."
  local os_major="${$(/usr/bin/sw_vers -productVersion)%%.*}"
  (( os_major >= 14 )) || die "macOS 14 ou plus récent est requis."
  require_writable_directory "${SUITE_ROOT}"
  require_writable_directory "${STATE_DIRECTORY}"
  require_writable_directory "${DOWNLOAD_DIRECTORY}"

  local app_disk=0 models_disk=0 memory_required=0 value
  if (( install_rp )); then
    value="$(requirement_value "${summary}" rpBot requiredFreeDiskBytes)"; (( app_disk += value ))
    value="$(requirement_value "${summary}" rpBot requiredMemoryBytes)"; (( memory_required = value > memory_required ? value : memory_required ))
    require_port_available "${RP_BOT_PORT}" "RP Bot"
  fi
  if (( install_pulid )); then
    value="$(requirement_value "${summary}" pulid requiredFreeDiskBytes)"; (( app_disk += value ))
    value="$(requirement_value "${summary}" pulidModels requiredFreeDiskBytes)"; (( models_disk += value ))
    value="$(requirement_value "${summary}" pulid requiredMemoryBytes)"; (( memory_required = value > memory_required ? value : memory_required ))
    require_port_available "${PULID_PORT}" "PuLID"
  fi
  if (( install_backgrounds )); then
    value="$(requirement_value "${summary}" roleplayBackgrounds requiredFreeDiskBytes)"; (( app_disk += value ))
  fi
  require_disk_space "${SUITE_ROOT}" "${app_disk}" "les applications et décors sélectionnés"
  if (( install_pulid )); then
    require_writable_directory "${MODELS_ROOT}"
    require_disk_space "${MODELS_ROOT}" "${models_disk}" "les modèles PuLID"
  fi
  local physical_memory
  physical_memory="$(/usr/sbin/sysctl -n hw.memsize)"
  (( physical_memory >= memory_required )) || die "Mémoire insuffisante : ${memory_required} octets requis, ${physical_memory} détectés."

  require_connectivity GitHub "https://github.com/"
  if (( install_pulid )); then
    require_connectivity "Hugging Face" "https://huggingface.co/"
    require_connectivity PyTorch "https://download.pytorch.org/"
    require_connectivity Astral/uv "https://astral.sh/uv/"
    require_connectivity "llama-cpp-python" "https://abetlen.github.io/llama-cpp-python/"
    require_connectivity PyPI "https://pypi.org/simple/"
  fi
  local -a selected_components
  (( install_rp )) && selected_components+=(rp-bot)
  (( install_pulid )) && selected_components+=(pulid pulid-models)
  (( install_backgrounds )) && selected_components+=(roleplay-backgrounds)
  local blocker_code blocker_message
  while IFS=$'\t' read -r blocker_code blocker_message; do
    [[ -z "${blocker_code}" ]] || die "Incompatibilité bloquante ${blocker_code} : ${blocker_message}"
  done < <(json_helper blocking-lines "${MANIFEST_PATH}" "${CHANNEL}" macos arm64 "${(j:,:)selected_components}")
}

install_rp_bot() {
  local summary="$1" current_version="$2"
  local version file_name url size sha sig_status sig_url archive staging prepared target actual operation_kind
  version="$(json_get "${summary}" rpBotVersion)"
  operation_kind="$([[ -z "${current_version}" ]] && print install || { [[ "${current_version}" == "${version}" ]] && print repair || print update; })"
  file_name="$(artifact_value "${summary}" rpBot fileName)"
  url="$(artifact_value "${summary}" rpBot url)"
  size="$(artifact_value "${summary}" rpBot sizeBytes)"
  sha="$(artifact_value "${summary}" rpBot sha256)"
  sig_status="$(artifact_value "${summary}" rpBot signature.status)"
  sig_url="$(artifact_value "${summary}" rpBot signature.url 2>/dev/null || true)"
  set_operation "${operation_kind}" rp-bot downloading "${current_version:--}" "${version}" "Téléchargement RP Bot en cours."
  download_verified rp-bot "${file_name}" "${url}" "${size}" "${sha}" "${sig_status}" "${sig_url}"
  archive="${REPLY}"
  set_operation "${operation_kind}" rp-bot installing "${current_version:--}" "${version}" "Artefact RP Bot vérifié ; extraction en cours."
  staging="${SUITE_ROOT}/apps/rp-bot/.staging.$(/usr/bin/uuidgen)"
  extract_archive "${archive}" "${staging}" rp-bot
  single_archive_root "${staging}"; prepared="${REPLY}"
  [[ -x "${prepared}/runtime/node" && -f "${prepared}/launcher.mjs" && -f "${prepared}/metadata/build.json" ]] || die "Artefact RP Bot incomplet."
  actual="$(json_helper build-version "${prepared}/metadata/build.json")"
  [[ "${actual}" == "${version}" ]] || die "L'artefact RP Bot contient la version ${actual}, ${version} attendue."
  target="${SUITE_ROOT}/apps/rp-bot/${version}"
  swap_in_directory "${prepared}" "${target}" "${staging}"
  atomic_local_update activate-rp "${version}" "${target}"
  commit_swap
  atomic_local_update clear-operation
  print -- "RP Bot ${version} installé et activé sans modifier ${SUITE_ROOT}/data/rp-bot."
}

install_pulid() {
  local summary="$1" current_version="$2"
  local version file_name url size sha sig_status sig_url archive staging prepared target operation_kind
  version="$(json_get "${summary}" pulidVersion)"
  operation_kind="$([[ -z "${current_version}" ]] && print install || { [[ "${current_version}" == "${version}" ]] && print repair || print update; })"
  file_name="$(artifact_value "${summary}" pulid fileName)"
  url="$(artifact_value "${summary}" pulid url)"
  size="$(artifact_value "${summary}" pulid sizeBytes)"
  sha="$(artifact_value "${summary}" pulid sha256)"
  sig_status="$(artifact_value "${summary}" pulid signature.status)"
  sig_url="$(artifact_value "${summary}" pulid signature.url 2>/dev/null || true)"
  set_operation "${operation_kind}" pulid downloading "${current_version:--}" "${version}" "Téléchargement PuLID en cours."
  download_verified pulid "${file_name}" "${url}" "${size}" "${sha}" "${sig_status}" "${sig_url}"
  archive="${REPLY}"
  set_operation "${operation_kind}" pulid installing "${current_version:--}" "${version}" "Archive PuLID vérifiée ; installation du runtime privé en cours."
  staging="${SUITE_ROOT}/apps/pulid/.staging.$(/usr/bin/uuidgen)"
  extract_archive "${archive}" "${staging}" pulid
  single_archive_root "${staging}"; prepared="${REPLY}"
  [[ -f "${prepared}/pyproject.toml" && -f "${prepared}/install_production_macos.sh" && -f "${prepared}/install_macos.sh" ]] || die "Archive PuLID incomplète : installateur production absent."
  /bin/chmod +x "${prepared}/install_production_macos.sh" "${prepared}/install_macos.sh"
  target="${SUITE_ROOT}/apps/pulid/${version}"
  swap_in_directory "${prepared}" "${target}" "${staging}"
  if ! PULID_MODELS_ROOT="${MODELS_ROOT}" "${target}/install_production_macos.sh"; then
    rollback_swap
    die "L'installation PuLID a échoué. Les modèles déjà valides ont été conservés dans ${MODELS_ROOT}."
  fi
  [[ -x "${target}/.venv/bin/pulid-gen" ]] || {
    rollback_swap
    die "Le contrôle de santé PuLID n'a pas produit le runtime attendu."
  }
  atomic_local_update activate-pulid "${version}" "${target}" "${MODELS_ROOT}"
  commit_swap
  atomic_local_update clear-operation
  print -- "PuLID ${version} installé avec Python privé ; modèles conservés dans ${MODELS_ROOT}."
}

verify_background_tree() {
  local directory="$1" expected_content="$2" expected_format="$3" inventory file_name expected_size expected_sha file_path expected_count actual_count
  inventory="${directory}/roleplay-backgrounds.manifest.json"
  [[ -f "${inventory}" ]] || die "Inventaire des décors absent."
  [[ "$(json_get "${inventory}" contentVersion)" == "${expected_content}" && "$(json_get "${inventory}" formatVersion)" == "${expected_format}" ]] || die "Versions de l'inventaire des décors incohérentes."
  while IFS=$'\t' read -r file_name expected_size expected_sha; do
    [[ -n "${file_name}" ]] || continue
    file_path="${directory}/${file_name}"
    [[ -f "${file_path}" ]] || die "Fichier de décor absent : ${file_name}"
    verify_download "${file_path}" "${expected_size}" "${expected_sha}" || die "Fichier de décor invalide : ${file_name}"
  done < <(json_helper background-inventory "${inventory}")
  expected_count="$(json_get "${inventory}" fileCount)"
  actual_count="$(/usr/bin/find "${directory}" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  (( actual_count == expected_count + 1 )) || die "L'archive de décors contient des fichiers non déclarés."
  [[ -z "$(/usr/bin/find "${directory}" -mindepth 1 -type d -print -quit)" ]] || die "Les sous-dossiers sont interdits dans le pack de décors v1."
}

install_backgrounds() {
  local summary="$1"
  local content format file_name url size sha sig_status sig_url archive staging target
  content="$(json_get "${summary}" backgrounds.contentVersion)"
  format="$(json_get "${summary}" backgrounds.formatVersion)"
  file_name="$(artifact_value "${summary}" roleplayBackgrounds fileName)"
  url="$(artifact_value "${summary}" roleplayBackgrounds url)"
  size="$(artifact_value "${summary}" roleplayBackgrounds sizeBytes)"
  sha="$(artifact_value "${summary}" roleplayBackgrounds sha256)"
  sig_status="$(artifact_value "${summary}" roleplayBackgrounds signature.status)"
  sig_url="$(artifact_value "${summary}" roleplayBackgrounds signature.url 2>/dev/null || true)"
  set_operation install roleplay-backgrounds downloading - "${content}" "Téléchargement du pack de décors en cours."
  download_verified roleplay-backgrounds "${file_name}" "${url}" "${size}" "${sha}" "${sig_status}" "${sig_url}"
  archive="${REPLY}"
  staging="${SUITE_ROOT}/assets/roleplay-backgrounds/.staging.$(/usr/bin/uuidgen)"
  extract_archive "${archive}" "${staging}" roleplay-backgrounds
  verify_background_tree "${staging}" "${content}" "${format}"
  target="${SUITE_ROOT}/assets/roleplay-backgrounds/${content}-format-${format}"
  swap_in_directory "${staging}" "${target}" "${staging}"
  atomic_local_update activate-backgrounds "${content}" "${format}" "${target}"
  commit_swap
  atomic_local_update clear-operation
  print -- "Pack de décors ${content} (format ${format}) vérifié et activé."
}

run_self_test() {
  is_safe_archive_entry "folder/file.txt" || die "Self-test archive sûr en échec."
  ! is_safe_archive_entry "../escape" || die "Self-test traversée en échec."
  ! is_safe_archive_entry "/absolute" || die "Self-test chemin absolu en échec."
  ! is_safe_archive_entry 'C:\\escape' || die "Self-test chemin Windows en échec."
  local pointer manifest pointer_summary manifest_summary
  pointer="${0:A:h:h}/../docs/distribution/examples/latest-beta-v1.example.json"
  manifest="${0:A:h:h}/../docs/distribution/examples/rp-bot-suite-manifest-v1.example.json"
  if [[ -f "${pointer}" && -f "${manifest}" ]]; then
    pointer_summary="$(json_helper pointer-summary "${pointer}" beta)"
    manifest_summary="$(json_helper manifest-summary "${manifest}" beta macos arm64)"
    [[ "$(print -r -- "${pointer_summary}" | /usr/bin/plutil -extract suiteVersion raw -o - -)" == "0.2.0-beta.1" ]] || die "Self-test pointeur en échec."
    [[ "$(print -r -- "${manifest_summary}" | /usr/bin/plutil -extract rpBotVersion raw -o - -)" == "0.2.0-beta.1" ]] || die "Self-test manifeste en échec."
  fi
  local state_root local_path local_temporary now
  state_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rp-bot-installer-state-test.XXXXXX")"
  local_path="${state_root}/installation.json"
  local_temporary="${state_root}/installation.tmp.json"
  now="2026-09-15T12:00:00.000Z"
  json_helper local-update "${local_path}" "${state_root}" beta activate-rp "${now}" 0.2.0-beta.1 "${state_root}/apps/rp-bot/0.2.0-beta.1" > "${local_temporary}"
  /bin/mv -- "${local_temporary}" "${local_path}"
  [[ "$(json_helper local-summary "${local_path}" "${state_root}" beta | /usr/bin/plutil -extract rpBotVersion raw -o - -)" == "0.2.0-beta.1" ]] || die "Self-test manifeste local en échec."
  local archive_source archive_path archive_staging archive_root
  archive_source="${state_root}/archive-source"
  /bin/mkdir -p "${archive_source}/sample-root"
  print -n -- "verified" > "${archive_source}/sample-root/file.txt"
  archive_path="${state_root}/sample.tar.gz"
  /usr/bin/tar -czf "${archive_path}" -C "${archive_source}" sample-root
  archive_staging="${state_root}/archive-staging"
  extract_archive "${archive_path}" "${archive_staging}" self-test
  single_archive_root "${archive_staging}"; archive_root="${REPLY}"
  [[ "$(<"${archive_root}/file.txt")" == "verified" ]] || die "Self-test extraction sûre en échec."
  local swap_parent swap_target swap_prepared
  swap_parent="${state_root}/swap"
  swap_target="${swap_parent}/target"
  swap_prepared="${swap_parent}/prepared"
  /bin/mkdir -p "${swap_target}" "${swap_prepared}"
  print -n -- old > "${swap_target}/value"
  print -n -- new > "${swap_prepared}/value"
  swap_in_directory "${swap_prepared}" "${swap_target}" "${swap_parent}/unused-staging"
  rollback_swap
  [[ "$(<"${swap_target}/value")" == "old" ]] || die "Self-test rollback côte à côte en échec."
  /bin/rm -rf -- "${state_root}"
  print -- "Self-test installateur macOS : OK"
}

main() {
  parse_arguments "$@"
  if (( SELF_TEST )); then
    run_self_test
    return
  fi
  TEMPORARY_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rp-bot-installer.XXXXXX")"
  STATE_DIRECTORY="${SUITE_ROOT}/state"
  DOWNLOAD_DIRECTORY="${STATE_DIRECTORY}/downloads"
  LOCAL_MANIFEST="${STATE_DIRECTORY}/installation.json"
  /bin/mkdir -p "${STATE_DIRECTORY}" "${DOWNLOAD_DIRECTORY}"
  /bin/chmod 700 "${STATE_DIRECTORY}" "${DOWNLOAD_DIRECTORY}" 2>/dev/null || true

  notice "Lecture du canal ${CHANNEL}"
  local pointer_path="${TEMPORARY_ROOT}/latest-${CHANNEL}.json"
  local pointer_url="${PUBLIC_RAW_BASE}/latest-${CHANNEL}.json"
  download_small pointer "${pointer_url}" "${pointer_path}"
  local pointer_summary="${TEMPORARY_ROOT}/pointer-summary.json"
  json_helper pointer-summary "${pointer_path}" "${CHANNEL}" > "${pointer_summary}" || die "Pointeur de canal invalide."
  local pointer_signature_status pointer_signature_url
  pointer_signature_status="$(json_get "${pointer_summary}" channelSignature.status)"
  pointer_signature_url="$(json_get "${pointer_summary}" channelSignature.url 2>/dev/null || true)"
  verify_signature "${pointer_path}" "${pointer_signature_status}" "${pointer_signature_url}"
  local manifest_file manifest_url manifest_size manifest_sha manifest_sig_status manifest_sig_url
  manifest_file="$(json_get "${pointer_summary}" manifest.fileName)"
  manifest_url="$(json_get "${pointer_summary}" manifest.url)"
  manifest_size="$(json_get "${pointer_summary}" manifest.sizeBytes)"
  manifest_sha="$(json_get "${pointer_summary}" manifest.sha256)"
  manifest_sig_status="$(json_get "${pointer_summary}" manifest.signature.status)"
  manifest_sig_url="$(json_get "${pointer_summary}" manifest.signature.url 2>/dev/null || true)"
  download_verified manifest "${manifest_file}" "${manifest_url}" "${manifest_size}" "${manifest_sha}" "${manifest_sig_status}" "${manifest_sig_url}"
  local manifest_path="${REPLY}"
  MANIFEST_PATH="${manifest_path}"
  local suite_summary="${TEMPORARY_ROOT}/suite-summary.json"
  json_helper manifest-summary "${manifest_path}" "${CHANNEL}" macos arm64 > "${suite_summary}" || die "Manifeste de suite invalide."

  local local_summary="${TEMPORARY_ROOT}/local-summary.json"
  json_helper local-summary "${LOCAL_MANIFEST}" "${SUITE_ROOT}" "${CHANNEL}" > "${local_summary}" || die "Manifeste local invalide ; il n'a pas été remplacé."
  local latest_rp latest_pulid current_rp current_pulid current_bg_content current_bg_format
  latest_rp="$(json_get "${suite_summary}" rpBotVersion)"
  latest_pulid="$(json_get "${suite_summary}" pulidVersion)"
  current_rp="$(json_get "${local_summary}" rpBotVersion || true)"
  current_pulid="$(json_get "${local_summary}" pulidVersion || true)"
  local current_pulid_type
  current_pulid_type="$(json_get "${local_summary}" pulidInstallationType || true)"
  current_bg_content="$(json_get "${local_summary}" backgroundsContentVersion || true)"
  current_bg_format="$(json_get "${local_summary}" backgroundsFormatVersion || true)"
  display_status "${local_summary}" "${latest_rp}" "${latest_pulid}"
  choose_selection

  local install_rp=0 install_pulid=0 install_backgrounds=0
  [[ "${SELECTION}" == "rp-bot" || "${SELECTION}" == "both" ]] && install_rp=1
  [[ "${SELECTION}" == "pulid" || "${SELECTION}" == "both" ]] && install_pulid=1
  if (( install_pulid )) && [[ -n "${current_pulid_type}" && "${current_pulid_type}" != "managed-local" ]]; then
    die "PuLID est déclaré ${current_pulid_type}. L'installateur ne modifie jamais une installation externe ou distante."
  fi
  if (( install_rp )); then
    local desired_bg_content desired_bg_format
    desired_bg_content="$(json_get "${suite_summary}" backgrounds.contentVersion)"
    desired_bg_format="$(json_get "${suite_summary}" backgrounds.formatVersion)"
    if [[ "${current_bg_content}" == "${desired_bg_content}" && "${current_bg_format}" == "${desired_bg_format}" ]]; then
      print -- "Le pack de décors compatible ${desired_bg_content}/${desired_bg_format} est déjà installé ; aucun téléchargement."
    elif [[ "${BACKGROUNDS_CHOICE}" == "yes" ]] || { [[ "${BACKGROUNDS_CHOICE}" == "ask" ]] && prompt_yes_no "Installer le pack de décors recommandé ($(artifact_value "${suite_summary}" roleplayBackgrounds sizeBytes) octets) ?" yes; }; then
      install_backgrounds=1
    fi
  fi

  if (( install_pulid )); then
    if [[ -z "${MODELS_ROOT}" ]]; then
      MODELS_ROOT="$(json_get "${local_summary}" modelsPath || true)"
    fi
    if [[ -z "${MODELS_ROOT}" ]]; then
      local default_models="${SUITE_ROOT}/models/PuLID_models" answer
      if prompt_yes_no "Utiliser ${default_models} pour les modèles PuLID ?" yes; then
        MODELS_ROOT="${default_models}"
      else
        read -r "answer?Chemin absolu du dossier PuLID_models (SSD externe accepté) : "
        [[ "${answer}" == /* ]] || die "Le dossier de modèles doit être absolu."
        MODELS_ROOT="${answer}"
      fi
    fi
    print -- "\nLicence InsightFace/AntelopeV2 : les poids sont réservés à la recherche non commerciale."
    print -- "Conditions : https://github.com/deepinsight/insightface/blob/master/server/LICENSING.md"
    prompt_yes_no "Acceptez-vous explicitement ces conditions avant tout téléchargement de modèle ?" no || die "Licence InsightFace refusée ; PuLID n'a pas été installé."
  fi

  local unsigned_lines
  unsigned_lines="$(json_helper unsigned-lines "${pointer_path}" "${manifest_path}" "${CHANNEL}")"
  if [[ -n "${unsigned_lines}" ]]; then
    print -- "\nAVERTISSEMENT — prerelease MVP non signée"
    print -- "${unsigned_lines}"
    print -- "HTTPS, taille et SHA-256 seront vérifiés pour chaque fichier. Aucune mise à jour silencieuse ne sera effectuée."
    if (( ! ACCEPT_UNSIGNED )); then
      prompt_yes_no "Continuer avec cette release non signée ?" no || die "Installation annulée avant les gros téléchargements."
    fi
  fi

  notice "Préflight matériel, disque, ports et réseau"
  prepare_preflight "${suite_summary}" "${install_rp}" "${install_pulid}" "${install_backgrounds}"

  (( install_rp )) && install_rp_bot "${suite_summary}" "${current_rp}"
  (( install_pulid )) && install_pulid "${suite_summary}" "${current_pulid}"
  (( install_backgrounds )) && install_backgrounds "${suite_summary}"

  notice "Installation terminée"
  print -- "Manifeste local : ${LOCAL_MANIFEST}"
  print -- "Les composants non sélectionnés, les données RP Bot et les modèles PuLID n'ont pas été supprimés."
}

main "$@"
