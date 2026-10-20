# Architecture - BlackHoleMonitorApp

Application macOS de barre de menus en Swift/SwiftUI qui intercepte et traite l'audio système en temps réel via le pilote audio virtuel BlackHole/Background Music.

## Vue d'ensemble

```
AppDelegate (point d'entrée, barre de menus + popover, volume Background Music)
    |
    +-- AudioManager (thread principal : réglages, périphériques, cycle de vie)
    |   +-- AudioSession (une par démarrage, tout l'état temps réel)
    |   |   +-- AUHAL d'entrée -> Resampler -> RingBuffer
    |   |   +-- RingBuffer -> karaoké -> Compressor -> Equalizer -> AudioVisualizer -> AUHAL de sortie
    |   |   +-- DemucsBridge (FIFO thread audio <-> réseau)
    |   +-- VocalSeparatorAI (client TCP + processus Python Demucs, file dédiée)
    |   +-- VisualizationTap -> minuterie 60 Hz -> VisualizationData (@Published)
    |
    +-- MenuBarView (UI SwiftUI - contrôles)
    +-- Visualisations : SpectrumAnalyzerView, OscilloscopeView, DiscoView, SpectrumFloatingWindow
```

## Modèle de threads

| Thread | Rôle | Règles |
|---|---|---|
| Principal | UI, `AudioManager`, création/arrêt de `AudioSession` | Publie les réglages, ne touche jamais à l'état des callbacks |
| Callback d'entrée (AUHAL) | Capture, désentrelacement, rééchantillonnage, écriture dans le `RingBuffer` | Aucune allocation, aucun log, aucun `DispatchQueue.async` |
| Callback de sortie (AUHAL) | Lecture du `RingBuffer`, traitement, copie vers le périphérique | Idem |
| File `com.blackhole.monitor.demucs` | Connexion TCP, processus Python, envoi/réception | Ne parle au thread audio que via les FIFO de `DemucsBridge` |

Les réglages passent du thread principal vers les threads audio par **`ParameterMailbox`** : l'écrivain publie une valeur complète sous verrou ; les lecteurs audio n'utilisent que `os_unfair_lock_trylock` et gardent leur copie précédente si le verrou est pris. Les valeurs sont des structures simples (SIMD, flottants, booléens), donc leur copie ne fait ni retain, ni release, ni libération mémoire.

- `RenderParameters` : volume, activations, intensité du karaoké, correction de dérive, visualisation.
- `Compressor.Parameters` et `Equalizer.Coefficients` : coefficients précalculés sur le thread principal. L'égaliseur change de coefficients **sans réinitialiser l'état des filtres**, donc sans clic.

Les FIFO (`RingBuffer`) sont préallouées et protégées par `os_unfair_lock`. Le verrou n'est tenu que le temps d'un `memcpy` borné, et il transmet sa priorité au détenteur, ce qui évite l'inversion de priorité.

## Fichiers sources

### `BlackHoleMonitorApp/DSP/` - code temps réel pur (module `AudioCore` testé par `swift test`)

| Fichier | Rôle |
|---|---|
| `ParameterMailbox.swift` | Transfert de paramètres thread principal -> threads audio, sans blocage côté audio |
| `RingBuffer.swift` | FIFO multicanale : amorçage, latence adaptative, fondus, vidage d'urgence |
| `Resampler.swift` | Interpolation Catmull-Rom en flux, phase continue entre les buffers |
| `DriftController.swift` | Ajuste le ratio de rééchantillonnage (±0,1 %) selon le remplissage du tampon |
| `Compressor.swift` | Compresseur crête par blocs de 32 frames |
| `Equalizer.swift` | 8 biquads (RBJ, Q = 1) en SIMD8, contournement quand tout est à 0 dB |
| `MidSideKaraoke.swift` | Karaoké instantané, Mid-Side sur 3 bandes |
| `AudioVisualizer.swift` | FFT 1024 points et oscilloscope, 30 i/s synchronisés, `VisualizationTap` |
| `DemucsProtocol.swift` | Format des messages client/serveur (v2) |
| `DemucsBridge.swift` | FIFO entrée/sortie du karaoké IA, mélange sec/traité aligné |

### Application

