# Architecture - BlackHoleMonitorApp

Application macOS menu bar en Swift/SwiftUI (~4 100 lignes) qui intercepte et traite l'audio systeme en temps reel via le driver audio virtuel BlackHole/Background Music.

## Vue d'ensemble

```
AppDelegate (point d'entree, menu bar + popover)
    |
    +-- AudioManager (coeur, singleton)
    |   +-- Capture CoreAudio (entree/sortie via AUHAL)
    |   +-- Reechantillonnage vDSP (interpolation cubique)
    |   +-- OptimizedCompressor (compression dynamique)
    |   +-- OptimizedRingBuffer (buffer circulaire thread-safe)
    |   +-- SmoothDriftController (correction latence)
    |   +-- EQ 8 bandes (filtres Biquad)
    |   +-- Karaoke (mid-side ou IA Demucs)
    |   +-- VocalSeparatorAI (client TCP -> serveur Python Demucs)
    |
    +-- MenuBarView (UI SwiftUI - controles)
    |
    +-- Visualisations
        +-- SpectrumAnalyzerView (16 barres FFT)
        +-- OscilloscopeView (forme d'onde phosphore vert)
        +-- DiscoView (animation 60fps reactive a l'audio)
        +-- SpectrumFloatingWindow (fenetre flottante)
```

## Fichiers sources

| Fichier | Lignes | Role |
|---|---|---|
| `AudioManager.swift` | ~1600 | Coeur : capture CoreAudio, traitement temps reel (compresseur, EQ, karaoke), reechantillonnage vDSP, FFT, oscilloscope |
| `OptimizedAudioProcessing.swift` | ~386 | `SmoothDriftController` (correction latence), `OptimizedCompressor` (enveloppe attack/release, protection denormales), `OptimizedRingBuffer` (ring buffer thread-safe avec fade-in/out) |
| `VocalSeparatorAI.swift` | ~286 | Client TCP vers serveur Python Demucs (port 19845), separation vocale IA avec latence ~3s |
| `BlackHoleMonitorApp.swift` | ~267 | `AppDelegate`, barre de menu, popover, listeners CoreAudio (volume/mute) |
| `MenuBarView.swift` | ~394 | Interface SwiftUI : selection E/S, volume, compresseur, karaoke, EQ, toggles disco/spectrum |
| `DiscoView.swift` | ~390 | Animation disco 60fps : gradient pulsant (basses), aurores (mids), lasers (aigus), boule disco, 50 particules, strobe |
| `SpectrumFloatingWindow.swift` | ~125 | Fenetre flottante borderless avec spectre + oscilloscope + EQ 8 bandes |
| `SpectrumAnalyzerView.swift` | ~85 | 16 barres x 12 segments colores (vert/orange/rouge), rendu Canvas + drawingGroup() |
| `OscilloscopeView.swift` | ~53 | Trace forme d'onde avec effet halo phosphore multi-couches |
| `VerticalSliderView.swift` | ~55 | NSViewRepresentable pour slider vertical (EQ) |
| `DriftCorrectionTests.swift` | ~213 | 8 tests unitaires : drift, compresseur, ring buffer |

## Pipeline audio

1. **Capture** : AUHAL input callback recoit l'audio de BlackHole/Background Music
2. **Ring Buffer** : ecriture thread-safe avec protection underrun
3. **Drift Correction** : `SmoothDriftController` ajuste le ratio de reechantillonnage pour compenser la derive entre horloges d'entree/sortie
4. **Reechantillonnage** : `VDSPResampler` avec interpolation cubique (4 points)
5. **Compresseur** : enveloppe attack/release, threshold/ratio/makeup gain, protection denormales via vDSP
6. **EQ** : 8 filtres Biquad parametriques (-12/+12 dB) par canal
7. **Karaoke** : soustraction mid-side (stereo) ou separation vocale IA via Demucs
8. **Sortie** : AUHAL output callback vers le peripherique de sortie selectionne
9. **Visualisation** (conditionnelle) : FFT 1024 points -> 16 bandes spectre, oscilloscope 256 samples

## Systeme de visualisation

Les visualisations sont decoupees du pipeline audio principal via un flag `visualizationActive` :

- `VisualizationData` : objet `@ObservableObject` isole qui porte `spectrumBands` et `oscilloscopeSamples`
- Les vues (`SpectrumAnalyzerView`, `OscilloscopeView`) observent uniquement `VisualizationData`, pas `AudioManager` -> evite les re-renders de `MenuBarView`
- `SpectrumContainerView` et `OscilloscopeContainerView` : conteneurs d'isolation SwiftUI

### Gestion du flag `visualizationActive`

| Evenement | Action |
|---|---|
| Demarrage app | `visualizationActive = false` |
| Ouverture popover | `= true` |
| Fermeture popover | `= false` (si ni spectrum ni disco actifs) |
| Ouverture spectrum flottant | `= true` |
| Fermeture spectrum flottant | `= false` (si disco inactif) |
| Ouverture disco | `= true` |
| Fermeture disco | `= false` (si spectrum inactif) |

## Optimisations de performance

### Historique des optimisations CPU

Le projet est passe de **182% CPU** a **0.0% au repos** a travers plusieurs iterations :

1. **Throttling UI** (`5635e37`) : limitation des mises a jour UI a 20fps pour le spectre, 60fps pour l'oscilloscope
2. **Isolation re-renders** (`077b71d`) : `VisualizationData` separe pour eviter de re-render `MenuBarView` a chaque frame
3. **Skip FFT quand invisible** (`1d5142f`) : guard `visualizationActive` dans `analyzeSpectrum()` et `updateOscilloscope()`
4. **Desactivation complete au repos** (`8ec583b`) :
   - `visualizationActive` demarre a `false` au lieu de `true`
   - Timer disco 60fps controle par `onAppear`/`onDisappear` au lieu de `autoconnect()`
   - Fermeture disco/spectrum desactive correctement la visualisation
   - `popoverDidClose` verifie disco ET spectrum avant de couper

### Resultat

- **Au repos (aucun son)** : 0.0% CPU
- **Musique en lecture (pas de visualisation ouverte)** : 0.0% CPU (seul le pipeline audio tourne, cout negligeable)
- **Avec visualisation ouverte** : FFT + oscilloscope actifs, throttles a 20/60fps

### Note sur le sample rate

Le daemon `coreaudiod (usbaudiod)` peut consommer excessivement le CPU (>12%) si le sample rate de la sortie USB ne correspond pas au natif du peripherique. Configurer la sortie en 44.1kHz natif resout le probleme (0.0% CPU).
