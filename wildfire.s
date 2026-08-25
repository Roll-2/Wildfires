// ============================================================
// wildfire.s — Wildfire Simulator ARM64 (macOS)
// Griglia ADATTIVA (max 512×512 con --size N, default 128×128),
// tabellone FISSO con aggiornamenti incrementali (niente scroll).
//
// COME COMPILARE (macOS, Apple Silicon):
//   clang -o wildfire wildfire.s -arch arm64
// (basta clang / Command Line Tools; nessuna libreria extra)
//
// ESEMPI:
//   ./wildfire                  default 128×128, alberi 40, fulmini 40
//   ./wildfire 60 80            alberi 60, fulmini 80
//   ./wildfire --size 256       board 256×256 (anche 512)
//   ./wildfire --demo           foresta piena + incendio al centro
//   ./wildfire -h               aiuto completo (tasti e opzioni)
//
// IMPORTANTE (bug fix): su macOS ARM64 gli argomenti delle
// funzioni VARIADICHE (printf) si passano sullo STACK,
// NON nei registri x1-x7 (diverso da Linux AAPCS64).
// Vedere _print_status_bar. Lo spazio per i varargs deve restare
// ALLINEATO a 16 byte (es. 7 argomenti → sub sp, #64, non #56).
//
// Attesa zoom: se il terminale non è abbastanza grande per la board
// richiesta (--size, default 128) il programma stampa un hint e
// ricontrolla da solo ogni mezzo secondo finché non entra.
// ============================================================

.global _main
.align 2

// ============================================================
// Costanti
// ============================================================
.equ GRID_SIZE_MAX,  512        // cap massimo (--size 512)
.equ GRID_AREA_MAX,  262144      // 512 * 512
.equ ROW_BUF_SIZE,   16384       // Buffer per una riga di output (256 celle ~9KB)

// Stati cella
.equ CELL_EMPTY,      0
.equ CELL_TREE,       1
.equ CELL_BURNING,    2
// Cenere che sfuma: stati 3..10 = ASH_0..ASH_7 (avanza di 1 a
// frame, poi EMPTY). NB: ogni stato >= 2 (BURNING o cenere) =
// "che incendia" (le braci accendono i vicini).
.equ CELL_ASH_0,      3
.equ CELL_ASH_LAST,   10

// Slider utente (1..100): le soglie 32-bit vengono ricavate da qui
// in _update_thresholds in base a fps (frame_delay).
// SCALE QUADRATICHE (s², richiesta utente) ancorate a s=40:
//   alberi:  default 40 ≈ ~3.5 min (INVARIATO); 100 → 6.25× (fill ~33s);
//            1 ≈ quasi fermo (inerente alla quadratica)
//   fulmini: default 40 ≈ 1 ogni ~2.5s (INVARIATO); 100 → 6.25× (≥4×
//            richiesto); 1 ≈ quasi mai. Indipendente dalla densità
//            grazie alla ricerca cella TREE
.equ DEFAULT_TREE_SLIDER,      40
.equ DEFAULT_LIGHTNING_SLIDER, 40

// Frequenza fulmini: quanti frame attendere tra un tentativo e l'altro
.equ LIGHTNING_COOLDOWN,    1
// Ricerca cella TREE: fino a LIGHTNING_RETRIES tentativi per trovare un
// albero da colpire → la frequenza NON dipende più dalla densità della
// foresta (slider 100 = ~1 fulmine ogni 2s anche con foresta rada).
.equ LIGHTNING_RETRIES,     64
// Bonus clustering alberi: +0.05% assoluti (0.0005 * 2^32) di probabilità
// che una cella ADIACENTE (8 direzioni) a un albero diventi TREE, così
// nel lungo periodo si formano piccoli cluster senza alterare la crescita
// di base.
.equ CLUSTER_BONUS,         2147484   // = 0x20C49C

// Terminale
.equ TCSANOW,         0
.equ ICANON,          0x00000100
.equ ECHO,            0x00000008
.equ ISIG,            0x00000001
.equ F_SETFL,         3           // macOS fcntl
.equ O_NONBLOCK,      0x0004      // macOS
.equ SIGINT,          2
.equ SIGTERM,         15

// TIOCGWINSZ = _IOR('t', 104, struct winsize) = 0x40087468
// (caricato con movz/movk perché > 4095)

// Lunghezze stringhe ANSI (byte, senza NUL)
.equ LEN_CLEAR,       4           // \033[2J
.equ LEN_HIDE_CURSOR, 6           // \033[?25l
.equ LEN_SHOW_CURSOR, 6           // \033[?25h
.equ LEN_RESET,       4           // \033[0m
.equ LEN_ALT_ON,      8           // \033[?1049h
.equ LEN_ALT_OFF,     8           // \033[?1049l

// ============================================================
// Sezione .data — dati inizializzati
// ============================================================
.data
.align 4

// --- Stringhe ANSI ---
ansi_clear:         .asciz  "\033[2J"
ansi_hide_cursor:   .asciz  "\033[?25l"
ansi_show_cursor:   .asciz  "\033[?25h"
ansi_reset:         .asciz  "\033[0m"
ansi_alt_on:        .asciz  "\033[?1049h"
ansi_alt_off:       .asciz  "\033[?1049l"

// Colori SFONDO (ESC[48;2;R;G;Bm) — per la meta' superiore della cella
color_empty:        .asciz  "\033[48;2;0;0;0m"
color_tree:         .asciz  "\033[48;2;20;160;30m"
color_burning:      .asciz  "\033[48;2;255;60;0m"
// Cenere (stati 3..10): rampa brace calda → quasi nero, poi EMPTY
color_ash0:         .asciz  "\033[48;2;70;40;20m"
color_ash1:         .asciz  "\033[48;2;58;33;17m"
color_ash2:         .asciz  "\033[48;2;48;27;14m"
color_ash3:         .asciz  "\033[48;2;39;22;11m"
color_ash4:         .asciz  "\033[48;2;31;18;9m"
color_ash5:         .asciz  "\033[48;2;24;14;7m"
color_ash6:         .asciz  "\033[48;2;18;10;5m"
color_ash7:         .asciz  "\033[48;2;11;6;3m"

// Array puntatori ai colori di SFONDO per indice stato
.align 3
color_table:
    .quad color_empty
    .quad color_tree
    .quad color_burning
    .quad color_ash0
    .quad color_ash1
    .quad color_ash2
    .quad color_ash3
    .quad color_ash4
    .quad color_ash5
    .quad color_ash6
    .quad color_ash7

// Colori PRIMO PIANO (ESC[38;2;R;G;Bm) — meta' inferiore della cella
color_empty_fg:     .asciz  "\033[38;2;0;0;0m"
color_tree_fg:      .asciz  "\033[38;2;20;160;30m"
color_burning_fg:   .asciz  "\033[38;2;255;60;0m"
color_ash0_fg:      .asciz  "\033[38;2;70;40;20m"
color_ash1_fg:      .asciz  "\033[38;2;58;33;17m"
color_ash2_fg:      .asciz  "\033[38;2;48;27;14m"
color_ash3_fg:      .asciz  "\033[38;2;39;22;11m"
color_ash4_fg:      .asciz  "\033[38;2;31;18;9m"
color_ash5_fg:      .asciz  "\033[38;2;24;14;7m"
color_ash6_fg:      .asciz  "\033[38;2;18;10;5m"
color_ash7_fg:      .asciz  "\033[38;2;11;6;3m"

.align 3
color_table_fg:
    .quad color_empty_fg
    .quad color_tree_fg
    .quad color_burning_fg
    .quad color_ash0_fg
    .quad color_ash1_fg
    .quad color_ash2_fg
    .quad color_ash3_fg
    .quad color_ash4_fg
    .quad color_ash5_fg
    .quad color_ash6_fg
    .quad color_ash7_fg

// Colore del BORDO box-drawing (grigio-azzurro, neutro)
color_border:       .asciz  "\033[38;2;130;140;155m"

// Status bar — RIGA 1: barra con sfondo scuro SLATE (24,30,42),
// separatori '│' grigi, valori bianchi. Il colore del fuoco/pausa
// è incorporato NELLE STRINGHE %s (vedi status_fire_on/off).
status_fmt:
    .asciz  "\033[48;2;24;30;42m\033[K\033[38;2;70;85;105m│ \033[38;2;160;170;185mTrees:\033[38;2;235;240;245m %d \033[38;2;70;85;105m│ Burning:\033[38;2;235;240;245m %d \033[38;2;70;85;105m│ Fire: %s %s\033[0m\n"
// Status bar — RIGA 2: probabilità + griglia + hint tasti
status_fmt2:
    .asciz  "\033[48;2;24;30;42m\033[K\033[38;2;70;85;105m│ \033[38;2;160;170;185mGrowth:\033[38;2;235;240;245m %d/100 \033[38;2;70;85;105m│ Lightning:\033[38;2;235;240;245m %d/100 \033[38;2;70;85;105m│ Grid:\033[38;2;235;240;245m %dx%d \033[38;2;70;85;105m│ SPACE=pausa Q=esci\033[0m\n"
// Le stringhe %s portano con sé il proprio colore + ritorno al bianco
status_fire_on:     .asciz  "\033[38;2;255;120;60mACTIVE!!\033[38;2;235;240;245m"
status_fire_off:    .asciz  "\033[38;2;110;120;130mnone\033[38;2;235;240;245m"
status_paused:      .asciz  "\033[38;2;255;210;90mPAUSED\033[38;2;235;240;245m"
status_blank:       .asciz  ""

// Zoom kitty — OSC kitty-cmd scritto DIRETTAMENTE su stdout
// (è esattamente ciò che fa `kitten @`): funziona in kitty senza
// allow_remote_control, non blocca mai e non sporca l'output.
// Delta: -12 all'avvio, +12 all'uscita (restore esatto dello zoom).
// Attivo SOLO se KITTY_WINDOW_ID è settata (siamo dentro kitty).
zoom_shrink_osc:
    .asciz  "\033P@kitty-cmd{\"cmd\":\"set-font-size\",\"payload\":{\"size\":12,\"increment_op\":\"-\"}}\033\\"
zoom_restore_osc:
    .asciz  "\033P@kitty-cmd{\"cmd\":\"set-font-size\",\"payload\":{\"size\":12,\"increment_op\":\"+\"}}\033\\"

env_kitty_window:   .asciz  "KITTY_WINDOW_ID"
nozoom_flag:        .asciz  "--no-zoom"
zoom_flag:          .asciz  "--zoom"
demo_flag:          .asciz  "--demo"
size_flag:          .asciz  "--size"
help_flag:          .asciz  "-h"
help_flag_long:     .asciz  "--help"
help_flag_dash:     .asciz  "-help"

// Aiuto CLI (-h / --help): stampato PRIMA della config del terminale
msg_help:
    .asciz  "Wildfire — simulatore di foresta e incendi (ARM64)\n\nUso:  ./wildfire [alberi] [fulmini] [opzioni]\n\n  alberi    velocita' crescita alberi (1..100, default 40)\n  fulmini   frequenza fulmini        (1..100, default 40)\n\nOpzioni:\n  --size N   dimensione board: 128, 256 o 512 (default 128)\n  --demo     foresta piena + incendio al centro\n  --zoom     auto-riduci lo zoom kitty all'avvio\n  --no-zoom  disabilita l'auto-zoom (default)\n  -h, --help mostra questo aiuto\n\nTasti in gioco:\n  frecce       alberi (↑↓) / fulmini (→←) ±5\n  Shift/Ctrl+freccia  regolazione fine ±1\n  SPACE        pausa          Q / ESC    esci\n  [ ]          rallenta / accelera la simulazione\n  Cmd+0        ripristina lo zoom originale\n"