| Fichier | Rôle |
|---|---|
| `AudioSession.swift` | Unités AUHAL, callbacks, tampons préalloués, entrelacement |
| `AudioManager.swift` | Réglages `@Published`, persistance (différée de 0,5 s), périphériques, reconnexion USB |
| `VocalSeparatorAI.swift` | Lancement à la demande du serveur Python, connexion, découpage exact des messages |
| `AudioDevices.swift` | Requêtes CoreAudio (noms, canaux, fréquences) partagées |
| `Log.swift` | Journalisation unifiée (`os.Logger`) |
| `BlackHoleMonitorApp.swift` | `AppDelegate`, popover, écouteurs de volume/muet de Background Music |
| `SpectrumAnalyzerView.swift`, `OscilloscopeView.swift` | Visualisations Core Animation (`*LayerView`) et wrappers SwiftUI ; `OscilloscopeView` (Canvas) pour le disco |
| `MenuBarView.swift`, `DiscoView.swift`, `*Window.swift` | Interface |

## Pipeline audio

1. **Capture** : le callback d'entrée appelle `AudioUnitRender` avec l'horodatage et les drapeaux reçus. Il utilise une `AudioBufferList` préallouée : un tampon si le format est entrelacé, un tampon par canal sinon.
2. **Désentrelacement** si besoin (`vDSP_ztoc`).
3. **Rééchantillonnage** (si les fréquences diffèrent) avec le ratio corrigé par `DriftController`. La position de lecture est suivie en continu : le débit moyen est exact, sans saut de phase.
4. **Ring buffer** : cible de 10 ms (un bloc HAL typique). La cible ne grandit pas après une sous-alimentation, pour rester dans la fenêtre d'annulation d'écho des outils de visio. Un filet d'urgence vide 64 trames si le FIFO dépasse 2× la cible.
5. **Karaoké** : Mid-Side (fréquence de sortie) ou flux Demucs retardé.
6. **Compresseur**, **égaliseur**, **visualisation** (seulement si une vue est ouverte), **volume** (courbe x³).
7. **Sortie** : copie vers les tampons de l'AUHAL, entrelacés ou non (`vDSP_ctoz`).

Le traitement se fait par blocs de 4096 frames au plus. `kAudioUnitProperty_MaximumFramesPerSlice` est fixé à 4096 pour les deux unités.

## Comportement en surcharge CPU

Avant, chaque callback allouait plusieurs tableaux et envoyait des blocs sur la file principale. Sous charge, cela provoquait de courtes coupures en rafale : des craquements. Désormais :

- les callbacks n'allouent rien et ne prennent jamais de verrou bloquant pour lire les paramètres ;
- après une sous-alimentation, le `RingBuffer` reste silencieux (avec fondu) jusqu'à retrouver sa cible de 10 ms. On obtient **une seule coupure nette** au lieu d'une rafale de micro-coupures ;
- le nombre de sous-alimentations et la latence finale sont journalisés à l'arrêt.

## Karaoké IA (Demucs)

```
thread audio --(DemucsBridge.toServer)--> file réseau --AUDIO--> demucs_server.py
thread audio <-(DemucsBridge.fromServer)- file réseau <-RESULT-- (traité + sec aligné)
```

