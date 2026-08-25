# 🌲 Wildfire — Simulatore di foresta e incendi / Forest & Fire Simulator

Un simulatore di crescita di una foresta e dei suoi incendi, scritto in **Assembly ARM64** per macOS (Apple Silicon), che gira interamente nel terminale.

A forest-fire simulator written in **ARM64 assembly** for macOS (Apple Silicon), running entirely in your terminal.

---

## 🇮🇹 Italiano

### Ispirazione

Questo progetto è ispirato alla simulazione di incendi forestali mostrata da **Derek Muller (Veritasium)** nel video *"Why can't we predict catastrophic wildfires?"*:

🔗 **https://www.veritasium.com/simulation5**

Quella simulazione implementa il **modello Drossel–Schwabl** (autorganizzazione critica): alberi che crescono, fulmini rari che innescano incendi, e cenere che ricresce. Il nostro simulatore riprende l'idea — crescita, fulmini, propagazione del fuoco, cenere che sfuma — con controlli interattivi e una resa a mezzi-blocchi (`▀`) nel terminale.

### Compilazione (macOS, Apple Silicon)

Serve solo clang (Xcode Command Line Tools). Nessuna libreria extra.

```bash
clang -o wildfire wildfire.s -arch arm64
```

### Uso

```bash
./wildfire                        # default: 128×128, alberi 40, fulmini 40
./wildfire 60 80                  # alberi 60, fulmini 80
./wildfire --size 256             # board 256×256 (anche 512)
./wildfire --demo                 # foresta piena + incendio al centro
./wildfire -h                     # aiuto completo
```

**Argomenti posizionali**: `[alberi] [fulmini]` — valori 1..100 (scale quadratiche, ancorate a 40).

**Opzioni**:

| Opzione | Effetto |
|---|---|
| `--size N` | Dimensione board: 128, 256 o 512 (default 128) |
| `--demo` | Foresta piena + incendio al centro |
| `--zoom` | Auto-riduce lo zoom kitty all'avvio (richiede kitty) |
| `--no-zoom` | Disabilita l'auto-zoom (default) |
| `-h`, `--help` | Mostra l'aiuto |

### Comandi in gioco

| Tasto | Effetto |
|---|---|
| `↑` `↓` | Alberi ±5 |
| `→` `←` | Fulmini ±5 |
| `Shift`/`Ctrl` + freccia | Regolazione fine ±1 |
| `SPACE` | Pausa |
| `Q` / `ESC` | Esci |
| `[` `]` | Rallenta / accelera la simulazione |
| `Cmd+0` | Ripristina lo zoom originale (kitty) |

Se il terminale è troppo piccolo per la board richiesta, il programma stampa un messaggio e **parte da solo appena lo zoom è giusto** (riduci il testo con `Cmd−`).

### Come funziona

- **Griglia adattiva** a mezzi-blocchi: ogni carattere `▀` disegna 2 celle (la riga pari nella metà superiore, la dispari in quella inferiore) → le celle risultano quasi quadrate.
- **Crescita**: ogni cella vuota diventa albero con probabilità `(slider/100)²`-scalata; le celle adiacenti a un albero hanno un piccolo bonus (+0,05% assoluti) → nel tempo si formano cluster.
- **Fulmini**: cercano una cella con un albero (fino a 64 tentativi), quindi la frequenza **non dipende dalla densità** della foresta.
- **Fuoco**: si propaga di 1 cella/frame; le diagonali e le braci (cenere) incendiano anch'esse → fronte rotondo.
- **Cenere che sfuma**: dopo la fiamma, la cella passa per 8 stadi di cenere (brace calda → quasi nero) prima di tornare vuota e ricrescere; le braci continuano a incendiare i vicini.
- **Scale quadratiche**: spostando gli slider oltre il 40 l'effetto accelera in modo evidente (a 100 è 6,25× rispetto a 40).

---

## 🇬🇧 English

### Inspiration

This project is inspired by the wildfire simulation shown by **Derek Muller (Veritasium)** in *"Why can't we predict catastrophic wildfires?"*:

🔗 **https://www.veritasium.com/simulation5**

That simulation implements the **Drossel–Schwabl model** (self-organized criticality): trees that grow, rare lightning strikes that start fires, and ash that regrows. Ours takes the same ideas — growth, lightning, fire spread, fading ash — with interactive controls and half-block (`▀`) rendering in the terminal.

### Building (macOS, Apple Silicon)

You only need clang (Xcode Command Line Tools). No extra libraries.

```bash
clang -o wildfire wildfire.s -arch arm64
```

### Usage

```bash
./wildfire                        # default: 128×128, trees 40, lightning 40
./wildfire 60 80                  # trees 60, lightning 80
./wildfire --size 256             # 256×256 board (512 also works)
./wildfire --demo                 # full forest + fire at the center
./wildfire -h                     # full help
```

**Positional arguments**: `[trees] [lightning]` — values 1..100 (quadratic scales, anchored at 40).

**Options**:

| Option | Effect |
|---|---|
| `--size N` | Board size: 128, 256 or 512 (default 128) |
| `--demo` | Full forest + fire at the center |
| `--zoom` | Auto-shrinks kitty zoom at startup (requires kitty) |
| `--no-zoom` | Disables auto-zoom (default) |
| `-h`, `--help` | Show help |

### In-game controls

| Key | Effect |
|---|---|
| `↑` `↓` | Trees ±5 |
| `→` `←` | Lightning ±5 |
| `Shift`/`Ctrl` + arrow | Fine tuning ±1 |
| `SPACE` | Pause |
| `Q` / `ESC` | Quit |
| `[` `]` | Slow down / speed up the simulation |
| `Cmd+0` | Restore original zoom (kitty) |

If the terminal is too small for the requested board, the program prints a hint and **starts by itself as soon as the zoom is right** (shrink the text with `Cmd−`).

### How it works

- **Adaptive half-block grid**: each `▀` character draws 2 cells (even row in the top half, odd row in the bottom half) → cells end up roughly square.
- **Growth**: every empty cell becomes a tree with a `(slider/100)²`-scaled probability; cells adjacent to a tree get a small bonus (+0.05% absolute) → clusters form over time.
- **Lightning**: searches for a tree cell (up to 64 tries), so strike frequency **does not depend** on forest density.
- **Fire**: spreads 1 cell per frame; diagonals and embers (ash) also ignite → round fire front.
- **Fading ash**: after the flame, a cell goes through 8 ash stages (hot ember → near black) before becoming empty and regrowing; embers keep igniting neighbors.
- **Quadratic scales**: moving the sliders above 40 accelerates noticeably (100 is 6.25× relative to 40).

---

*Made with ❤️ and a lot of ARM64 assembly. Feedback and pull requests welcome.*