// Messaggio attesa zoom manuale: corto, senza numeri, colore viola.
msg_wait_fmt:
    .asciz  "\r\033[2K  \033[38;2;205;170;255m🌲 Rimpicciolisci un po' il testo (Cmd−) finché la board entra: parto da solo! Cmd+0 = zoom originale ✨\033[0m   (Ctrl+C = esci)"
msg_restore_zoom:
    .asciz  "\nRiporta lo zoom alla dimensione originale (Ctrl+= / Cmd+0).\n"

// Errori
err_term_raw:       .asciz  "Error: cannot set raw terminal mode\n"
err_term_restore:   .asciz  "Error: cannot restore terminal\n"
err_fcntl:          .asciz  "Error: cannot set non-blocking input\n"

// ============================================================
// Sezione .bss — dati non inizializzati
// ============================================================
.bss
.align 4

// Griglie: double-buffer + snapshot per il diff incrementale
grid:           .space  GRID_AREA_MAX
new_grid:       .space  GRID_AREA_MAX
prev_grid:      .space  GRID_AREA_MAX

// Buffer di output (RLE / diff)
row_buffer:     .space  ROW_BUF_SIZE
scratch_buf:    .space  32

// Dimensione terminale (da ioctl TIOCGWINSZ)
winsize_buf:    .space  8
ws_row:         .space  2
ws_col:         .space  2
last_ws:        .space  4

// Layout della board (calcolati da _compute_layout)
grid_size:      .space  4    // lato griglia (≤ 128)
grid_area:      .space  4    // size*size
top_pad:        .space  4    // righe vuote sopra la griglia
left_pad:       .space  4    // colonne vuote a sinistra

// Stato PRNG xorshift32
prng_state:     .space  4

// Slider utente (1..100) e soglie 32-bit derivate
tree_slider:        .space  4   // 1..100
tree_threshold:     .space  4   // 32 bit, da _update_thresholds
lightning_slider:   .space  4   // 1..100
lightning_threshold: .space 4   // 32 bit, da _update_thresholds

// Dimensione richiesta via --size (default 128) + indice argv del valore
grid_size_request:  .space  4
size_arg_idx:       .space  4   // -1 = nessuno
wait_was_active:    .space  4   // 1 se l'attesa zoom ha davvero aspettato

// Flag di stato
fire_active:    .space  4
paused:         .space  4
running:        .space  4
lightning_cooldown_counter: .space 4
zoom_active:    .space  4
zoom_disabled:  .space  4
demo_mode:      .space  4

// Strutture termios (128 byte ciascuna per sicurezza)
old_termios:    .space  128
new_termios:    .space  128

// Buffer per lettura tasti
key_buffer:     .space  8
// Byte di una sequenza ESC spezzata tra due read (max 8: read(8) - consumati)
pend_buf:       .space  16
pend_len:       .space  4

// Contatori per la status bar
frame_delay:    .space  4   // usleep per frame (tasti [ ])
tree_count:     .space  4
burning_count:  .space  4

// ============================================================
// Sezione .text — codice
// ============================================================
.text
.align 2