- **Protocole v2** (`DemucsProtocol.swift`, `ML/demucs_server.py`) : en-tête de 12 octets `magic "BHMD" | type | valeur`, suivi des données. Messages : `HELLO` (fréquence d'échantillonnage), `HELLO_ACK` (version), `AUDIO`, `RESULT`. `RESULT` contient `[wetL, wetR, dryL, dryR]` : le signal sec est aligné avec le signal traité, et le mélange selon l'intensité ne produit donc pas d'écho.
- **Serveur** : il sépare `[1,5 s de contexte | 0,75 s de nouveau signal]`, émet 0,75 s et applique un fondu enchaîné de 0,1 s entre deux blocs. HTDemucs complète chaque entrée jusqu'à son segment d'entraînement (~7,8 s) : un pas coûte le même temps quelle que soit la taille du bloc (~0,45 s sur MPS), d'où l'intérêt d'un bloc court. Le modèle est préchauffé au chargement, et à nouveau pour chaque fréquence d'échantillonnage pendant que le premier bloc se remplit. `shifts=0` (pas de décalage aléatoire). Rééchantillonnage vers la fréquence du modèle et retour, accumulation dans des tableaux numpy, coupe si le retard dépasse 10 s.
- **Latence** : 1,72 s mesurés à l'échantillon près (impulsions, 60 s, 0 coupure), 1,70 s sous charge CPU complète (0 coupure, pas le plus lent : 0,64 s pour un bloc de 0,75 s). Décomposition : 0,75 s de bloc + 0,1 s de fondu + ~0,45 s de calcul + 0,4 s de marge contre la gigue (`DemucsBridge.leadInSeconds`). Avant : ~3,7 s (bloc de 1,5 s, premier pas non préchauffé à ~1,5 s, marge de 0,75 s).
- **Cycle de vie** : le serveur est lancé seulement quand « Demucs AI » est activé, puis arrêté à la désactivation ou à la fermeture de l'app. Avec `--parent-pid`, il s'arrête aussi tout seul si l'app plante.
- **Interpréteur** : premier `python3` capable d'importer `demucs`, `torch` et `torchaudio` (Homebrew, `/usr/local`, python.org, système). On peut le forcer : `defaults write com.blackhole.monitor demucsPythonPath /chemin/python3`.
- **Sécurité** : la vérification TLS reste active ; les certificats de `certifi` sont utilisés s'il est installé.
- Tant que le flux IA n'est pas prêt, ou en cas d'échec, le Mid-Side est utilisé et l'UI affiche le statut.

## Système de visualisation

- Le thread audio calcule le spectre et l'oscilloscope ensemble, 30 fois par seconde **à partir du nombre d'échantillons** (indépendamment de la taille des buffers), et les dépose dans `VisualizationTap` (`trylock`).
- Une minuterie du thread principal (60 Hz, pour ne jamais afficher une image en retard d'une période) lit la dernière image et la transmet par `VisualizationData.deliver`. Elle ne tourne que si une visualisation est visible **et** que l'audio est démarré.
- **Popover et fenêtre flottante** : `SpectrumLayerView` et `OscilloscopeLayerView` sont des `NSView` en Core Animation, enregistrées comme `VisualizationListener`. Le spectre est une grille de segments statique avec un masque de 16 barres, dont seules les hauteurs changent à chaque image. L'oscilloscope est un tracé de 256 points partagé par 3 `CAShapeLayer`. SwiftUI n'est pas sollicité à chaque image, et la rastérisation se fait dans le serveur de rendu.
- **Mode disco** : il reste en SwiftUI (`Canvas`, animation à 60 i/s de toute façon) et observe les valeurs `@Published` de `VisualizationData`.

### Mesures (CPU de l'app, BlackHole -> sortie USB à 48 kHz, Mac mini Apple Silicon)

| État | CPU |
|---|---|
| Popover ouvert, Canvas SwiftUI (versions précédentes) | ~15 % |
| Popover ouvert, Core Animation (actuel) | 2,5 % (3 relevés de 60 s : 2,48 / 2,55 / 2,55) |
| Popover fermé, routage audio actif | 0,5 % |

### Gestion du drapeau `visualizationActive`

| Événement | Action |
|---|---|
| Démarrage de l'app | `visualizationActive = false` |
| Ouverture du popover | `= true` |
| Fermeture du popover | `= false` (si ni le spectre ni le disco ne sont actifs) |
| Ouverture du spectre flottant | `= true` |
| Fermeture du spectre flottant | `= false` (si le disco est inactif) |
| Ouverture du disco | `= true` |
| Fermeture du disco | `= false` (si le spectre est inactif) |

## Tests

```bash
swift test                      # 41 tests XCTest du dossier DSP/
swift test --sanitize=thread    # mêmes tests sous Thread Sanitizer
```

Les tests portent directement sur le code de production : continuité de phase et débit du rééchantillonneur, convergence de la correction de dérive en boucle fermée, amorçage et latence adaptative du ring buffer, absence de lectures déchirées dans `ParameterMailbox`, protocole Demucs, etc.

## Journaux

```bash
log stream --level info --predicate 'subsystem == "com.blackhole.monitor"'
```

Catégories : `app`, `audio`, `demucs` (y compris la sortie du serveur Python).

## Optimisations de performance

### Historique des optimisations CPU

Le projet est passé de **182 % CPU** à **0,0 % au repos** en plusieurs étapes :

1. **Limitation de l'UI** (`5635e37`) : 20 i/s pour le spectre, 60 i/s pour l'oscilloscope
2. **Isolation des re-rendus** (`077b71d`) : `VisualizationData` séparé
3. **FFT ignorée quand rien n'est visible** (`1d5142f`)
4. **Désactivation complète au repos** (`8ec583b`)
5. **Callbacks sans allocation** : FFT calculée 20 fois par seconde (et non plus à chaque callback), serveur Demucs lancé seulement à la demande (il démarrait avant à chaque lancement de l'app)
6. **Visualisation en Core Animation** : une image synchronisée à 30 i/s, dessinée par des `CALayer` au lieu de `Canvas` SwiftUI (~15 % -> 2,5 % avec le popover ouvert)

### Note sur le sample rate

Le démon `coreaudiod (usbaudiod)` peut consommer beaucoup de CPU (> 12 %) si la fréquence de la sortie USB ne correspond pas à sa fréquence native. Régler la sortie sur sa fréquence native (par exemple 44,1 kHz) règle le problème (0,0 % CPU).
