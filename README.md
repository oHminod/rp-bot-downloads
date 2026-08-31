# RP Bot Suite

RP Bot Suite regroupe **RP Bot**, son pack de décors recommandé et, en option,
**PuLID** pour la génération d'images. Les installeurs ci-dessous suivent le
canal bêta et récupèrent automatiquement sa release la plus récente.

> [!WARNING]
> La version actuellement publiée est une prerelease MVP non signée. macOS ou
> Windows peut donc afficher un avertissement de sécurité. L'installeur demande
> une confirmation explicite avant les téléchargements importants, puis vérifie
> chaque archive par sa taille et son empreinte SHA-256.

## Télécharger l'installeur

| Plateforme | Configuration requise | Téléchargement direct |
| --- | --- | --- |
| macOS | macOS 14 ou plus récent, Mac Apple Silicon (M1 ou ultérieur) | **[Télécharger pour macOS / Apple Silicon](https://raw.githubusercontent.com/oHminod/rp-bot-downloads/main/install-rp-bot-macos.command)** |
| Windows | Windows 11 64 bits ; GPU NVIDIA et pilote compatible CUDA 13 pour PuLID | **[Télécharger pour Windows / CUDA](https://raw.githubusercontent.com/oHminod/rp-bot-downloads/main/install-rp-bot-windows.bat)** |

Si le navigateur affiche le contenu du fichier au lieu de le télécharger,
faites un clic droit sur le lien puis choisissez **Enregistrer le lien sous**.

La release bêta publiée et ses notes sont disponibles sur la page
[Releases](https://github.com/oHminod/rp-bot-downloads/releases).

## Avant de commencer

- Déplacez l'installeur dans un dossier permanent et inscriptible, hors du
  dossier `Téléchargements`. Le dossier `RP Bot Suite` sera créé **à côté de
  l'installeur**.
- Pour installer PuLID, prévoyez au minimum **16 Go de mémoire** et environ
  **20 Go d'espace libre** (6 Go pour le runtime et 14 Go pour les modèles),
  davantage si vous téléchargez aussi un checkpoint SDXL.
- Sous Windows, PuLID exige un GPU NVIDIA et un pilote dont `nvidia-smi`
  annonce CUDA 13 ou une version ultérieure. RP Bot seul ne nécessite pas de
  GPU NVIDIA.
- Gardez une connexion Internet active pendant toute l'installation. Aucun
  clone Git ni environnement de développement Node.js n'est nécessaire.

## Installation sur macOS

1. Téléchargez `install-rp-bot-macos.command`, puis déplacez-le dans le dossier
   où vous souhaitez conserver RP Bot Suite, par exemple `~/Applications`.
2. Ouvrez Terminal et rendez le fichier exécutable :

   ```sh
   chmod +x ~/Applications/install-rp-bot-macos.command
   ```

3. Lancez-le depuis Terminal :

   ```sh
   ~/Applications/install-rp-bot-macos.command
   ```

   Vous pouvez aussi faire un clic droit sur le fichier dans Finder, choisir
   **Ouvrir**, puis confirmer l'ouverture si macOS affiche un avertissement.
4. Choisissez d'installer **RP Bot**, **PuLID**, ou les deux. Si vous installez
   RP Bot, l'installeur propose également le pack de décors recommandé.
5. Pour PuLID, choisissez l'emplacement des modèles, acceptez la licence
   InsightFace/AntelopeV2 si elle vous convient, puis choisissez si vous
   souhaitez fournir ou télécharger un modèle SDXL.
6. Lisez l'avertissement concernant la prerelease non signée et confirmez pour
   lancer l'installation.

Une fois l'installation terminée, ouvrez `RP Bot Suite`, puis double-cliquez
sur `Lancer RP Bot.command`. Les lanceurs PuLID et le lanceur de mise à jour
sont créés dans le même dossier lorsque les composants correspondants sont
installés.

## Installation sur Windows

1. Téléchargez `install-rp-bot-windows.bat`, puis déplacez-le dans le dossier
   où vous souhaitez conserver RP Bot Suite.
2. Double-cliquez sur le fichier. Si Microsoft Defender SmartScreen intervient,
   vérifiez que le fichier provient bien de ce dépôt avant de choisir
   **Informations complémentaires**, puis **Exécuter quand même**.
3. Choisissez d'installer **RP Bot**, **PuLID**, ou les deux. Si vous installez
   RP Bot, l'installeur propose également le pack de décors recommandé.
4. Pour PuLID, choisissez l'emplacement des modèles, acceptez la licence
   InsightFace/AntelopeV2 si elle vous convient, puis choisissez si vous
   souhaitez fournir ou télécharger un modèle SDXL.
5. Confirmez l'installation de la prerelease non signée. L'installeur contrôle
   ensuite Windows, la mémoire, l'espace disque et, pour PuLID, le GPU NVIDIA
   ainsi que la compatibilité CUDA du pilote avant tout gros téléchargement.

Une fois l'installation terminée, ouvrez `RP Bot Suite`, puis double-cliquez
sur `Lancer RP Bot.bat`. Les lanceurs PuLID et le lanceur de mise à jour sont
créés dans le même dossier lorsque les composants correspondants sont
installés.

## Mettre à jour

Double-cliquez sur `Mettre a jour RP Bot.command` sous macOS ou
`Mettre a jour RP Bot.bat` sous Windows. Le lanceur consulte le canal bêta,
télécharge la release la plus récente et conserve les données RP Bot ainsi que
les modèles PuLID.

En cas de téléchargement interrompu, relancez simplement l'installeur ou le
lanceur de mise à jour : le fichier partiel est conservé et revalidé avant la
reprise.
