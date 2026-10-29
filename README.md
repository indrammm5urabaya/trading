# Trading EA Collection

Kumpulan Expert Advisor (MQL5) untuk MetaTrader 5.

## Struktur

```
ea/
  breakout-baskettp/
    v3.20_NoSL/     # Entry: Buy Stop & Sell Stop breakout
    v4.10/          # Entry: market order, arah dari Daily Change %
    v4.10_opt/      # Build hasil optimasi
  grid-classic/
    v1.06/          # Grid klasik + modul CARA EXIT
  pending-stop-grid/
    v1.00/          # Pending stop grid
  straddle-breakout-xau/
                    # Straddle breakout XAU (binary)
sets/
                    # Preset parameter (.set)
```

## Catatan versi

### EA_Breakout_BasketTP
Rantai versi lengkap tercatat di changelog dalam file `.mq5`:
v1.00 → v1.01 → v2.00 → v2.10 → v2.20 → v2.30 → v2.40 → v2.50 →
v2.60 → v2.70 → v2.71 → v2.72 → v2.80 → v2.90 → v3.00 → v3.10 →
v3.11 → v3.20 → v3.30 → v4.00 → v4.10

Yang tersimpan di repo ini hanya build yang masih ada:
- v3.20_NoSL (revisi v3.20 tanpa fitur SL)
- v4.10
- v4.10_opt (binary only, tanpa source)

### GRID_CLASSIC
v1.00 → v1.01 → v1.02 → (v1.03 tidak ada di changelog) → v1.04 → v1.05 → v1.06

### PENDING_STOP_GRID
v1.00 — binary + paket zip, tanpa source `.mq5`.

## Lisensi

Lihat `LICENSE`. GRID_CLASSIC: © Bang iNo.