// ------------------------------------------------------------
// _main — Entry point
// ------------------------------------------------------------
_main:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x22, x21, [sp, #-16]!
    stp     x20, x19, [sp, #-16]!

    mov     x19, x0                 // argc
    mov     x20, x1                 // argv

    // Slider di default (1..100) + dimensione richiesta
    mov     w0, #DEFAULT_TREE_SLIDER
    adrp    x1, tree_slider@PAGE
    str     w0, [x1, tree_slider@PAGEOFF]
    mov     w0, #DEFAULT_LIGHTNING_SLIDER
    adrp    x1, lightning_slider@PAGE
    str     w0, [x1, lightning_slider@PAGEOFF]
    mov     w0, #128
    adrp    x1, grid_size_request@PAGE
    str     w0, [x1, grid_size_request@PAGEOFF]
    mov     w0, #-1
    adrp    x1, size_arg_idx@PAGE
    str     w0, [x1, size_arg_idx@PAGEOFF]

    // --- Flag scan (SEMPRE eseguito, PRIMA del parse numerico) ---
    // ./wildfire [tree_rate] [lightning_rate] [--zoom] [--no-zoom] [--demo]
    // Default: zoom DISABILITATO. L'OSC kitty-cmd senza allow_remote_control
    // in kitty.conf fa stampare a kitty l'errore "Remote control is disabled"
    // nel terminale (rompe il display) — quindi SOLO --zoom esplicito.
    adrp    x0, zoom_disabled@PAGE
    add     x0, x0, zoom_disabled@PAGEOFF
    mov     w1, #1
    str     w1, [x0]                 // 1 = zoom off
    mov     w22, #1                   // indice argv
pg_flags:
    cmp     w22, w19
    b.hs    parse_done
    ldr     x0, [x20, w22, uxtw #3]
    // -h / --help / -help: stampa l'uso ed esce pulito
    adrp    x1, help_flag@PAGE
    add     x1, x1, help_flag@PAGEOFF
    bl      _str_eq
    cbz     w0, 12f
    bl      _print_help
    mov     w0, #0
    b       _exit_prog
12: ldr     x0, [x20, w22, uxtw #3]
    adrp    x1, help_flag_long@PAGE
    add     x1, x1, help_flag_long@PAGEOFF
    bl      _str_eq
    cbz     w0, 13f
    bl      _print_help
    mov     w0, #0
    b       _exit_prog
13: ldr     x0, [x20, w22, uxtw #3]
    adrp    x1, help_flag_dash@PAGE
    add     x1, x1, help_flag_dash@PAGEOFF
    bl      _str_eq
    cbz     w0, 14f
    bl      _print_help
    mov     w0, #0
    b       _exit_prog
14:
    // x0 è stato consumato dal check -help → ricarica argv[w22]
    ldr     x0, [x20, w22, uxtw #3]
    // --size N: imposta grid_size_request (pari, 128..512)
    adrp    x1, size_flag@PAGE
    add     x1, x1, size_flag@PAGEOFF
    bl      _str_eq
    cbz     w0, 11f
    add     w23, w22, #1
    cmp     w23, w19
    b.hs    9f                      // --size senza valore: ignora
    ldr     x0, [x20, w23, uxtw #3]
    bl      _atoi
    mov     w1, #512
    cmp     w0, w1
    csel    w0, w1, w0, hi          // clamp max 512
    mov     w1, #128
    cmp     w0, w1
    csel    w0, w1, w0, lo          // clamp min 128
    bic     w0, w0, #1              // arrotonda a pari
    adrp    x1, grid_size_request@PAGE
    add     x1, x1, grid_size_request@PAGEOFF
    str     w0, [x1]
    adrp    x1, size_arg_idx@PAGE
    add     x1, x1, size_arg_idx@PAGEOFF
    str     w23, [x1]
    mov     w22, w23                // salta il valore nel parse numerico
    b       9f
11:
    // x0 è stato consumato da _str_eq del check --size → ricarica argv
    ldr     x0, [x20, w22, uxtw #3]
    adrp    x1, zoom_flag@PAGE
    add     x1, x1, zoom_flag@PAGEOFF
    bl      _str_eq
    cbz     w0, 8f
    adrp    x0, zoom_disabled@PAGE
    add     x0, x0, zoom_disabled@PAGEOFF
    str     wzr, [x0]                 // --zoom → abilita
    b       9f
8:  ldr     x0, [x20, w22, uxtw #3]
    adrp    x1, nozoom_flag@PAGE
    add     x1, x1, nozoom_flag@PAGEOFF
    bl      _str_eq
    cbz     w0, 10f
    adrp    x0, zoom_disabled@PAGE
    add     x0, x0, zoom_disabled@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
    b       9f
10: ldr     x0, [x20, w22, uxtw #3]
    adrp    x1, demo_flag@PAGE
    add     x1, x1, demo_flag@PAGEOFF
    bl      _str_eq
    cbz     w0, 9f
    adrp    x0, demo_mode@PAGE
    add     x0, x0, demo_mode@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
9:  add     w22, w22, #1
    b       pg_flags
parse_done:

    // --- Parsing numerico: ./wildfire [tree 0..255] [lightning 0..65535] ---
    // BUG FIX: prima versione leggeva argv[1]/argv[2] a fisso, quindi
    // `./wildfire --demo` passava "--demo" ad atoi → soglie azzerate!
    // Ora: scarta gli argomenti che iniziano con '-', usa i primi
    // due argomenti NUMERICI trovati (tree, poi lightning).
    mov     w22, #1                 // indice argv
    mov     w21, #0                 // numerici trovati finora
parse_num:
    cmp     w22, w19
    b.hs    parse_num_done
    // Salta l'eventuale valore di --size (già consumato nel flag scan)
    adrp    x0, size_arg_idx@PAGE
    add     x0, x0, size_arg_idx@PAGEOFF
    ldr     w1, [x0]
    cmp     w1, w22
    b.eq    parse_num_next
    ldr     x0, [x20, w22, uxtw #3]
    ldrb    w1, [x0]
    cmp     w1, #'-'
    b.eq    parse_num_next
    bl      _atoi
    cbnz    w21, parse_lightning
    // Primo numerico → tree_slider 1..100
    cmp     w0, #1
    b.ge    1f
    mov     w0, #1
    b       2f
1:  cmp     w0, #100
    b.le    2f
    mov     w0, #100
2:
    adrp    x1, tree_slider@PAGE
    add     x1, x1, tree_slider@PAGEOFF
    str     w0, [x1]
    mov     w21, #1
    b       parse_num_next
parse_lightning:
    cmp     w0, #1
    b.ge    3f
    mov     w0, #1
    b       4f
3:  cmp     w0, #100
    b.le    4f
    mov     w0, #100
4:
    adrp    x1, lightning_slider@PAGE
    add     x1, x1, lightning_slider@PAGEOFF
    str     w0, [x1]
    mov     w21, #2
parse_num_next:
    add     w22, w22, #1
    b       parse_num
parse_num_done:

    // Flag iniziali
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    str     wzr, [x0]
    adrp    x0, paused@PAGE
    add     x0, x0, paused@PAGEOFF
    str     wzr, [x0]
    adrp    x0, running@PAGE
    add     x0, x0, running@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
    adrp    x0, lightning_cooldown_counter@PAGE
    add     x0, x0, lightning_cooldown_counter@PAGEOFF
    str     wzr, [x0]
    adrp    x0, frame_delay@PAGE
    add     x0, x0, frame_delay@PAGEOFF
    movz    w1, #0x80E8            // 33000 µs ≈ 30 fps
    str     w1, [x0]

    // Soglie 32-bit dagli slider (dopo che frame_delay è settato)
    bl      _update_thresholds

    bl      _get_prng_seed

    // Zoom shrink (OPZIONALE, solo con --zoom): prima di misurare il
    // terminale, così la griglia può usare più spazio. Disabilitato di
    // default per non sporcare l'output con l'OSC kitty-cmd.
    adrp    x0, zoom_disabled@PAGE
    add     x0, x0, zoom_disabled@PAGEOFF
    ldr     w0, [x0]
    cbnz    w0, 5f
    bl      _setup_zoom
5:
    // Attesa zoom manuale: se il terminale non è abbastanza grande
    // per la board richiesta, stampa l'hint e ricontrolla da solo
    // ogni mezzo secondo finché non entra (poi si parte).
    bl      _wait_for_terminal
    // Misura terminale + layout
    bl      _query_term_size
    adrp    x0, ws_row@PAGE
    add     x0, x0, ws_row@PAGEOFF
    ldrh    w1, [x0]
    ldrh    w2, [x0, #2]
    adrp    x0, last_ws@PAGE
    add     x0, x0, last_ws@PAGEOFF
    strh    w1, [x0]
    strh    w2, [x0, #2]
    bl      _compute_layout
    bl      _init_grid

    // Modalità demo: foresta piena + fulmine al centro (anello di fuoco)
    bl      _setup_demo

    // Terminale raw
    bl      _setup_terminal
    cbz     w0, 6f
    bl      _restore_zoom
    adrp    x0, err_term_raw@PAGE
    add     x0, x0, err_term_raw@PAGEOFF
    bl      _printf
    mov     w0, #1
    b       _exit_prog
6:
    // Input non bloccante (rete di sicurezza oltre a VMIN=0)
    // BUG FIX: fcntl è VARIADICA → O_NONBLOCK va sullo STACK, non in x2!
    sub     sp, sp, #16
    mov     x8, #O_NONBLOCK
    str     x8, [sp]
    mov     w0, #0
    mov     w1, #F_SETFL
    bl      _fcntl
    add     sp, sp, #16
    cmp     w0, #0
    b.ge    7f
    bl      _restore_zoom
    adrp    x0, err_fcntl@PAGE
    add     x0, x0, err_fcntl@PAGEOFF
    bl      _printf
    mov     w0, #1
    b       _exit_prog
7:
    // Handler segnali: uscita pulita anche con SIGINT/SIGTERM
    mov     w0, #SIGINT
    adrp    x1, _sig_handler@PAGE
    add     x1, x1, _sig_handler@PAGEOFF
    bl      _signal
    mov     w0, #SIGTERM
    adrp    x1, _sig_handler@PAGE
    add     x1, x1, _sig_handler@PAGEOFF
    bl      _signal

    // Alternate screen + nascondi cursore + pulisci
    adrp    x0, ansi_alt_on@PAGE
    add     x0, x0, ansi_alt_on@PAGEOFF
    mov     w1, #LEN_ALT_ON
    bl      _write_str
    adrp    x0, ansi_hide_cursor@PAGE
    add     x0, x0, ansi_hide_cursor@PAGEOFF
    mov     w1, #LEN_HIDE_CURSOR
    bl      _write_str
    adrp    x0, ansi_clear@PAGE
    add     x0, x0, ansi_clear@PAGEOFF
    mov     w1, #LEN_CLEAR
    bl      _write_str

    // Paint iniziale del tabellone fisso
    bl      _paint_grid

// ============================================================
// MAIN LOOP
// ============================================================
main_loop:
    bl      _handle_input
    adrp    x0, running@PAGE
    add     x0, x0, running@PAGEOFF
    ldr     w0, [x0]
    cbz     w0, main_exit

    // Rileva resize del terminale → riadatta layout e ripaint
    bl      _query_term_size
    adrp    x0, ws_row@PAGE
    add     x0, x0, ws_row@PAGEOFF
    ldrh    w1, [x0]
    ldrh    w2, [x0, #2]
    adrp    x0, last_ws@PAGE
    add     x0, x0, last_ws@PAGEOFF
    ldrh    w3, [x0]
    ldrh    w4, [x0, #2]
    cmp     w1, w3
    cset    w5, ne
    cmp     w2, w4
    cset    w6, ne
    orr     w5, w5, w6
    cbz     w5, ml_no_resize
    adrp    x0, last_ws@PAGE
    add     x0, x0, last_ws@PAGEOFF
    strh    w1, [x0]
    strh    w2, [x0, #2]
    bl      _compute_layout
    bl      _init_grid
    adrp    x0, ansi_clear@PAGE
    add     x0, x0, ansi_clear@PAGEOFF
    mov     w1, #LEN_CLEAR
    bl      _write_str
    bl      _paint_grid

ml_no_resize:
    // Pausa?
    adrp    x0, paused@PAGE
    add     x0, x0, paused@PAGEOFF
    ldr     w0, [x0]
    cbnz    w0, ml_render

    // Fuoco attivo? → solo propagazione (niente crescita/fulmini)
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    ldr     w0, [x0]
    cbnz    w0, ml_fire

    // Nessun fuoco: crescita alberi + tentativo fulmine
    bl      _grow_trees
    bl      _try_lightning
    b       ml_render

ml_fire:
    // _spread_fire_step ritorna le celle BURNING+BURNED residue:
    // 0 → tutto bruciato e ripulito → fuoco spento
    bl      _spread_fire_step
    cbnz    w0, ml_render
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    str     wzr, [x0]

ml_render:
    // Aggiornamento incrementale (solo celle cambiate) + status
    bl      _update_changes
    bl      _print_status_bar
    adrp    x0, frame_delay@PAGE
    add     x0, x0, frame_delay@PAGEOFF
    ldr     w0, [x0]
    bl      _usleep
    b       main_loop

main_exit:
    // Esci dall'alternate screen e ripristina il terminale
    adrp    x0, ansi_show_cursor@PAGE
    add     x0, x0, ansi_show_cursor@PAGEOFF
    mov     w1, #LEN_SHOW_CURSOR
    bl      _write_str
    adrp    x0, ansi_reset@PAGE
    add     x0, x0, ansi_reset@PAGEOFF
    mov     w1, #LEN_RESET
    bl      _write_str
    adrp    x0, ansi_alt_off@PAGE
    add     x0, x0, ansi_alt_off@PAGEOFF
    mov     w1, #LEN_ALT_OFF
    bl      _write_str

    bl      _restore_terminal
    cbz     w0, 1f
    adrp    x0, err_term_restore@PAGE
    add     x0, x0, err_term_restore@PAGEOFF
    bl      _printf
1:
    // Ripristina lo zoom SOLO se lo shrink era riuscito
    bl      _restore_zoom
    // Se l'attesa zoom manuale era stata attiva, ricorda di
    // riportare il terminale alla dimensione originale.
    adrp    x0, wait_was_active@PAGE
    add     x0, x0, wait_was_active@PAGEOFF
    ldr     w1, [x0]
    cbz     w1, 2f
    adrp    x0, msg_restore_zoom@PAGE
    add     x0, x0, msg_restore_zoom@PAGEOFF
    bl      _printf
2:
    mov     w0, #0

_exit_prog:
    ldp     x20, x19, [sp], #16
    ldp     x22, x21, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _sig_handler — Imposta running=0 (usato da SIGINT/SIGTERM)
// ------------------------------------------------------------
_sig_handler:
    adrp    x0, running@PAGE
    add     x0, x0, running@PAGEOFF
    str     wzr, [x0]
    ret

// ------------------------------------------------------------
// _setup_zoom — Scrive l'OSC kitty-cmd di shrink (-12) se siamo
// dentro kitty (KITTY_WINDOW_ID settata) e zoom non disabilitato.
// ------------------------------------------------------------
_setup_zoom:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adrp    x0, env_kitty_window@PAGE
    add     x0, x0, env_kitty_window@PAGEOFF
    bl      _getenv
    cbz     x0, sz_done             // non siamo in kitty → niente zoom
    adrp    x0, zoom_shrink_osc@PAGE
    add     x0, x0, zoom_shrink_osc@PAGEOFF
    bl      _strlen
    mov     w1, w0
    adrp    x0, zoom_shrink_osc@PAGE
    add     x0, x0, zoom_shrink_osc@PAGEOFF
    bl      _write_str
    adrp    x0, zoom_active@PAGE
    add     x0, x0, zoom_active@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
sz_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _restore_zoom — Ripristina +12 pt se zoom_active
// ------------------------------------------------------------
_restore_zoom:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adrp    x0, zoom_active@PAGE
    add     x0, x0, zoom_active@PAGEOFF
    ldr     w1, [x0]
    cbz     w1, rz_done
    adrp    x0, zoom_restore_osc@PAGE
    add     x0, x0, zoom_restore_osc@PAGEOFF
    bl      _strlen
    mov     w1, w0
    adrp    x0, zoom_restore_osc@PAGE
    add     x0, x0, zoom_restore_osc@PAGEOFF
    bl      _write_str
rz_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _strlen — x0 = stringa NUL-terminata → w0 = lunghezza
// ------------------------------------------------------------
_strlen:
    mov     w1, #0
1:  ldrb    w2, [x0, w1, uxtw]
    cbz     w2, 2f
    add     w1, w1, #1
    b       1b
2:  mov     w0, w1
    ret

// ------------------------------------------------------------
// _print_help — Stampa l'uso del programma (-h / --help) ed esce.
// Chiamata PRIMA della configurazione del terminale: niente da
// ripristinare, basta stampare e tornare (il runtime fa exit(0)).
// ------------------------------------------------------------
_print_help:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adrp    x0, msg_help@PAGE
    add     x0, x0, msg_help@PAGEOFF
    bl      _printf
    mov     w0, #0
    bl      _fflush
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _str_eq — Confronta due stringhe NUL-terminate (x0, x1)
// Ritorna: w0 = 1 se uguali, 0 altrimenti
// ------------------------------------------------------------
_str_eq:
    mov     w2, #0
1:  ldrb    w3, [x0, w2, uxtw]
    ldrb    w4, [x1, w2, uxtw]
    cmp     w3, w4
    b.ne    2f
    cbz     w3, 3f
    add     w2, w2, #1
    b       1b
2:  mov     w0, #0
    ret
3:  mov     w0, #1
    ret

// ------------------------------------------------------------
// _write_str — Scrive una stringa ANSI su stdout
// x0 = indirizzo, w1 = lunghezza
// ------------------------------------------------------------
_write_str:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x2, x1
    mov     x1, x0
    mov     w0, #1
    bl      _write
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _setup_terminal — Raw mode. w0 = 0 successo
// ------------------------------------------------------------
_setup_terminal:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     w0, #0
    adrp    x1, old_termios@PAGE
    add     x1, x1, old_termios@PAGEOFF
    bl      _tcgetattr
    cbnz    w0, st_fail

    adrp    x0, old_termios@PAGE
    add     x0, x0, old_termios@PAGEOFF
    adrp    x1, new_termios@PAGE
    add     x1, x1, new_termios@PAGEOFF
    mov     w2, #80
    bl      _memcpy

    // c_lflag a offset 24 (tcflag_t = 8 byte su arm64):
    // togli ICANON, ECHO, ISIG
    adrp    x0, new_termios@PAGE
    add     x0, x0, new_termios@PAGEOFF
    ldr     x1, [x0, #24]
    mov     x2, #(ICANON | ECHO | ISIG)
    bic     x1, x1, x2
    str     x1, [x0, #24]

    // VMIN = 0 (offset 48), VTIME = 0 (offset 49)
    mov     w1, #0
    strb    w1, [x0, #48]
    strb    w1, [x0, #49]

    mov     w0, #0
    mov     w1, #TCSANOW
    adrp    x2, new_termios@PAGE
    add     x2, x2, new_termios@PAGEOFF
    bl      _tcsetattr
    cbz     w0, st_ok

st_fail:
    mov     w0, #1
    b       st_end
st_ok:
    mov     w0, #0
st_end:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _restore_terminal — w0 = 0 successo
// ------------------------------------------------------------
_restore_terminal:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     w0, #0
    mov     w1, #TCSANOW
    adrp    x2, old_termios@PAGE
    add     x2, x2, old_termios@PAGEOFF
    bl      _tcsetattr
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _query_term_size — ioctl TIOCGWINSZ su stdin.
// Scrive ws_row/ws_col; se fallisce usa default 50×80.
// ------------------------------------------------------------
_query_term_size:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    // BUG FIX macOS ARM64: ioctl è VARIADICA → il terzo argomento
    // (il puntatore a winsize) va sullo STACK, NON in x2!
    // Prima versione: ioctl "riusciva" (ret 0) ma scriveva rows=0 cols=0.
    sub     sp, sp, #16
    adrp    x8, winsize_buf@PAGE
    add     x8, x8, winsize_buf@PAGEOFF
    str     x8, [sp]
    mov     w0, #0                  // stdin
    mov     w1, #0x7468
    movk    w1, #0x4008, lsl #16    // TIOCGWINSZ
    bl      _ioctl
    add     sp, sp, #16
    cbnz    w0, qts_fail
    adrp    x2, winsize_buf@PAGE
    add     x2, x2, winsize_buf@PAGEOFF
    ldrh    w3, [x2]                // rows
    ldrh    w4, [x2, #2]            // cols
    cmp     w3, #4
    b.lo    qts_fail
    cmp     w4, #2
    b.lo    qts_fail
    b       qts_store
qts_fail:
    mov     w3, #50
    mov     w4, #80
qts_store:
    adrp    x2, ws_row@PAGE
    add     x2, x2, ws_row@PAGEOFF
    strh    w3, [x2]
    strh    w4, [x2, #2]
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _compute_layout — Da ws_row/ws_col calcola la griglia con
// MEZZI-BLOCCHI (▀): ogni carattere disegna 2 celle (alto/basso),
// così le celle risultano ~QUADRATE (il carattere è alto il doppio)
// e la griglia arriva al doppio delle righe di celle.
// size = min(request 128..512, 2*(rows-4), cols-3) arrotondato a PARI.
// (2 righe per il bordo + 2 per la status bar; 2 colonne bordo + 1 margine)
// ------------------------------------------------------------
_compute_layout:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x20, x19, [sp, #-16]!

    adrp    x0, ws_row@PAGE
    add     x0, x0, ws_row@PAGEOFF
    ldrh    w19, [x0]               // rows
    ldrh    w20, [x0, #2]           // cols

    sub     w1, w19, #4
    lsl     w1, w1, #1              // 2*(rows-4) = righe di celle possibili
    adrp    x0, grid_size_request@PAGE
    add     x0, x0, grid_size_request@PAGEOFF
    ldr     w2, [x0]                // dimensione richiesta (--size, default 128)
    cmp     w2, w1
    csel    w2, w1, w2, hi          // w2 = min(request, 2*(rows-4))
    sub     w3, w20, #3
    cmp     w2, w3
    csel    w2, w3, w2, hi          // w2 = min(w2, cols-3)
    bic     w2, w2, #1              // arrotonda a pari (mezzo-blocchi)
    cmp     w2, #2
    b.hs    1f
    mov     w2, #2
1:
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    str     w2, [x0]
    mul     w3, w2, w2
    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    str     w3, [x0]

    // top_pad = (rows - 4 - size/2) / 2   (righe vuote sopra il bordo)
    lsr     w4, w2, #1
    sub     w5, w19, #4
    sub     w5, w5, w4
    lsr     w5, w5, #1
    adrp    x0, top_pad@PAGE
    add     x0, x0, top_pad@PAGEOFF
    str     w5, [x0]
    // left_pad = (cols - size - 2) / 2    (colonne vuote a sinistra del bordo)
    sub     w6, w20, w2
    sub     w6, w6, #2
    lsr     w6, w6, #1
    adrp    x0, left_pad@PAGE
    add     x0, x0, left_pad@PAGEOFF
    str     w6, [x0]

    ldp     x20, x19, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _init_grid — Azzera grid, new_grid e prev_grid (tutto EMPTY)
// ------------------------------------------------------------
_init_grid:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    ldr     w1, [x0]
    adrp    x0, grid@PAGE
    add     x0, x0, grid@PAGEOFF
    bl      _zero_area
    adrp    x0, new_grid@PAGE
    add     x0, x0, new_grid@PAGEOFF
    adrp    x1, grid_area@PAGE
    add     x1, x1, grid_area@PAGEOFF
    ldr     w1, [x1]
    bl      _zero_area
    adrp    x0, prev_grid@PAGE
    add     x0, x0, prev_grid@PAGEOFF
    adrp    x1, grid_area@PAGE
    add     x1, x1, grid_area@PAGEOFF
    ldr     w1, [x1]
    bl      _zero_area
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _zero_area — x0 = base, w1 = byte count: scrive 0
// ------------------------------------------------------------
_zero_area:
    cbz     w1, 1f
2:  sub     w1, w1, #1
    strb    wzr, [x0, w1, uxtw]
    cbnz    w1, 2b
1:  ret

// ------------------------------------------------------------
// _setup_demo — Modalità --demo: riempie la griglia di alberi
// e mette il fulmine AL CENTRO (anello di fuoco verso i bordi).
// Dopo l'incendio il loop normale riprende (crescita + fulmini).
// ------------------------------------------------------------
_setup_demo:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    adrp    x0, demo_mode@PAGE
    add     x0, x0, demo_mode@PAGEOFF
    ldr     w0, [x0]
    cbz     w0, sd_done

    // Riempi tutta la griglia di alberi
    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    ldr     w1, [x0]
    adrp    x0, grid@PAGE
    add     x0, x0, grid@PAGEOFF
1:  sub     w1, w1, #1
    mov     w2, #CELL_TREE
    strb    w2, [x0, w1, uxtw]
    cbnz    w1, 1b

    // Fulmine al centro: idx = (size/2)*size + size/2
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w1, [x0]
    lsr     w2, w1, #1              // size/2
    mul     w3, w2, w1
    add     w3, w3, w2              // indice centro
    adrp    x0, grid@PAGE
    add     x0, x0, grid@PAGEOFF
    mov     w4, #CELL_BURNING
    strb    w4, [x0, w3, uxtw]

    // Attiva il fuoco
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
sd_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _get_prng_seed — Seed PRNG con time() + indirizzo stack
// ------------------------------------------------------------
_get_prng_seed:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x20, x19, [sp, #-16]!
    // Seed = time() XOR pid XOR indirizzo stack (ASLR varia a ogni run)
    mov     w0, #0
    bl      _time
    mov     w19, w0
    bl      _getpid
    eor     w19, w19, w0
    mov     x20, sp
    eor     x0, x19, x20
    lsl     x1, x0, #17
    eor     x0, x0, x1
    lsr     x1, x0, #31
    eor     x0, x0, x1
    mov     w0, w0
    cbnz    w0, 1f
    mov     w0, #1
1:
    adrp    x1, prng_state@PAGE
    add     x1, x1, prng_state@PAGEOFF
    str     w0, [x1]
    ldp     x20, x19, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _xorshift32 — PRNG. Ritorna w0 = random
// ------------------------------------------------------------
_xorshift32:
    adrp    x1, prng_state@PAGE
    add     x1, x1, prng_state@PAGEOFF
    ldr     w0, [x1]
    lsl     w2, w0, #13
    eor     w0, w0, w2
    lsr     w2, w0, #17
    eor     w0, w0, w2
    lsl     w2, w0, #5
    eor     w0, w0, w2
    str     w0, [x1]
    ret

// ------------------------------------------------------------
// _update_thresholds — Ricalcola le soglie 32-bit dagli slider
// (1..100) e dal frame_delay corrente. NB: i tasti [ ] (velocità)
// NON ricalcolano le soglie → accelerano TUTTO insieme (crescita,
// fulmini e fuoco), che è il comportamento voluto.
//   fps = 1000000 / frame_delay
//   SCALE QUADRATICHE (s²) ancorate a s=40 (= valore precedente):
//   alberi:  threshold32 = s² * 38516 / fps
//            → 40 invariato (~3.5 min), 100 = 6.25× (~33s), 1 ≈ fermo
//   fulmini: threshold32 = s² * 2147484 / fps  (2147484 ≈ 2^31/1000)
//            → 40 invariato (~1 ogni 2.5s), 100 = 6.25× (≥4× richiesto)
// ------------------------------------------------------------
_update_thresholds:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #16

    // fps = 1000000 / frame_delay
    adrp    x0, frame_delay@PAGE
    add     x0, x0, frame_delay@PAGEOFF
    ldr     w1, [x0]
    movz    w0, #0x4240
    movk    w0, #0x000F, lsl #16    // 1000000
    udiv    w2, w0, w1              // w2 = fps (≥5, mai 0)
    str     w2, [sp]                // salva fps

    // --- Alberi: threshold32 = s² * 38516 / fps (quadratica) ---
    // Ancorata a s=40 = valore precedente (~3.5 min); 100 → 6.25×
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    ldr     w3, [x0]                // s
    movz    w4, #0x9674             // 38516
    sxtw    x4, w4
    sxtw    x3, w3
    mul     x5, x3, x3              // s²
    mul     x5, x5, x4              // s² * 38516 (≤ 3.9e8)
    ldr     w2, [sp]                // fps
    sxtw    x2, w2
    udiv    x5, x5, x2
    cmp     x5, #1
    b.hs    1f
    mov     x5, #1
1:
    adrp    x0, tree_threshold@PAGE
    add     x0, x0, tree_threshold@PAGEOFF
    str     w5, [x0]

    // --- Fulmini: threshold32 = s² * 2147484 / fps (quadratica) ---
    // 2147484 ≈ 2^31/1000; ancorata a s=40 = valore precedente,
    // a 100 → (100/40)² = 6.25× (≥4× richiesto dall'utente)
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    ldr     w3, [x0]                // s
    movz    w4, #0xC49C
    movk    w4, #0x0020, lsl #16    // 2147484 ≈ 2^31/1000
    sxtw    x4, w4
    sxtw    x3, w3
    mul     x5, x3, x3              // s²
    mul     x5, x5, x4              // s² * 2147484 (≤ 2.2e13)
    ldr     w2, [sp]                // fps
    sxtw    x2, w2
    udiv    x5, x5, x2
    cmp     x5, #1
    b.hs    2f
    mov     x5, #1
2:
    adrp    x0, lightning_threshold@PAGE
    add     x0, x0, lightning_threshold@PAGEOFF
    str     w5, [x0]

    add     sp, sp, #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _wait_for_terminal — Attende che il terminale sia grande
// abbastanza per la board richiesta (grid_size_request):
// servono cols ≥ size+3 e rows ≥ size/2+4. Se non entra,
// stampa un hint corto ("Rimpicciolisci un po' il testo (Cmd−)..."
// in viola, senza numeri) e ricontrolla da solo ogni mezzo
// secondo: appena entra, si parte.
// ------------------------------------------------------------
_wait_for_terminal:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
wft_loop:
    bl      _query_term_size
    adrp    x0, grid_size_request@PAGE
    add     x0, x0, grid_size_request@PAGEOFF
    ldr     w1, [x0]                // req
    lsr     w2, w1, #1
    add     w2, w2, #4              // righe minime
    add     w3, w1, #3              // colonne minime
    adrp    x0, ws_row@PAGE
    add     x0, x0, ws_row@PAGEOFF
    ldrh    w4, [x0]                // rows
    ldrh    w5, [x0, #2]            // cols
    cmp     w4, w2
    b.lo    wft_msg
    cmp     w5, w3
    b.hs    wft_done
wft_msg:
    // Nessun varargs: basta il puntatore al formato.
    adrp    x0, msg_wait_fmt@PAGE
    add     x0, x0, msg_wait_fmt@PAGEOFF
    bl      _printf
    mov     w0, #0
    bl      _fflush
    adrp    x0, wait_was_active@PAGE
    add     x0, x0, wait_was_active@PAGEOFF
    mov     w1, #1
    str     w1, [x0]
    movz    w0, #0xA120
    movk    w0, #0x0007, lsl #16    // 500000 µs = 0.5s
    bl      _usleep
    b       wft_loop
wft_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _has_tree_neighbor — w0 = indice cella, x19 = base grid.
// Ritorna w0 = 1 se una delle 8 celle adiacenti è CELL_TREE.
// (Usato da _grow_trees per il bonus di clustering.)
// ------------------------------------------------------------
_has_tree_neighbor:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     w10, w0                 // indice cella (persistente)
    adrp    x1, grid_size@PAGE
    add     x1, x1, grid_size@PAGEOFF
    ldr     w1, [x1]                // size
    udiv    w2, w10, w1             // y
    msub    w3, w2, w1, w10         // x
    sub     w9, w1, #1              // size-1
    // N
    cbz     w2, htn_e
    sub     w11, w10, w1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_e:
    // E
    cmp     w3, w9
    b.hs    htn_s
    add     w11, w10, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_s:
    // S
    cmp     w2, w9
    b.hs    htn_w
    add     w11, w10, w1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_w:
    // W
    cbz     w3, htn_ne
    sub     w11, w10, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_ne:
    // NE
    cbz     w2, htn_se
    cmp     w3, w9
    b.hs    htn_se
    sub     w11, w10, w1
    add     w11, w11, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_se:
    // SE
    cmp     w2, w9
    b.hs    htn_sw
    cmp     w3, w9
    b.hs    htn_sw
    add     w11, w10, w1
    add     w11, w11, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_sw:
    // SW
    cmp     w2, w9
    b.hs    htn_nw
    cbz     w3, htn_nw
    add     w11, w10, w1
    sub     w11, w11, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_nw:
    // NW
    cbz     w2, htn_no
    cbz     w3, htn_no
    sub     w11, w10, w1
    sub     w11, w11, #1
    ldrb    w4, [x19, w11, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    htn_yes
htn_no:
    mov     w0, #0
    b       htn_done
htn_yes:
    mov     w0, #1
htn_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _grow_trees — Ogni cella EMPTY ha probabilità tree_threshold/2^32
// di diventare TREE (la cenere deve prima sfumare a EMPTY); se la
// cella è ADIACENTE (8 direzioni) a un albero, la soglia sale di
// CLUSTER_BONUS (+0.05% assoluti) → piccoli cluster nel tempo.
// ------------------------------------------------------------
_grow_trees:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x20, x19, [sp, #-16]!

    adrp    x19, grid@PAGE
    add     x19, x19, grid@PAGEOFF
    adrp    x20, tree_threshold@PAGE
    add     x20, x20, tree_threshold@PAGEOFF
    ldr     w20, [x20]

    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    ldr     w0, [x0]
1:
    sub     w0, w0, #1
    ldrb    w1, [x19, w0, uxtw]
    cmp     w1, #CELL_EMPTY
    b.ne    3f
2:
    stp     x0, x1, [sp, #-16]!     // salva indice (e x1) su stack
    bl      _has_tree_neighbor       // w0 = 1 se adiacente a un TREE
    mov     w2, w0                   // w2 = adiacente?
    mov     w3, w20
    cbz     w2, 4f
    movz    w4, #0xC49C
    movk    w4, #0x0020, lsl #16     // CLUSTER_BONUS = 0x20C49C (+0.05%)
    add     w3, w3, w4               // soglia effettiva
4:
    bl      _xorshift32
    mov     w2, w0                   // conserva il random
    ldp     x0, x1, [sp], #16        // ripristina l'indice
    cmp     w2, w3                   // soglia effettiva 32-bit
    b.hs    3f
    mov     w1, #CELL_TREE
    strb    w1, [x19, w0, uxtw]
3:
    cbnz    w0, 1b

    ldp     x20, x19, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _try_lightning — Tenta un fulmine su una cella TREE casuale
// ------------------------------------------------------------
_try_lightning:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Cooldown: massimo 1 fulmine ogni LIGHTNING_COOLDOWN frame
    adrp    x0, lightning_cooldown_counter@PAGE
    add     x0, x0, lightning_cooldown_counter@PAGEOFF
    ldr     w1, [x0]
    cbz     w1, lt_go
    sub     w1, w1, #1
    str     w1, [x0]
    b       lt_done
lt_go:
    mov     w1, #LIGHTNING_COOLDOWN
    str     w1, [x0]

    // Ricerca cella: ritenta fino a LIGHTNING_RETRIES volte finché non
    // trova un TREE. Così la frequenza dei fulmini NON dipende dalla
    // densità della foresta (slider 100 ≈ 1 fulmine ogni 2s anche con
    // foresta rada). Con foresta quasi vuota (pochi alberi in giro) i
    // fulmini restano comunque più rari, come nella realtà.
    adrp    x12, grid@PAGE
    add     x12, x12, grid@PAGEOFF   // base grid (persiste nel loop)
    mov     w13, #0                  // tentativi fatti
lt_retry:
    bl      _xorshift32
    lsr     w0, w0, #8              // usa i bit ALTI (bit bassi piu' deboli)
    adrp    x1, grid_area@PAGE
    add     x1, x1, grid_area@PAGEOFF
    ldr     w1, [x1]
    udiv    w2, w0, w1
    msub    w3, w2, w1, w0          // w3 = random % grid_area (cella casuale)
    ldrb    w4, [x12, w3, uxtw]
    cmp     w4, #CELL_TREE
    b.eq    lt_found
    add     w13, w13, #1
    cmp     w13, #LIGHTNING_RETRIES
    b.lo    lt_retry
    b       lt_done                  // foresta troppo rada: niente fulmine

lt_found:
    // È un albero: probabilità fulmine (soglia 32-bit)
    bl      _xorshift32
    adrp    x1, lightning_threshold@PAGE
    add     x1, x1, lightning_threshold@PAGEOFF
    ldr     w1, [x1]
    cmp     w0, w1
    b.hs    lt_done

    // FULMINE! La cella diventa BURNING e si attiva il fuoco
    mov     w1, #CELL_BURNING
    strb    w1, [x12, w3, uxtw]
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    mov     w1, #1
    str     w1, [x0]

lt_done:
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _spread_fire_step — Propaga il fuoco di un passo (double buffer)
//   BURNING → cenere fresca (ASH_0) ; cenere → stadio+1 → EMPTY
//     (le braci sfumano in ASH_LAST-ASH_0+1 frame ≈ 0.27s)
//   TREE con vicino NSEW BURNING (o 8-dir braci) → BURNING
// Ritorna: w0 = celle BURNING+cenere nella NUOVA griglia (0 = spento)
// ------------------------------------------------------------
_spread_fire_step:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x24, x23, [sp, #-16]!
    stp     x22, x21, [sp, #-16]!
    stp     x20, x19, [sp, #-16]!

    adrp    x19, grid@PAGE
    add     x19, x19, grid@PAGEOFF
    adrp    x20, new_grid@PAGE
    add     x20, x20, new_grid@PAGEOFF
    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    ldr     w23, [x0]               // area

    mov     w22, #0                 // contatore BURNING+BURNED
    mov     w21, #0                 // indice cella

sfs_loop:
    ldrb    w0, [x19, w21, uxtw]

    cmp     w0, #CELL_BURNING
    b.eq    sfs_burning
    cmp     w0, #CELL_ASH_0
    b.lo    sfs_check_tree
    cmp     w0, #CELL_ASH_LAST
    b.ls    sfs_ash
sfs_check_tree:
    cmp     w0, #CELL_TREE
    b.ne    sfs_copy

    // BUG FIX CRITICO: _should_ignite sovrascrive w0 con il suo
    // risultato (0/1). Un albero NON infiammato arriverebbe a
    // sfs_copy con w0=0 → scritto come EMPTY (alberi cancellati!).
    // Salviamo lo stato originale (TREE) in w24 prima della chiamata.
    mov     w24, w0
    bl      _should_ignite
    cbz     w0, sfs_copy_tree
    mov     w0, #CELL_BURNING
    strb    w0, [x20, w21, uxtw]
    add     w22, w22, #1
    b       sfs_next

sfs_copy:
    strb    w0, [x20, w21, uxtw]
    b       sfs_next

sfs_copy_tree:
    strb    w24, [x20, w21, uxtw]
    b       sfs_next

sfs_burning:
    mov     w0, #CELL_ASH_0
    strb    w0, [x20, w21, uxtw]
    add     w22, w22, #1
    b       sfs_next

sfs_ash:
    // Braci che si spengono: avanza di uno stadio, poi EMPTY
    cmp     w0, #CELL_ASH_LAST
    b.eq    sfs_ash_out
    add     w0, w0, #1
    strb    w0, [x20, w21, uxtw]
    add     w22, w22, #1            // cenere residua → fuoco ancora attivo
    b       sfs_next
sfs_ash_out:
    mov     w0, #CELL_EMPTY
    strb    w0, [x20, w21, uxtw]
    b       sfs_next

sfs_next:
    add     w21, w21, #1
    cmp     w21, w23
    b.lo    sfs_loop

    // Copia new_grid → grid
    mov     w0, w23
1:  sub     w0, w0, #1
    ldrb    w1, [x20, w0, uxtw]
    strb    w1, [x19, w0, uxtw]
    cbnz    w0, 1b

    mov     w0, w22
    ldp     x20, x19, [sp], #16
    ldp     x22, x21, [sp], #16
    ldp     x24, x23, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _should_ignite — Un TREE prende fuoco se:
//   A) ha un vicino NSEW in BURNING (propagazione diretta)
//   B) ha un vicino (8 direzioni) con stato >= BURNING: BURNED o
//      cenere in QUALSIASI stadio (le braci incendiano → fronte
//      rotondo). NB: stato >= 2 = "che incendia".
// Input: w21 = indice, x19 = grid base
// Ritorna: w0 = 1 se deve bruciare
// ------------------------------------------------------------
_should_ignite:
    mov     w0, w21
    adrp    x1, grid_size@PAGE
    add     x1, x1, grid_size@PAGEOFF
    ldr     w1, [x1]                // size
    udiv    w2, w0, w1              // y
    msub    w3, w2, w1, w0          // x
    sub     w9, w1, #1              // size-1

    // --- Regola A: NSEW in BURNING ---
    cbz     w2, si_a_down
    sub     w0, w0, w1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.eq    si_yes
si_a_down:
    cmp     w2, w9
    b.hs    si_a_left
    add     w0, w21, w1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.eq    si_yes
si_a_left:
    cbz     w3, si_a_right
    sub     w0, w21, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.eq    si_yes
si_a_right:
    cmp     w3, w9
    b.hs    si_b_diag
    add     w0, w21, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.eq    si_yes

    // --- Regola B: 8 direzioni con stato >= BURNING (fuoco o braci) ---
si_b_diag:
    cbz     w2, si_b_ne
    sub     w0, w21, w1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_ne:
    cbz     w2, si_b_e
    cmp     w3, w9
    b.hs    si_b_e
    sub     w0, w21, w1
    add     w0, w0, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_e:
    cmp     w3, w9
    b.hs    si_b_se
    add     w0, w21, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_se:
    cmp     w2, w9
    b.hs    si_b_s
    cmp     w3, w9
    b.hs    si_b_s
    add     w0, w21, w1
    add     w0, w0, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_s:
    cmp     w2, w9
    b.hs    si_b_sw
    add     w0, w21, w1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_sw:
    cmp     w2, w9
    b.hs    si_b_w
    cbz     w3, si_b_w
    add     w0, w21, w1
    sub     w0, w0, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_w:
    cbz     w3, si_b_nw
    sub     w0, w21, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes
si_b_nw:
    cbz     w2, si_no
    cbz     w3, si_no
    sub     w0, w21, w1
    sub     w0, w0, #1
    ldrb    w4, [x19, w0, uxtw]
    cmp     w4, #CELL_BURNING
    b.hs    si_yes

si_no:
    mov     w0, #0
    ret
si_yes:
    mov     w0, #1
    ret

// ------------------------------------------------------------
// _paint_grid — Paint INIZIALE del tabellone fisso.
// Disegna il BORDO box-drawing (┌─┐│└┘) e le righe della griglia
// con MEZZI-BLOCCHI: ogni carattere ▀ = 2 celle. ▀ disegna il
// PRIMO PIANO nella meta' SUPERIORE e lo sfondo in quella INFERIORE,
// quindi: riga pari della coppia → PRIMO PIANO, riga dispari →
// SFONDO. (Fix flip: prima erano scambiati → righe capovolte a
// coppie.) Niente newline → niente scroll.
// ------------------------------------------------------------
_paint_grid:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x24, x23, [sp, #-16]!
    stp     x22, x21, [sp, #-16]!
    stp     x20, x19, [sp, #-16]!
    sub     sp, sp, #32

    adrp    x19, grid@PAGE
    add     x19, x19, grid@PAGEOFF
    adrp    x20, row_buffer@PAGE
    add     x20, x20, row_buffer@PAGEOFF
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w21, [x0]               // size
    adrp    x0, top_pad@PAGE
    add     x0, x0, top_pad@PAGEOFF
    ldr     w22, [x0]               // top_pad
    adrp    x0, left_pad@PAGE
    add     x0, x0, left_pad@PAGEOFF
    ldr     w23, [x0]               // left_pad

    // ---- Bordo superiore: ┌ ─×size ┐ ----
    // NB: il clang IAS scarta le istruzioni dopo ';' → ogni
    // istruzione su una riga propria (o via helper _emit_box).
    mov     x25, x20
    add     w0, w22, #1
    add     w1, w23, #1
    bl      _emit_csi_pos
    adrp    x0, color_border@PAGE
    add     x0, x0, color_border@PAGEOFF
    bl      _emit_cstr
    mov     w0, #0x8C
    bl      _emit_box                // ┌
    mov     w10, w21
1:  mov     w0, #0x80
    bl      _emit_box                // ─
    sub     w10, w10, #1
    cbnz    w10, 1b
    mov     w0, #0x90
    bl      _emit_box                // ┐
    bl      _buf_flush

    // ---- Righe della griglia (mezzo-blocchi) ----
    mov     w24, #0                 // r (riga testo)
pg_row:
    lsr     w9, w21, #1             // righe testo = size/2
    cmp     w24, w9
    b.hs    pg_border_bottom
    mov     x25, x20
    add     w0, w24, #1
    add     w0, w0, w22
    add     w0, w0, #1              // + bordo superiore
    add     w1, w23, #1
    add     w1, w1, #1              // + bordo sinistro
    bl      _emit_csi_pos
    lsl     w9, w24, #1             // 2r
    mul     w9, w9, w21
    str     w9, [sp]                // row_start top
    add     w9, w9, w21
    str     w9, [sp, #8]            // row_start bot
    mov     w26, #-1                // last_top
    mov     w0, #-1
    str     w0, [sp, #16]           // last_bot
    str     wzr, [sp, #24]          // c = 0
pg_col:
    ldr     w10, [sp, #24]
    cmp     w10, w21
    b.hs    pg_row_end
    ldr     w9, [sp]
    add     w9, w9, w10
    ldrb    w4, [x19, w9, uxtw]     // top (riga pari → PRIMO PIANO)
    ldr     w9, [sp, #8]
    add     w9, w9, w10
    ldrb    w6, [x19, w9, uxtw]     // bot (riga dispari → SFONDO)
    cmp     w4, w26
    b.eq    pg_bot
    mov     w26, w4
    bl      _emit_fg_color
pg_bot:
    ldr     w8, [sp, #16]
    cmp     w6, w8
    b.eq    pg_char
    str     w6, [sp, #16]
    mov     w4, w6
    bl      _emit_bg_color
pg_char:
    bl      _emit_half
    ldr     w10, [sp, #24]
    add     w10, w10, #1
    str     w10, [sp, #24]
    b       pg_col
pg_row_end:
    // BUG FIX nero a destra: ESC[0m PRIMA di ESC[K, altrimenti
    // ESC[K cancella il resto della riga col colore dell'ultima
    // cella (spesso nero) → fascia nera a destra del tabellone.
    // Con ESC[0m cancella col colore di default (trasparente).
    mov     w11, #27
    strb    w11, [x25], #1
    mov     w11, #'['
    strb    w11, [x25], #1
    mov     w11, #'0'
    strb    w11, [x25], #1
    mov     w11, #'m'
    strb    w11, [x25], #1
    mov     w11, #27
    strb    w11, [x25], #1
    mov     w11, #'['
    strb    w11, [x25], #1
    mov     w11, #'K'
    strb    w11, [x25], #1
    bl      _buf_flush
    add     w24, w24, #1
    b       pg_row

pg_border_bottom:
    // ---- Bordo inferiore: └ ─×size ┘ ----
    mov     x25, x20
    lsr     w9, w21, #1
    add     w0, w22, #1
    add     w0, w0, w9
    add     w0, w0, #1
    add     w1, w23, #1
    bl      _emit_csi_pos
    adrp    x0, color_border@PAGE
    add     x0, x0, color_border@PAGEOFF
    bl      _emit_cstr
    mov     w0, #0x94
    bl      _emit_box                // └
    mov     w10, w21
1:  mov     w0, #0x80
    bl      _emit_box                // ─
    sub     w10, w10, #1
    cbnz    w10, 1b
    mov     w0, #0x98
    bl      _emit_box                // ┘
    bl      _buf_flush

    // ---- Bordi laterali: │ a sinistra e destra ----
    mov     w24, #0
pg_side:
    lsr     w9, w21, #1
    cmp     w24, w9
    b.hs    pg_done
    // sinistra
    mov     x25, x20
    add     w0, w24, #1
    add     w0, w0, w22
    add     w0, w0, #1
    add     w1, w23, #1
    bl      _emit_csi_pos
    adrp    x0, color_border@PAGE
    add     x0, x0, color_border@PAGEOFF
    bl      _emit_cstr
    mov     w0, #0x82
    bl      _emit_box                // │
    bl      _buf_flush
    // destra
    mov     x25, x20
    add     w0, w24, #1
    add     w0, w0, w22
    add     w0, w0, #1
    add     w1, w23, #1
    add     w1, w1, w21
    add     w1, w1, #1
    bl      _emit_csi_pos
    adrp    x0, color_border@PAGE
    add     x0, x0, color_border@PAGEOFF
    bl      _emit_cstr
    mov     w0, #0x82
    bl      _emit_box                // │
    bl      _buf_flush
    add     w24, w24, #1
    b       pg_side

pg_done:
    add     sp, sp, #32
    ldp     x20, x19, [sp], #16
    ldp     x22, x21, [sp], #16
    ldp     x24, x23, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _update_changes — Diff grid vs prev_grid a livello di CARATTERE
// (2 celle per carattere ▀). Emette SOLO i caratteri cambiati:
// CSI pos + fg(top, riga pari) + bg(bot, riga dispari) + ▀.
// Poi copia grid → prev_grid e aggiorna i contatori tree/burning.
// ------------------------------------------------------------
_update_changes:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x28, x27, [sp, #-16]!
    stp     x26, x25, [sp, #-16]!
    stp     x24, x23, [sp, #-16]!
    stp     x22, x21, [sp, #-16]!
    stp     x20, x19, [sp, #-16]!
    sub     sp, sp, #64
    // [sp]=c, [sp+8]=row_changed, [sp+16]=last_bot,
    // [sp+24]=top salvato, [sp+32]=bot salvato,
    // [sp+40]=row_start_top, [sp+48]=row_start_bot

    adrp    x19, grid@PAGE
    add     x19, x19, grid@PAGEOFF
    adrp    x20, prev_grid@PAGE
    add     x20, x20, prev_grid@PAGEOFF
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w21, [x0]               // size
    adrp    x0, top_pad@PAGE
    add     x0, x0, top_pad@PAGEOFF
    ldr     w22, [x0]
    adrp    x0, left_pad@PAGE
    add     x0, x0, left_pad@PAGEOFF
    ldr     w23, [x0]

    mov     w27, #0                 // tree count
    mov     w28, #0                 // burning count
    mov     w26, #-1                // last_top
    mov     w0, #-1
    str     w0, [sp, #16]           // last_bot
    adrp    x0, row_buffer@PAGE
    add     x25, x0, row_buffer@PAGEOFF

    mov     w24, #0                 // r (riga testo)
uc_row:
    lsr     w9, w21, #1             // righe testo = size/2
    cmp     w24, w9
    b.hs    uc_done
    str     wzr, [sp, #8]           // row_changed = 0
    str     wzr, [sp]               // c = 0
    lsl     w9, w24, #1             // 2r
    mul     w9, w9, w21
    str     w9, [sp, #40]           // row_start_top
    add     w9, w9, w21
    str     w9, [sp, #48]           // row_start_bot

uc_cell:
    ldr     w8, [sp]                // c
    ldr     w9, [sp, #40]
    add     w9, w9, w8              // idx_top
    ldrb    w4, [x19, w9, uxtw]     // top
    ldrb    w5, [x20, w9, uxtw]     // prev_top
    ldr     w10, [sp, #48]
    add     w10, w10, w8            // idx_bot
    ldrb    w6, [x19, w10, uxtw]    // bot
    ldrb    w7, [x20, w10, uxtw]    // prev_bot

    // Contatori: top
    cmp     w4, #CELL_TREE
    b.ne    1f
    add     w27, w27, #1
    b       2f
1:  cmp     w4, #CELL_BURNING
    b.ne    2f
    add     w28, w28, #1
2:  // Contatori: bot
    cmp     w6, #CELL_TREE
    b.ne    3f
    add     w27, w27, #1
    b       4f
3:  cmp     w6, #CELL_BURNING
    b.ne    4f
    add     w28, w28, #1
4:
    // Carattere cambiato? (top O bot diversi da prev)
    cmp     w4, w5
    b.ne    uc_changed
    cmp     w6, w7
    b.eq    uc_next

uc_changed:
    // Gli emit clobberano w4/w6 → salvali (servono per i colori)
    str     w4, [sp, #24]
    str     w6, [sp, #32]
    ldr     w8, [sp]                // c
    ldr     w9, [sp, #8]            // row_changed
    cbnz    w9, uc_same_row
    add     w0, w24, #1
    add     w0, w0, w22
    add     w0, w0, #1              // + bordo superiore
    add     w1, w8, #1
    add     w1, w1, w23
    add     w1, w1, #1              // + bordo sinistro
    bl      _emit_csi_pos
    mov     w9, #1
    str     w9, [sp, #8]
    b       uc_emit_colors
uc_same_row:
    add     w1, w8, #1
    add     w1, w1, w23
    add     w1, w1, #1
    bl      _emit_csi_col
uc_emit_colors:
    ldr     w4, [sp, #24]           // top (riga pari → PRIMO PIANO)
    ldr     w6, [sp, #32]           // bot (riga dispari → SFONDO)
    cmp     w4, w26
    b.eq    uc_check_bot
    mov     w26, w4
    bl      _emit_fg_color
uc_check_bot:
    ldr     w8, [sp, #16]           // last_bot
    cmp     w6, w8
    b.eq    uc_emit_char
    str     w6, [sp, #16]
    mov     w4, w6
    bl      _emit_bg_color
uc_emit_char:
    bl      _emit_half
    // Flush se buffer quasi pieno
    adrp    x0, row_buffer@PAGE
    add     x0, x0, row_buffer@PAGEOFF
    sub     x1, x25, x0
    cmp     x1, #3000
    b.lo    uc_next
    bl      _buf_flush

uc_next:
    ldr     w8, [sp]
    add     w8, w8, #1
    str     w8, [sp]
    cmp     w8, w21
    b.lo    uc_cell

    bl      _buf_flush
    add     w24, w24, #1
    b       uc_row

uc_done:
    // Copia grid → prev_grid
    adrp    x0, grid_area@PAGE
    add     x0, x0, grid_area@PAGEOFF
    ldr     w2, [x0]
    mov     x0, x20
    mov     x1, x19
    bl      _memcpy

    // Salva contatori
    adrp    x0, tree_count@PAGE
    add     x0, x0, tree_count@PAGEOFF
    str     w27, [x0]
    adrp    x0, burning_count@PAGE
    add     x0, x0, burning_count@PAGEOFF
    str     w28, [x0]

    add     sp, sp, #64
    ldp     x20, x19, [sp], #16
    ldp     x22, x21, [sp], #16
    ldp     x24, x23, [sp], #16
    ldp     x26, x25, [sp], #16
    ldp     x28, x27, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _print_status_bar — Due righe fisse sotto la griglia.
// printf variadica macOS: args sullo STACK.
// ------------------------------------------------------------
_print_status_bar:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Posiziona riga 1: top_pad + size/2 + 3 (sotto il bordo inferiore)
    adrp    x0, top_pad@PAGE
    add     x0, x0, top_pad@PAGEOFF
    ldr     w1, [x0]
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w2, [x0]
    lsr     w2, w2, #1
    add     w0, w1, w2
    add     w0, w0, #3
    mov     w1, #1
    bl      _pos_write

    // Carica contatori e stringhe stato
    adrp    x0, tree_count@PAGE
    add     x0, x0, tree_count@PAGEOFF
    ldr     w8, [x0]
    adrp    x0, burning_count@PAGE
    add     x0, x0, burning_count@PAGEOFF
    ldr     w9, [x0]

    adrp    x4, status_fire_off@PAGE
    add     x4, x4, status_fire_off@PAGEOFF
    adrp    x5, status_blank@PAGE
    add     x5, x5, status_blank@PAGEOFF
    adrp    x0, fire_active@PAGE
    add     x0, x0, fire_active@PAGEOFF
    ldr     w10, [x0]
    cbnz    w10, psb_fire
    adrp    x0, paused@PAGE
    add     x0, x0, paused@PAGEOFF
    ldr     w10, [x0]
    cbz     w10, psb_ok
    adrp    x5, status_paused@PAGE
    add     x5, x5, status_paused@PAGEOFF
    b       psb_ok
psb_fire:
    adrp    x4, status_fire_on@PAGE
    add     x4, x4, status_fire_on@PAGEOFF
psb_ok:

    sub     sp, sp, #32
    sxtw    x8, w8
    str     x8, [sp]
    sxtw    x9, w9
    str     x9, [sp, #8]
    str     x4, [sp, #16]
    str     x5, [sp, #24]
    adrp    x0, status_fmt@PAGE
    add     x0, x0, status_fmt@PAGEOFF
    bl      _printf
    add     sp, sp, #32
    mov     w0, #0
    bl      _fflush

    // Posiziona riga 2: top_pad + size/2 + 4
    adrp    x0, top_pad@PAGE
    add     x0, x0, top_pad@PAGEOFF
    ldr     w1, [x0]
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w2, [x0]
    lsr     w2, w2, #1
    add     w0, w1, w2
    add     w0, w0, #4
    mov     w1, #1
    bl      _pos_write

    // Riga 2: slider, slider, grid size
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    ldr     w8, [x0]
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    ldr     w9, [x0]
    adrp    x0, grid_size@PAGE
    add     x0, x0, grid_size@PAGEOFF
    ldr     w16, [x0]

    sub     sp, sp, #32            // 4 varargs
    sxtw    x8, w8
    str     x8, [sp]
    sxtw    x9, w9
    str     x9, [sp, #8]
    sxtw    x16, w16
    str     x16, [sp, #16]
    str     x16, [sp, #24]
    adrp    x0, status_fmt2@PAGE
    add     x0, x0, status_fmt2@PAGEOFF
    bl      _printf
    add     sp, sp, #32
    mov     w0, #0
    bl      _fflush

    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _handle_input — Legge e processa TUTTI i tasti nel buffer.
// Le sequenze ESC spezzate tra due read vengono conservate in
// pend_buf e riunite alla read successiva (niente tasti persi).
// Un ESC singolo esce solo se NON arriva altro (niente quit
// accidentale quando una freccia viene spezzata in due read).
// ------------------------------------------------------------
_handle_input:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x22, x21, [sp, #-16]!
    stp     x20, x19, [sp, #-16]!

hi_read:
    // Prepend dei byte pendenti (sequenza ESC spezzata)
    adrp    x0, pend_len@PAGE
    add     x0, x0, pend_len@PAGEOFF
    ldr     w21, [x0]               // n byte pendenti
    str     wzr, [x0]
    cbz     w21, hi_read_clean
    adrp    x1, pend_buf@PAGE
    add     x1, x1, pend_buf@PAGEOFF
    adrp    x8, key_buffer@PAGE
    add     x8, x8, key_buffer@PAGEOFF
    mov     w22, w21
1:  ldrb    w2, [x1], #1
    strb    w2, [x8], #1
    sub     w22, w22, #1
    cbnz    w22, 1b
hi_read_clean:
    // read(0, key_buffer + w21, 8 - w21)
    adrp    x1, key_buffer@PAGE
    add     x1, x1, key_buffer@PAGEOFF
    add     x1, x1, w21, uxtw
    mov     w0, #0
    mov     w2, #8
    sub     w2, w2, w21
    bl      _read
    cmp     w0, #0
    b.gt    hi_have
    // Read vuoto: se c'era un ESC singolo pendente → quit (l'utente
    // ha premuto davvero ESC, non era l'inizio di una freccia).
    cmp     w21, #1
    b.ne    hi_repend
    adrp    x8, pend_buf@PAGE
    add     x8, x8, pend_buf@PAGEOFF
    ldrb    w9, [x8]
    cmp     w9, #27
    b.eq    hi_quit
hi_repend:
    // Il pend era già stato copiato in key_buffer ma non è arrivato
    // altro: ri-salvalo in pend_buf, così la sequenza spezzata
    // sopravvive alla chiamata successiva (senza, andava persa).
    cbz     w21, hi_done
    adrp    x1, pend_buf@PAGE
    add     x1, x1, pend_buf@PAGEOFF
    adrp    x8, key_buffer@PAGE
    add     x8, x8, key_buffer@PAGEOFF
    mov     w2, w21
    mov     w22, w21
1:  ldrb    w3, [x8], #1
    strb    w3, [x1], #1
    sub     w2, w2, #1
    cbnz    w2, 1b
    adrp    x0, pend_len@PAGE
    add     x0, x0, pend_len@PAGEOFF
    str     w22, [x0]
    b       hi_done
hi_have:
    add     w19, w0, w21            // totale byte nel buffer
    mov     w20, #0                 // offset

hi_parse:
    cmp     w20, w19
    b.hs    hi_read                 // buffer esaurito → leggi altro
    adrp    x8, key_buffer@PAGE
    add     x8, x8, key_buffer@PAGEOFF
    ldrb    w9, [x8, w20, uxtw]

    cmp     w9, #'q'
    b.eq    hi_quit
    cmp     w9, #'Q'
    b.eq    hi_quit
    cmp     w9, #0x03              // Ctrl+C
    b.eq    hi_quit
    cmp     w9, #27                 // ESC
    b.eq    hi_escape
    cmp     w9, #' '
    b.eq    hi_pause
    cmp     w9, #'['
    b.eq    hi_slow
    cmp     w9, #']'
    b.eq    hi_fast
    add     w20, w20, #1            // non riconosciuto
    b       hi_parse

hi_escape:
    sub     w21, w19, w20           // byte rimanenti
    cmp     w21, #1
    b.eq    hi_esc_pend             // ESC in fondo: pendi, non uscire
    add     w11, w20, #1
    ldrb    w9, [x8, w11, uxtw]
    cmp     w9, #'['
    b.ne    hi_esc_skip
    cmp     w21, #3
    b.lo    hi_esc_partial          // ESC[ senza carattere finale: pendi
    add     w11, w20, #2
    ldrb    w9, [x8, w11, uxtw]
    cmp     w9, #'1'                // freccia MODIFICATA: ESC[1;2A (Shift) / ESC[1;5A (Ctrl)
    b.eq    hi_esc_mod
    cmp     w9, #'A'                // SU: +alberi
    b.eq    hi_tree_up
    cmp     w9, #'B'                // GIÙ: -alberi
    b.eq    hi_tree_down
    cmp     w9, #'C'                // DESTRA: +fulmini
    b.eq    hi_lightning_up
    cmp     w9, #'D'                // SINISTRA: -fulmini
    b.eq    hi_lightning_down
hi_esc_skip:
    add     w20, w20, #1            // ESC non-freccia: consuma 1
    b       hi_parse

hi_esc_mod:
    // Sequenza completa: ESC [ 1 ; m Y  (6 byte). Shift=2, Ctrl=5.
    cmp     w21, #6
    b.lo    hi_esc_partial
    add     w11, w20, #3
    ldrb    w9, [x8, w11, uxtw]
    cmp     w9, #';'
    b.ne    hi_esc_skip             // non è una freccia modificata
    add     w11, w20, #4
    ldrb    w9, [x8, w11, uxtw]     // modificatore
    cmp     w9, #'2'
    b.eq    hi_mod_ok
    cmp     w9, #'5'
    b.ne    hi_esc_skip6            // altri modificatori: ignora
hi_mod_ok:
    add     w11, w20, #5
    ldrb    w9, [x8, w11, uxtw]
    cmp     w9, #'A'
    b.eq    hi_tree_up_fine
    cmp     w9, #'B'
    b.eq    hi_tree_down_fine
    cmp     w9, #'C'
    b.eq    hi_lightning_up_fine
    cmp     w9, #'D'
    b.eq    hi_lightning_down_fine
hi_esc_skip6:
    add     w20, w20, #6
    b       hi_parse

hi_esc_pend:
    // Un solo ESC in fondo al buffer: potrebbe essere una freccia
    // spezzata → lo teniamo in sospeso. Se alla prossima read non
    // arriva altro, hi_read lo trasforma in quit.
    sub     w22, w19, w20           // byte rimanenti (=1)
    b       hi_pend_store

hi_esc_partial:
    // ESC[ senza il carattere finale (sequenza spezzata): pendi i
    // byte rimanenti e rileggi.
    sub     w22, w19, w20

hi_pend_store:
    adrp    x0, pend_len@PAGE
    add     x0, x0, pend_len@PAGEOFF
    str     w22, [x0]
    adrp    x1, pend_buf@PAGE
    add     x1, x1, pend_buf@PAGEOFF
    adrp    x8, key_buffer@PAGE
    add     x8, x8, key_buffer@PAGEOFF
    add     x8, x8, w20, uxtw
    mov     w2, w22
1:  ldrb    w3, [x8], #1
    strb    w3, [x1], #1
    sub     w2, w2, #1
    cbnz    w2, 1b
    b       hi_read

hi_tree_up:
    add     w20, w20, #3
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    mov     w1, #5
    mov     w12, #1
    bl      _slider_adjust
    b       hi_parse

hi_tree_down:
    add     w20, w20, #3
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    mov     w1, #5
    mov     w12, #-1
    bl      _slider_adjust
    b       hi_parse

hi_lightning_up:
    add     w20, w20, #3
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    mov     w1, #5
    mov     w12, #1
    bl      _slider_adjust
    b       hi_parse

hi_lightning_down:
    add     w20, w20, #3
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    mov     w1, #5
    mov     w12, #-1
    bl      _slider_adjust
    b       hi_parse

// Modalità FINE (Shift o Ctrl + freccia): ±1
hi_tree_up_fine:
    add     w20, w20, #6
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    mov     w1, #1
    mov     w12, #1
    bl      _slider_adjust
    b       hi_parse

hi_tree_down_fine:
    add     w20, w20, #6
    adrp    x0, tree_slider@PAGE
    add     x0, x0, tree_slider@PAGEOFF
    mov     w1, #1
    mov     w12, #-1
    bl      _slider_adjust
    b       hi_parse

hi_lightning_up_fine:
    add     w20, w20, #6
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    mov     w1, #1
    mov     w12, #1
    bl      _slider_adjust
    b       hi_parse

hi_lightning_down_fine:
    add     w20, w20, #6
    adrp    x0, lightning_slider@PAGE
    add     x0, x0, lightning_slider@PAGEOFF
    mov     w1, #1
    mov     w12, #-1
    bl      _slider_adjust
    b       hi_parse

// _slider_adjust — Regola uno slider 1..100.
// x0 = indirizzo slider, w1 = delta, w12 = +1 (su) / -1 (giù).
// Poi ricalcola le soglie. Non tocca i registri callee-saved.
_slider_adjust:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    ldr     w2, [x0]
    cmp     w12, #0
    b.lt    sa_down
    mov     w3, #100
    cmp     w2, w3
    b.hs    sa_done
    add     w2, w2, w1
    cmp     w2, w3
    csel    w2, w3, w2, hi          // clamp a 100
    str     w2, [x0]
    bl      _update_thresholds
    b       sa_done
sa_down:
    mov     w3, #1
    cmp     w2, w3
    b.ls    sa_done
    sub     w2, w2, w1
    cmp     w2, w3
    csel    w2, w3, w2, lo          // floor a 1
    str     w2, [x0]
    bl      _update_thresholds
sa_done:
    ldp     x29, x30, [sp], #16
    ret

hi_pause:
    add     w20, w20, #1
    adrp    x0, paused@PAGE
    add     x0, x0, paused@PAGEOFF
    ldr     w1, [x0]
    eor     w1, w1, #1
    str     w1, [x0]
    b       hi_parse

hi_slow:
    // '[' → rallenta (delay += 10000, max 200000)
    add     w20, w20, #1
    adrp    x0, frame_delay@PAGE
    add     x0, x0, frame_delay@PAGEOFF
    ldr     w1, [x0]
    movz    w2, #0xD40
    movk    w2, #0x0003, lsl #16    // 200000
    cmp     w1, w2
    b.hs    hi_parse
    movz    w2, #0x2710             // 10000
    add     w1, w1, w2
    str     w1, [x0]
    b       hi_parse

hi_fast:
    // ']' → accelera (delay -= 10000, min 10000)
    add     w20, w20, #1
    adrp    x0, frame_delay@PAGE
    add     x0, x0, frame_delay@PAGEOFF
    ldr     w1, [x0]
    movz    w2, #0x2710             // 10000
    cmp     w1, w2
    b.ls    hi_parse
    sub     w1, w1, w2
    str     w1, [x0]
    b       hi_parse

hi_quit:
    adrp    x0, running@PAGE
    add     x0, x0, running@PAGEOFF
    str     wzr, [x0]
    b       hi_done

hi_done:
    ldp     x20, x19, [sp], #16
    ldp     x22, x21, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// Emit helpers — scrivono nel buffer puntato da x25 e lo avanzano.
// Clobber: w0-w7, w10, w11, x4, x8 (e x25 ovviamente).
// NON toccano x19-x24, x26-x28 (callee-saved usati dai chiamanti).
// ------------------------------------------------------------

// _emit_utoa — w0 = valore → cifre decimali nel buffer
_emit_utoa:
    mov     w10, #10
    cbnz    w0, 1f
    mov     w2, #'0'
    strb    w2, [x25], #1
    ret
1:  sub     sp, sp, #16
    mov     x4, sp
    mov     w2, #0
2:  udiv    w5, w0, w10
    msub    w6, w5, w10, w0
    add     w6, w6, #'0'
    strb    w6, [x4], #1
    add     w2, w2, #1
    mov     w0, w5
    cbnz    w0, 2b
3:  sub     x4, x4, #1
    ldrb    w6, [x4]
    strb    w6, [x25], #1
    sub     w2, w2, #1
    cbnz    w2, 3b
    add     sp, sp, #16
    ret

// _emit_csi_pos — ESC[row;colH (w0 = row, w1 = col)
// IMPORTANTE: salva x29/x30 perché chiama _emit_utoa via bl,
// che sovrascrive x30 (link register). Senza questo il ret
// tornava dentro _emit_csi_pos stesso → loop infinito di 'H'
// finché x25 usciva dalla memoria mappata → SIGBUS.
_emit_csi_pos:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #16
    str     w1, [sp]
    mov     w2, #27
    strb    w2, [x25], #1
    mov     w2, #'['
    strb    w2, [x25], #1
    bl      _emit_utoa
    mov     w2, #';'
    strb    w2, [x25], #1
    ldr     w1, [sp]
    mov     w0, w1
    bl      _emit_utoa
    mov     w2, #'H'
    strb    w2, [x25], #1
    add     sp, sp, #16
    ldp     x29, x30, [sp], #16
    ret

// _emit_csi_col — ESC[colG (w1 = col; stessa riga)
// (stesso fix di x30 come _emit_csi_pos)
_emit_csi_col:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #16
    str     w1, [sp]
    mov     w2, #27
    strb    w2, [x25], #1
    mov     w2, #'['
    strb    w2, [x25], #1
    ldr     w0, [sp]
    bl      _emit_utoa
    mov     w2, #'G'
    strb    w2, [x25], #1
    add     sp, sp, #16
    ldp     x29, x30, [sp], #16
    ret

// _emit_bg_color — stringa colore SFONDO per stato w4
// (meta' INFERIORE della cella: riga dispari della coppia)
_emit_bg_color:
    adrp    x8, color_table@PAGE
    add     x8, x8, color_table@PAGEOFF
    ldr     x8, [x8, w4, uxtw #3]
1:  ldrb    w11, [x8], #1
    cbz     w11, 2f
    strb    w11, [x25], #1
    b       1b
2:  ret

// _emit_fg_color — stringa colore PRIMO PIANO per stato w4
// (meta' SUPERIORE della cella: riga pari della coppia)
_emit_fg_color:
    adrp    x8, color_table_fg@PAGE
    add     x8, x8, color_table_fg@PAGEOFF
    ldr     x8, [x8, w4, uxtw #3]
1:  ldrb    w11, [x8], #1
    cbz     w11, 2f
    strb    w11, [x25], #1
    b       1b
2:  ret

// _emit_cstr — copia una stringa NUL-terminata (x0) nel buffer x25
_emit_cstr:
1:  ldrb    w11, [x0], #1
    cbz     w11, 2f
    strb    w11, [x25], #1
    b       1b
2:  ret

// _emit_half — scrive il carattere mezzo-blocco '▀' (E2 96 80)
_emit_half:
    mov     w11, #0xE2
    strb    w11, [x25], #1
    mov     w11, #0x96
    strb    w11, [x25], #1
    mov     w11, #0x80
    strb    w11, [x25], #1
    ret

// _emit_box — scrive un carattere box-drawing E2 94 <w0> (0x8C=┌,
// 0x90=┐, 0x94=└, 0x98=┘, 0x80=─, 0x82=│). Tutte le istruzioni
// su righe proprie: il clang IAS scarta le istruzioni dopo ';'.
_emit_box:
    mov     w11, #0xE2
    strb    w11, [x25], #1
    mov     w11, #0x94
    strb    w11, [x25], #1
    strb    w0, [x25], #1
    ret

// _buf_flush — scrive row_buffer[0..len) e resetta x25 a row_buffer
_buf_flush:
    adrp    x0, row_buffer@PAGE
    add     x0, x0, row_buffer@PAGEOFF
    sub     x2, x25, x0
    cbz     x2, 1f
    stp     x29, x30, [sp, #-16]!
    mov     x1, x0
    mov     w0, #1
    bl      _write
    ldp     x29, x30, [sp], #16
1:  adrp    x0, row_buffer@PAGE
    add     x0, x0, row_buffer@PAGEOFF
    mov     x25, x0
    ret

// _pos_write — emette ESC[row;colH via scratch_buf e _write
// w0 = row, w1 = col
// IMPORTANTE: l'adrp/add di scratch_buf CLOBBERA x0 (il row!),
// quindi salva row/col in un'area TEMPORANEA sotto i registri
// salvati (NON su [sp], che è dove stanno x29/x30!)
_pos_write:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #16
    str     w0, [sp]
    str     w1, [sp, #8]
    adrp    x0, scratch_buf@PAGE
    add     x25, x0, scratch_buf@PAGEOFF
    ldr     w0, [sp]
    ldr     w1, [sp, #8]
    bl      _emit_csi_pos
    adrp    x0, scratch_buf@PAGE
    add     x0, x0, scratch_buf@PAGEOFF
    sub     x2, x25, x0
    mov     x1, x0
    mov     w0, #1
    bl      _write
    add     sp, sp, #16
    ldp     x29, x30, [sp], #16
    ret

// ------------------------------------------------------------
// _memcpy — x0 = dst, x1 = src, w2 = n
// ------------------------------------------------------------
_memcpy:
    cbz     w2, mc_done
1:  ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    sub     w2, w2, #1
    cbnz    w2, 1b
mc_done:
    ret
