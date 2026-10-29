//+------------------------------------------------------------------+
//|                                        Copyright 2026, Bang iNo  |
//|                                     https://wa.me/6285648181181  |
//+------------------------------------------------------------------+
#define EA_VERSION     "1.06"   // << SATU-SATUNYA tempat ganti versi
#property copyright "Bang iNo"
#property link      "https://wa.me/6285648181181"
#property version   EA_VERSION
#property strict
#property description "GRID CLASSIC - EA Grid klasik (Entry Grid re-entry tiap jarak grid, lot awal 0.01, side Buy/Sell/Both, max grid) + Modul EXIT lengkap CARA EXIT (Trailing Basket TP + TP Berjenjang + Side TP + Real/Virtual TP + Sweep TP Parsial + SL Basket + TP/SL History)."
// Tag file state (.dat): otomatis dari EA_VERSION ("." -> "_") saat init.
string g_ver_tag = "";
string EAVersionTag()
{
    if (g_ver_tag == "")
    {
        g_ver_tag = EA_VERSION;
        StringReplace(g_ver_tag, ".", "_");
    }
    return g_ver_tag;
}

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Object instances
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

//--- object Enum
enum ENUM_TP_FIELD_MODE { TPFIELD_AUTO = 0, TPFIELD_MANUAL = 1 };

//--- Pilihan sisi untuk strategi ENTRY GRID CLASSIC
enum ENUM_GRID_SIDE
{
    GRID_BUY_ONLY  = 0,   // Buy Only
    GRID_SELL_ONLY = 1,   // Sell Only
    GRID_BOTH      = 2,   // Buy & Sell
    GRID_AUTO      = 3    // AUTO (deteksi kondisi market)
};

//--- Kecenderungan market untuk mode AUTO
enum ENUM_MKT_REGIME
{
    MKT_SIDEWAY    = 0,   // Sideway  -> Support & Resistance
    MKT_BULL_STRONG= 1,   // Strong Bullish -> Supply & Demand
    MKT_BEAR_STRONG= 2,   // Strong Bearish -> Supply & Demand
    MKT_BREAKOUT   = 3    // Breakout (M15/H1/H4/D1) -> Breakout Momentum
};

//--- Input Parameters
//    Format: D'YYYY.MM.DD HH:MM:SS' — EA berhenti total setelah tanggal ini
const datetime EA_EXPIRED_DATE = D'2305.05.23 23:23:23';

input group "=== ENTRY GRID CLASSIC ==="
input ENUM_GRID_SIDE InpGridSide        = GRID_BOTH; // Sisi entry: Buy Only / Sell Only / Buy & Sell / AUTO
input double   InpInitialLot            = 0.01;      // Lot awal (dan lot setiap re-entry grid)
input int      InpGridDistancePoints    = 1000;      // Jarak grid (POINT). Re-entry tiap harga bergerak sejauh ini melawan posisi terakhir
input int      InpMaxGridPositions      = 1000;      // Maksimum total posisi grid (semua sisi). 0 = tak terbatas
input double   InpGridBasketTP          = 0.0;       // TP basket KHUSUS grid (USD). 0 = pakai modul EXIT (CARA EXIT) di bawah
input bool     InpEntryDebug            = false;     // Log diagnostik entry ke Journal

input group "=== AUTO SIDE (aktif bila InpGridSide = AUTO) ==="
input ENUM_TIMEFRAMES InpAutoHTF          = PERIOD_H1; // TF struktur (BOS/S&R/S&D)
input ENUM_TIMEFRAMES InpAutoBreakTF      = PERIOD_M15;// TF breakout terendah (momentum)
input bool     InpAutoD1Breakout          = true;      // Ikut sertakan breakout D1
input int      InpAutoSRLookback         = 40;        // Lookback swing S&R / S&D (bar)
input int      InpAutoSwingStrength      = 2;         // Kekuatan swing (bar kiri & kanan)
input double   InpAutoRangeMaxATR        = 2.5;       // Sideway bila lebar range <= x*ATR(HTF)
input double   InpAutoStrongBodyRatio    = 0.60;      // Body candle >= rasio ini = candle kuat (S&D)
input int      InpAutoStrongBars         = 3;         // Jumlah candle kuat beruntun utk regime S&D
input double   InpAutoBreakoutBufferATR  = 0.15;      // Buffer breakout = x*ATR(TF breakout)
input int      InpAutoATRPeriod          = 14;        // Periode ATR
input int      InpAutoBiasBars           = 3;         // Jumlah bar terakhir utk bias arah side (AUTO)
input double   InpAutoZoneATR             = 1.0;      // Lebar zona S&R/S&D = x*ATR(HTF)
input bool     InpAutoRespectBias        = false;     // Hormati bias: jangan entry melawan arah bila bertentangan (sisi non-bias)



input group "=== Settings ==="
input ulong    InpMagic            = 0;     // Magic Number. 0 = KELOLA SEMUA posisi symbol ini (manual/EA lain)
const bool     InpExitDebug        = true;  // Log diagnostik exit ke Journal. Matikan utk produksi.

input group "=== EXIT ==="
input double   InpTargetProfit      = 1.5;   // TP1 (USD) — target basket tingkat 0 (peak drawdown < 1x step)
input double   InpTargetProfit2     = 2.0;   // TP2 (USD) — tingkat 1 (peak drawdown >= 1x step)
input double   InpTargetProfit3     = 2.5 ;  // TP3 (USD) — tingkat 2 (peak drawdown >= 2x step)
input double   InpTargetProfit4     = 3.0 ;  // TP4 (USD) — tingkat >= 3 (mentok). Step = InpAutoGridStepUSD
const bool     InpBasketTPUseRealTP = true;  // Real-TP jalur NET-BASKET: true = Unified TP riil di broker; false = virtual (market close EA)
input double   InpSideTargetProfit  = 5.0;  // Target profit PER SISI (USD) — trailing lock identik Basket TP, hanya menutup satu sisi. AKTIF hanya saat DUA sisi terbuka. 0=nonaktif
const bool     InpSideTPUseRealTP   = false; // Real-TP jalur PER-SISI: true = parked TP riil di tiket sisi itu; false = virtual. TERPISAH dari InpBasketTPUseRealTP
const ENUM_TP_FIELD_MODE InpTPFieldMode = TPFIELD_AUTO; // Kepemilikan field TP tiket. AUTO = 1 sisi -> net-basket REAL & side virtual; 2 sisi -> side REAL & net-basket virtual. MANUAL = ikut kedua flag di atas
// Flag EFEKTIF — satu-satunya pintu baca real/virtual di seluruh EA.
bool EffBasketTPReal() { return (InpTPFieldMode == TPFIELD_AUTO) ? true : InpBasketTPUseRealTP; }
bool EffSideTPReal()   { return (InpTPFieldMode == TPFIELD_AUTO) ? true : InpSideTPUseRealTP; }
const int      InpBasketTPPauseSec  = 5;     // Jeda (detik) setelah Basket TP selesai sebelum siklus baru dimulai
const int      InpAutoGridStepUSD   = 300;   // Step USD TP BERJENJANG (basis peak drawdown basket)

input group "=== FILTER MAX FLOATING (SL BASKET) ==="
input double   InpMaxFloatingLoss   = 0.0;   // SL Basket: tutup SEMUA posisi symbol bila total floating <= -nilai ini (mata uang akun, isi positif). 0 = nonaktif

input group "=== UI (TP/SL HISTORY + GARIS TP) ==="
input bool     InpShowUI            = true;  // Tampilkan panel TP/SL HISTORY & garis TP di chart
input int      InpUIScalePercent    = 70;    // Skala UI (%)
const int      InpMaxRetries        = 10;    // Maksimum percobaan ulang saat close/delete order
const int      InpRetrySleepMs      = 300;   // Jeda antar percobaan ulang (ms)

//--- Global Variables
bool           is_processing     = false;
bool           g_had_positions   = false;
int            g_prev_open_positions = 0;    // jumlah posisi tick sebelumnya (deteksi TP parsial unified)
datetime       g_ea_start_time   = 0;
bool           g_stop_after_closeall = false;
bool           g_basket_ignore_magic = false;

double         g_tp_profit_accum = 0.0;
double         g_tp_profit_pending = 0.0;
bool           g_tp_profit_pending_valid = false;
double         g_tp_balance_before = 0.0;
bool           g_tp_balance_before_valid = false;
int            g_tp_hit_count = 0;

double         g_basket_peak   = 0.0;        // puncak floating profit siklus berjalan (trailing lock)
double         g_basket_worst  = 0.0;        // peak drawdown basket BERJALAN — basis TP Berjenjang
double         g_side_peak[2] = {0.0, 0.0};          // puncak floating per sisi [0]=BUY [1]=SELL
datetime       g_side_last_modify[2] = {0, 0};       // throttle modify TP per-side
double         g_side_last_parked[2] = {0.0, 0.0};   // parked target per-side terakhir terpasang

bool           g_unified_exit_active = false;
int            g_unified_exit_dir = 0;
double         g_unified_exit_bid = 0.0;
double         g_unified_exit_ask = 0.0;
int            g_unified_modify_passes_left = 0;
datetime       g_unified_last_modify_time = 0;
double         g_unified_last_target_profit = 0.0;
bool           g_unified_last_target_profit_valid = false;

datetime       g_basket_pause_until = 0;
bool           g_maxfloat_fired  = false;    // latch: close-all akibat Max Floating SL sudah dipicu
double         g_slh_balance_before = 0.0;   // balance sebelum penutupan non-TP (utk TP/SL History)
bool           g_slh_pending        = false;

string         g_ui_prefix = "";
bool           g_ui_inited = false;
double         g_ui_scale  = 1.0;

//--- mode AUTO: regime & bias terakhir (dibaca panel, murni tampilan)
ENUM_MKT_REGIME g_auto_regime = MKT_SIDEWAY;
int             g_auto_bias   = 0;
//--- cache keputusan AUTO (dihitung ulang hanya saat bar HTF baru)
datetime        g_auto_cache_bar   = 0;
bool            g_auto_cache_buy   = false;
bool            g_auto_cache_sell  = false;
bool            g_auto_cache_valid = false;
//--- jejak terburuk siklus berjalan (dibaca panel, murni tampilan)
//    Indeks: 0=BUY, 1=SELL, 2=TOTAL
double          g_worst_pl[3]  = {0.0, 0.0, 0.0};   // floating terendah
double          g_worst_lot[3] = {0.0, 0.0, 0.0};   // total lot saat terburuk
int             g_worst_cnt[3] = {0, 0, 0};         // jumlah posisi terbanyak

enum ENUM_BASKET_EXEC_STATE
{
    BASKET_EXEC_IDLE   = 0,
    BASKET_EXEC_INIT   = 1,
    BASKET_EXEC_SEND   = 2,
    BASKET_EXEC_VERIFY = 3,
    BASKET_EXEC_FORCE  = 4,
    BASKET_EXEC_DONE   = 5
};
bool           g_basket_exec_active = false;
int            g_basket_exec_state = BASKET_EXEC_IDLE;
ulong          g_basket_exec_seq = 0;
string         g_basket_exec_id = "";
datetime       g_basket_exec_next_check = 0;
int            g_basket_exec_cycles = 0;
int            g_basket_exec_force_cycles = 0;
double         g_basket_exec_profit_snapshot = 0.0;
double         g_basket_exec_target_snapshot = 0.0;
int            g_basket_exec_side = 0;      // 0=semua, +1=BUY saja, -1=SELL saja
string         g_basket_exec_reason = "";
ulong          g_basket_exec_pos_tickets[];
int            g_basket_exec_pos_attempts[];
datetime       g_basket_exec_pos_last_try[];
ulong          g_basket_exec_ord_tickets[];
int            g_basket_exec_ord_attempts[];
datetime       g_basket_exec_ord_last_try[];

//+------------------------------------------------------------------+
//| HELPER UMUM                                                       |
//+------------------------------------------------------------------+
datetime TimeWIBNow()
{
    datetime gmt = TimeGMT();
    if (gmt <= 0) gmt = TimeLocal();
    return gmt + 7 * 3600;
}

int UIS(const int v) { return (int)MathRound((double)v * g_ui_scale); }
int UIFont(const int v)
{
    int r = (int)MathRound((double)v * g_ui_scale);
    if (r < 1) r = 1;
    return r;
}

string AddThousandsSep(const string digits_only)
{
    int n = (int)StringLen(digits_only);
    if (n <= 3) return digits_only;
    string out = "";
    int first = n % 3;
    if (first == 0) first = 3;
    out = StringSubstr(digits_only, 0, first);
    for (int i = first; i < n; i += 3)
        out += "," + StringSubstr(digits_only, i, 3);
    return out;
}

string FormatMoney(const double value, const int decimals = 2)
{
    double v = value;
    string sign = "";
    if (v < 0.0) { sign = "-"; v = -v; }
    string s = DoubleToString(v, decimals);
    int dot = (int)StringFind(s, ".");
    string ip = (dot >= 0) ? StringSubstr(s, 0, dot) : s;
    string fp = (dot >= 0) ? StringSubstr(s, dot) : "";
    return sign + AddThousandsSep(ip) + fp + "$";
}

string FormatSignedMoney(const double value, const int decimals = 2)
{
    string s = FormatMoney(MathAbs(value), decimals);
    if (value > 0.0) return "+" + s;
    if (value < 0.0) return "-" + s;
    return s;
}

//+------------------------------------------------------------------+
//| Pencocokan magic untuk PENGELOLAAN/EXIT.                          |
//| InpMagic == 0  -> AMBIL ALIH semua posisi/order pada symbol ini,  |
//|                   APAPUN magic-nya (termasuk manual / EA lain).   |
//| InpMagic != 0  -> hanya magic yang sama.                          |
//+------------------------------------------------------------------+
bool MagicMatches(const long m)
{
    return (InpMagic == 0) || (m == (long)InpMagic);
}

// Cocokkan posisi/order dgn filter sisi eksekusi (0 = semua lolos).
bool ExecSideMatchPos(const ENUM_POSITION_TYPE t)
{
    if (g_basket_exec_side == 0) return true;
    return (g_basket_exec_side > 0) ? (t == POSITION_TYPE_BUY) : (t == POSITION_TYPE_SELL);
}
bool ExecSideMatchOrd(const ENUM_ORDER_TYPE t)
{
    if (g_basket_exec_side == 0) return true;
    bool is_buy = (t == ORDER_TYPE_BUY || t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT);
    return (g_basket_exec_side > 0) ? is_buy : !is_buy;
}

//+------------------------------------------------------------------+
//| Hitung posisi terbuka + floating                                  |
//+------------------------------------------------------------------+
int CountOpenPositions(double &total_profit, int &buy_count, int &sell_count, double &buy_profit, double &sell_profit)
{
    int count = 0;
    total_profit = 0; buy_count = 0; sell_count = 0; buy_profit = 0; sell_profit = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && MagicMatches(posInfo.Magic()))
        {
            count++;
            double p = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
            total_profit += p;
            if (posInfo.PositionType() == POSITION_TYPE_BUY)      { buy_count++;  buy_profit  += p; }
            else if (posInfo.PositionType() == POSITION_TYPE_SELL){ sell_count++; sell_profit += p; }
        }
    }
    return count;
}

int CountOpenPositions()
{
    double dummy_p, dummy_bp, dummy_sp;
    int dummy_b, dummy_s;
    return CountOpenPositions(dummy_p, dummy_b, dummy_s, dummy_bp, dummy_sp);
}

int CountRealPendingOrders()
{
    int count = 0;
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (!OrderSelect(ticket)) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (!MagicMatches(OrderGetInteger(ORDER_MAGIC))) continue;
        count++;
    }
    return count;
}

double GetTickValueProfit()
{
    double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
    if (tv > 0.0) return tv;
    tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    return tv;
}

bool IsBasketPauseActive()
{
    if (g_basket_pause_until <= 0) return false;
    return (TimeCurrent() < g_basket_pause_until);
}

bool IsEAExpired()
{
    return (TimeCurrent() > EA_EXPIRED_DATE);
}

// Predikat MURNI: hanya membaca status, tanpa efek samping.
bool IsAlgoTradingAllowedNow()
{
    return ((bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
            (bool)MQLInfoInteger(MQL_TRADE_ALLOWED) &&
            (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) &&
            (!g_basket_exec_active) &&
            (!IsBasketPauseActive()));
}

//+------------------------------------------------------------------+
//| Log diagnostik exit (throttled)                                   |
//+------------------------------------------------------------------+
void ExitDbg(const string reason)
{
    if (!InpExitDebug) return;
    static string   last_sig  = "";
    static datetime last_time = 0;
    datetime now = TimeCurrent();
    string sig = StringFormat("%d|%d", CountOpenPositions(), (int)g_basket_exec_state);
    if (sig == last_sig && (now - last_time) < 60) return;
    last_sig  = sig;
    last_time = now;
    Print("EXIT-DBG | ", reason, " | open=", CountOpenPositions());
}

//+------------------------------------------------------------------+
//| TP BERJENJANG — tingkat dari PEAK DRAWDOWN basket berjalan        |
//| (g_basket_worst; reset saat basket tutup). Mentok tingkat 3.      |
//+------------------------------------------------------------------+
int BasketTPTier()
{
    if (InpAutoGridStepUSD <= 0) return 0;
    int t = (int)MathFloor(MathMax(0.0, -g_basket_worst) / (double)InpAutoGridStepUSD);
    return MathMin(t, 3);
}

//+------------------------------------------------------------------+
//| Target basket EFEKTIF: satu-satunya pintu baca target.            |
//| Tingkat 0->TP1, 1->TP2, 2->TP3, >=3->TP4.                         |
//+------------------------------------------------------------------+
double EffTargetProfit()
{
    switch (BasketTPTier())
    {
        case 1:  return InpTargetProfit2;
        case 2:  return InpTargetProfit3;
        case 3:  return InpTargetProfit4;
        default: return InpTargetProfit;
    }
}

//+------------------------------------------------------------------+
//| RESET STATE SIKLUS EXIT (dipanggil saat basket tuntas / flat)     |
//+------------------------------------------------------------------+
void BasketExecResetState();
void ResetAfterClearPositions()
{
    g_prev_open_positions = 0;
    g_side_peak[0] = 0.0;  g_side_peak[1] = 0.0;
    g_side_last_parked[0] = 0.0; g_side_last_parked[1] = 0.0;
    g_side_last_modify[0] = 0;   g_side_last_modify[1] = 0;
    g_maxfloat_fired  = false;                       // lepas latch Max Floating SL
    g_basket_worst    = 0.0;                         // peak drawdown reset -> TP kembali TP1
    g_basket_peak     = 0.0;
    // CATATAN: jejak terburuk (g_worst_*) SENGAJA TIDAK di-reset di sini.
    // Nilainya diakumulasi sejak EA di-start dan hanya hilang saat EA
    // di-attach ulang (variabel global di-reinit oleh terminal).
    BasketExecResetState();
    g_had_positions = false;
    g_unified_exit_active = false;
    g_unified_exit_dir = 0;
    g_unified_exit_bid = 0.0;
    g_unified_exit_ask = 0.0;
    g_unified_last_modify_time = 0;
    g_unified_last_target_profit = 0.0;
    g_unified_last_target_profit_valid = false;
    g_tp_profit_pending = 0.0;
    g_tp_profit_pending_valid = false;
    g_tp_balance_before = 0.0;
    g_tp_balance_before_valid = false;
}

//+------------------------------------------------------------------+
//| TP/SL HISTORY (data + panel ringkas)                              |
//+------------------------------------------------------------------+
#define TPH_MAX 20
double   g_tph_val[TPH_MAX];
datetime g_tph_time[TPH_MAX];
string   g_tph_reason[TPH_MAX];
int      g_tph_count = 0;
bool     g_tph_collapsed = false;
int      g_tph_panel_w = 0;

string UIName(const string suffix) { return g_ui_prefix + suffix; }

bool UIEnsureRect(const string suffix, const int x, const int y, const int w, const int h, const color bg, const color border, const int z)
{
    string name = UIName(suffix);
    if (ObjectFind(0, name) < 0)
    {
        if (!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return false;
        ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    }
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
    ObjectSetInteger(0, name, OBJPROP_COLOR, border);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, z);
    return true;
}

bool UIEnsureLabel(const string suffix, const int x, const int y, const string text, const int font_size, const color clr, const string font, const ENUM_ANCHOR_POINT anchor, const int z)
{
    string name = UIName(suffix);
    if (ObjectFind(0, name) < 0)
    {
        if (!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return false;
        ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);
    }
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetString(0, name, OBJPROP_FONT, font);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, z);
    return true;
}

void UIDeleteAll()
{
    int total = ObjectsTotal(0, -1, -1);
    for (int i = total - 1; i >= 0; i--)
    {
        string n = ObjectName(0, i, -1, -1);
        if (StringLen(g_ui_prefix) > 0 && StringFind(n, g_ui_prefix) == 0)
            ObjectDelete(0, n);
    }
}

int UITextW(const string txt, const int fontsize, const string font = "Consolas")
{
    TextSetFont(font, -fontsize * 10);
    uint tw = 0, th = 0;
    if (!TextGetSize(txt, tw, th)) return (int)StringLen(txt) * fontsize;
    return (int)tw;
}

// Pasangan UITextW: TINGGI teks terukur (untuk memusatkan tombol panel).
int UITextH(const string txt, const int fontsize, const string font = "Consolas")
{
    TextSetFont(font, -fontsize * 10);
    uint tw = 0, th = 0;
    if (!TextGetSize(txt, tw, th)) return fontsize;
    return (int)th;
}

//--- state panel GRID CLASSIC
bool g_pnl_inited   = false;
bool g_pnl_collapsed = false;
int  g_pnl_panel_w  = 0;

void TPHistoryRender()
{
    if (!InpShowUI) return;
    int px = UIS(18) + g_pnl_panel_w + UIS(22);   // geser ke KANAN panel GRID CLASSIC
    int py = UIS(40);
    int rowh = UIS(28);
    int w = UIS(34) + UITextW("TP/SL HISTORY", UIFont(13)) + UIS(14);
    if (!g_tph_collapsed)
        for (int wi = 0; wi < g_tph_count; wi++)
        {
            string wt = StringFormat("%s | %-9s| %+.2f", TimeToString(g_tph_time[wi], TIME_MINUTES), g_tph_reason[wi], g_tph_val[wi]);
            w = MathMax(w, UIS(8) + UITextW(wt, UIFont(11)) + UIS(14));
        }
    g_tph_panel_w = w;
    int rows = g_tph_collapsed ? 0 : g_tph_count;
    int hgt  = UIS(28) + rows * rowh + ((rows > 0) ? UIS(24) : UIS(4));

    UIEnsureRect ("tph_bg", px, py, w, hgt, (color)C'12,17,28', (color)C'40,55,75', 50);
    UIEnsureLabel("tph_btn", px + UIS(8), py + UIS(6), g_tph_collapsed ? "[+]" : "[-]",
                  UIFont(10), (color)C'150,165,190', "Consolas", ANCHOR_LEFT_UPPER, 60);
    UIEnsureLabel("tph_ttl", px + UIS(34), py + UIS(6), "TP/SL HISTORY", UIFont(13),
                  (color)C'200,210,225', "Consolas", ANCHOR_LEFT_UPPER, 60);
    ObjectSetInteger(0, UIName("tph_btn"), OBJPROP_SELECTABLE, true);

    double tot = 0.0;
    for (int i = 0; i < TPH_MAX; i++)
    {
        string ln = "tph_r" + (string)i;
        if (g_tph_collapsed || i >= g_tph_count) { ObjectDelete(0, UIName(ln)); continue; }
        tot += g_tph_val[i];
        color c = (g_tph_val[i] >= 0.0) ? (color)C'0,220,120' : (color)C'255,80,90';
        string txt = StringFormat("%s | %-9s| %+.2f", TimeToString(g_tph_time[i], TIME_MINUTES), g_tph_reason[i], g_tph_val[i]);
        UIEnsureLabel(ln, px + UIS(8), py + UIS(28) + i * rowh, txt, UIFont(11), c, "Consolas", ANCHOR_LEFT_UPPER, 60);
    }
    if (!g_tph_collapsed && g_tph_count > 0)
    {
        color tc = (tot >= 0.0) ? (color)C'0,220,120' : (color)C'255,80,90';
        UIEnsureLabel("tph_tot", px + UIS(8), py + UIS(28) + g_tph_count * rowh + UIS(2),
                      StringFormat("TOTAL: %+.2f  (%dx TP)", tot, g_tp_hit_count), UIFont(11), tc, "Consolas", ANCHOR_LEFT_UPPER, 60);
    }
    else ObjectDelete(0, UIName("tph_tot"));
    ChartRedraw(0);
}

// Label reason dari state eksekusi basket berjalan
string TPHReasonLabel()
{
    string r = g_basket_exec_reason;
    if (r == "TP_SIDE_BUY")     return "TP BUY";
    if (r == "TP_SIDE_SELL")    return "TP SELL";
    if (r == "TP")              return "TP BASKET";
    if (r == "TP_SWEEP")        return (g_basket_exec_side > 0 ? "TP BUY" :
                                        (g_basket_exec_side < 0 ? "TP SELL" : "TP BASKET"));
    if (r == "MAX_FLOATING_SL") return "SL FLOAT";
    if (r == "MANUAL_CLOSEALL") return "MANUAL";
    return (r == "" ? "-" : r);
}

void TPHistoryPush(const double profit, const string reason)
{
    for (int i = MathMin(g_tph_count, TPH_MAX - 1); i > 0; i--)
    { g_tph_val[i] = g_tph_val[i-1]; g_tph_time[i] = g_tph_time[i-1]; g_tph_reason[i] = g_tph_reason[i-1]; }
    g_tph_val[0] = profit; g_tph_time[0] = TimeWIBNow(); g_tph_reason[0] = reason;
    if (g_tph_count < TPH_MAX) g_tph_count++;
    TPHistoryRender();
}

//+------------------------------------------------------------------+
//| EKSEKUTOR BASKET (state machine + retry + verifikasi)             |
//+------------------------------------------------------------------+
string BasketExecNewId()
{
    g_basket_exec_seq++;
    long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
    return StringFormat("%I64d_%s_%I64u_%I64u", login, _Symbol, InpMagic, (ulong)g_basket_exec_seq);
}

void BasketExecLog(const string action, const ulong ticket, const int attempt,
                   const int retcode, const int last_error, const string detail)
{
    string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    if (ticket != 0)
        PrintFormat("%s | BASKET[%s] | %s | ticket=%I64u | attempt=%d | rc=%d | le=%d | %s",
                    ts, g_basket_exec_id, action, (ulong)ticket, attempt, retcode, last_error, detail);
    else
        PrintFormat("%s | BASKET[%s] | %s | rc=%d | le=%d | %s",
                    ts, g_basket_exec_id, action, retcode, last_error, detail);
}

bool BasketExecPositionExists(const ulong ticket)
{
    if (ticket == 0) return false;
    if (!PositionSelectByTicket(ticket)) return false;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
    if (!MagicMatches(PositionGetInteger(POSITION_MAGIC))) return false;
    return true;
}

bool BasketExecOrderExists(const ulong ticket)
{
    if (ticket == 0) return false;
    if (!OrderSelect(ticket)) return false;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
    if (!MagicMatches(OrderGetInteger(ORDER_MAGIC))) return false;
    return true;
}

void BasketExecCollectSnapshot()
{
    ArrayFree(g_basket_exec_pos_tickets);
    ArrayFree(g_basket_exec_pos_attempts);
    ArrayFree(g_basket_exec_pos_last_try);
    ArrayFree(g_basket_exec_ord_tickets);
    ArrayFree(g_basket_exec_ord_attempts);
    ArrayFree(g_basket_exec_ord_last_try);

    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        if (!orderInfo.SelectByIndex(i)) continue;
        if (orderInfo.Symbol() != _Symbol) continue;
        if (!g_basket_ignore_magic && !MagicMatches(orderInfo.Magic())) continue;
        if (!ExecSideMatchOrd((ENUM_ORDER_TYPE)orderInfo.OrderType())) continue;
        int n = ArraySize(g_basket_exec_ord_tickets);
        ArrayResize(g_basket_exec_ord_tickets, n + 1);
        ArrayResize(g_basket_exec_ord_attempts, n + 1);
        ArrayResize(g_basket_exec_ord_last_try, n + 1);
        g_basket_exec_ord_tickets[n] = orderInfo.Ticket();
        g_basket_exec_ord_attempts[n] = 0;
        g_basket_exec_ord_last_try[n] = 0;
    }

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol) continue;
        if (!g_basket_ignore_magic && !MagicMatches(posInfo.Magic())) continue;
        if (!ExecSideMatchPos(posInfo.PositionType())) continue;
        int n = ArraySize(g_basket_exec_pos_tickets);
        ArrayResize(g_basket_exec_pos_tickets, n + 1);
        ArrayResize(g_basket_exec_pos_attempts, n + 1);
        ArrayResize(g_basket_exec_pos_last_try, n + 1);
        g_basket_exec_pos_tickets[n] = posInfo.Ticket();
        g_basket_exec_pos_attempts[n] = 0;
        g_basket_exec_pos_last_try[n] = 0;
    }
}

void BasketExecStart(const string reason, const double profit_snapshot, const int side_filter = 0)
{
    if (g_basket_exec_active) return;
    g_basket_exec_side   = side_filter;
    g_basket_exec_reason = reason;
    // SEMUA penutupan basket dicatat ke TP/SL History.
    // Jalur TP punya mekanisme sendiri (g_tp_*); selain itu pakai selisih balance.
    if (!g_tp_profit_pending_valid && !g_slh_pending)
    {
        g_slh_balance_before = AccountInfoDouble(ACCOUNT_BALANCE);
        g_slh_pending        = true;
    }
    g_basket_exec_active = true;
    g_basket_exec_state = BASKET_EXEC_INIT;
    g_basket_exec_id = BasketExecNewId();
    g_basket_exec_next_check = TimeCurrent();
    g_basket_exec_cycles = 0;
    g_basket_exec_force_cycles = 0;
    g_basket_exec_profit_snapshot = profit_snapshot;
    g_basket_exec_target_snapshot = EffTargetProfit();
    g_basket_peak = 0.0;
    BasketExecLog("START", 0, -1, 0, 0, StringFormat("reason=%s | profit=%.2f | target=%.2f | side=%s", reason, profit_snapshot, EffTargetProfit(),
                  (side_filter == 0 ? "ALL" : (side_filter > 0 ? "BUY" : "SELL"))));
}

void BasketExecResetState()
{
    g_basket_ignore_magic = false;
    g_basket_exec_active = false;
    g_basket_exec_state = BASKET_EXEC_IDLE;
    g_basket_exec_id = "";
    g_basket_exec_next_check = 0;
    g_basket_exec_cycles = 0;
    g_basket_exec_force_cycles = 0;
    g_basket_exec_profit_snapshot = 0.0;
    g_basket_exec_target_snapshot = 0.0;
    g_basket_exec_side = 0;
    ArrayFree(g_basket_exec_pos_tickets);
    ArrayFree(g_basket_exec_pos_attempts);
    ArrayFree(g_basket_exec_pos_last_try);
    ArrayFree(g_basket_exec_ord_tickets);
    ArrayFree(g_basket_exec_ord_attempts);
    ArrayFree(g_basket_exec_ord_last_try);
}

int BasketExecSendOps(const bool force_mode)
{
    trade.SetAsyncMode(true);
    datetime now = TimeCurrent();
    const int max_ops = 999;
    const int min_retry_sec = (force_mode ? 0 : 1);
    int sent = 0;

    for (int i = 0; i < ArraySize(g_basket_exec_ord_tickets) && sent < max_ops; i++)
    {
        ulong t = g_basket_exec_ord_tickets[i];
        if (t == 0) continue;
        if (!BasketExecOrderExists(t)) continue;
        if (g_basket_exec_ord_last_try[i] > 0 && (now - g_basket_exec_ord_last_try[i]) < min_retry_sec) continue;

        g_basket_exec_ord_attempts[i]++;
        g_basket_exec_ord_last_try[i] = now;
        ResetLastError();
        bool ok = trade.OrderDelete(t);
        int rc = (int)trade.ResultRetcode();
        int le = (int)GetLastError();
        BasketExecLog(ok ? "DELETE_SENT_OK" : "DELETE_SENT_FAIL", t, g_basket_exec_ord_attempts[i], rc, le, trade.ResultRetcodeDescription());
        sent++;
    }

    for (int i = 0; i < ArraySize(g_basket_exec_pos_tickets) && sent < max_ops; i++)
    {
        ulong t = g_basket_exec_pos_tickets[i];
        if (t == 0) continue;
        if (!BasketExecPositionExists(t)) continue;
        if (g_basket_exec_pos_last_try[i] > 0 && (now - g_basket_exec_pos_last_try[i]) < min_retry_sec) continue;

        g_basket_exec_pos_attempts[i]++;
        g_basket_exec_pos_last_try[i] = now;
        ResetLastError();
        bool ok = trade.PositionClose(t);
        int rc = (int)trade.ResultRetcode();
        int le = (int)GetLastError();
        BasketExecLog(ok ? "CLOSE_SENT_OK" : "CLOSE_SENT_FAIL", t, g_basket_exec_pos_attempts[i], rc, le, trade.ResultRetcodeDescription());
        sent++;
    }

    return sent;
}

bool BasketExecVerifyCounts(int &out_pos, int &out_ord)
{
    int pos_left = 0;
    int ord_left = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
        if (posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && MagicMatches(posInfo.Magic())
            && ExecSideMatchPos(posInfo.PositionType())) pos_left++;

    for (int i = OrdersTotal() - 1; i >= 0; i--)
        if (orderInfo.SelectByIndex(i) && orderInfo.Symbol() == _Symbol && MagicMatches(orderInfo.Magic())
            && ExecSideMatchOrd((ENUM_ORDER_TYPE)orderInfo.OrderType())) ord_left++;

    out_pos = pos_left;
    out_ord = ord_left;
    return (pos_left == 0 && ord_left == 0);
}

void BasketExecProcess()
{
    if (!g_basket_exec_active) return;
    datetime now = TimeCurrent();
    if (g_basket_exec_next_check > 0 && now < g_basket_exec_next_check) return;

    if (g_basket_exec_state == BASKET_EXEC_INIT)
    {
        // RE-CHECK terakhir sebelum batch close pertama (khusus trigger TP).
        // Bila floating sudah jatuh < target (spike/slippage sejak trigger),
        // BATALKAN eksekusi. Setelah tiket pertama terkirim, proses WAJIB
        // diselesaikan (anti basket pincang).
        if (g_tp_profit_pending_valid && (g_basket_exec_side != 0 ? InpSideTargetProfit : EffTargetProfit()) > 0.0)
        {
            double rc_p = 0.0, rc_bp = 0.0, rc_sp = 0.0; int rc_b = 0, rc_s = 0;
            int rc_n = CountOpenPositions(rc_p, rc_b, rc_s, rc_bp, rc_sp);
            double rc_chk    = (g_basket_exec_side > 0 ? rc_bp : (g_basket_exec_side < 0 ? rc_sp : rc_p));
            int    rc_n_chk  = (g_basket_exec_side > 0 ? rc_b  : (g_basket_exec_side < 0 ? rc_s  : rc_n));
            double rc_target = (g_basket_exec_side != 0 ? InpSideTargetProfit : EffTargetProfit());
            if (rc_n_chk > 0 && rc_chk < rc_target)
            {
                BasketExecLog("ABORT_TP_RECHECK", 0, -1, 0, 0,
                    StringFormat("floating=%.2f < target=%.2f (side=%s) -> batal, tunggu tick berikut", rc_chk, rc_target,
                                 (g_basket_exec_side == 0 ? "ALL" : (g_basket_exec_side > 0 ? "BUY" : "SELL"))));
                g_tp_profit_pending = 0.0;
                g_tp_profit_pending_valid = false;
                g_tp_balance_before = 0.0;
                g_tp_balance_before_valid = false;
                g_slh_pending = false;
                g_slh_balance_before = 0.0;
                BasketExecResetState();
                return;
            }
        }
        BasketExecCollectSnapshot();
        BasketExecLog("INIT", 0, -1, 0, 0, StringFormat("snapshot positions=%d | orders=%d",
                                                        ArraySize(g_basket_exec_pos_tickets),
                                                        ArraySize(g_basket_exec_ord_tickets)));
        g_basket_exec_state = BASKET_EXEC_SEND;
        g_basket_exec_next_check = now;
        return;
    }

    if (g_basket_exec_state == BASKET_EXEC_SEND)
    {
        int sent = BasketExecSendOps(false);
        BasketExecLog("SEND", 0, -1, 0, 0, StringFormat("sent=%d | cycle=%d/%d", sent, g_basket_exec_cycles, (int)InpMaxRetries));
        g_basket_exec_state = BASKET_EXEC_VERIFY;
        g_basket_exec_next_check = now + 2;
        return;
    }

    if (g_basket_exec_state == BASKET_EXEC_VERIFY)
    {
        int pos_left = 0, ord_left = 0;
        bool clean = BasketExecVerifyCounts(pos_left, ord_left);
        if (clean)
        {
            BasketExecLog("VERIFY_PASS", 0, -1, 0, 0, "positions=0 | orders=0");
            g_basket_exec_state = BASKET_EXEC_DONE;
            g_basket_exec_next_check = now;
            return;
        }

        BasketExecLog("VERIFY_FAIL", 0, -1, 0, 0, StringFormat("positions=%d | orders=%d", pos_left, ord_left));

        g_basket_exec_cycles++;
        if (g_basket_exec_cycles >= InpMaxRetries)
        {
            g_basket_exec_state = BASKET_EXEC_FORCE;
            g_basket_exec_next_check = now;
            return;
        }

        BasketExecCollectSnapshot();
        g_basket_exec_state = BASKET_EXEC_SEND;
        g_basket_exec_next_check = now;
        return;
    }

    if (g_basket_exec_state == BASKET_EXEC_FORCE)
    {
        int sent = BasketExecSendOps(true);
        BasketExecLog("FORCE_SEND", 0, -1, 0, 0, StringFormat("sent=%d | force_cycle=%d", sent, g_basket_exec_force_cycles));
        g_basket_exec_force_cycles++;
        int pos_left = 0, ord_left = 0;
        bool clean = BasketExecVerifyCounts(pos_left, ord_left);
        if (clean)
        {
            BasketExecLog("FORCE_PASS", 0, -1, 0, 0, "positions=0 | orders=0");
            g_basket_exec_state = BASKET_EXEC_DONE;
            g_basket_exec_next_check = now;
            return;
        }

        if (g_basket_exec_force_cycles >= (InpMaxRetries * 2))
        {
            BasketExecLog("UNRESOLVED_REMAINS", 0, -1, 0, 0,
                StringFormat("positions=%d | orders=%d — TETAP coba clear, tahan siklus", pos_left, ord_left));
            BasketExecCollectSnapshot();
            g_basket_exec_next_check = now + 5;   // lambatkan retry, tetap di state FORCE
            return;                                // TIDAK ke DONE -> siklus tertahan
        }

        BasketExecCollectSnapshot();
        g_basket_exec_next_check = now + 1;
        return;
    }

    if (g_basket_exec_state == BASKET_EXEC_DONE)
    {
        // GERBANG VERIFIKASI AKHIR: pastikan benar-benar CLEAR dulu
        int pos_left = 0, ord_left = 0;
        bool clean = BasketExecVerifyCounts(pos_left, ord_left);
        if (!clean)
        {
            BasketExecLog("DONE_RECHECK_FAIL", 0, -1, 0, 0,
                StringFormat("positions=%d | orders=%d — belum clear, ulangi", pos_left, ord_left));
            BasketExecCollectSnapshot();
            g_basket_exec_state = BASKET_EXEC_FORCE;
            g_basket_exec_next_check = now + 2;
            return;
        }

        BasketExecLog("DONE", 0, -1, 0, 0, "cleanup completed");

        if (g_tp_profit_pending_valid)
        {
            const double bal_after = AccountInfoDouble(ACCOUNT_BALANCE);
            double tp_result = 0.0;
            if (g_tp_balance_before_valid)
            {
                tp_result = bal_after - g_tp_balance_before;
                g_tp_profit_accum += tp_result;
            }
            else
            {
                tp_result = g_tp_profit_pending;
                g_tp_profit_accum += g_tp_profit_pending;
            }
            g_tp_hit_count++;
            g_tp_profit_pending = 0.0;
            g_tp_profit_pending_valid = false;
            g_tp_balance_before = 0.0;
            g_tp_balance_before_valid = false;
            TPHistoryPush(tp_result, TPHReasonLabel());
        }

        // Penutupan basket non-TP (SL basket, manual close all) dicatat realized.
        if (g_slh_pending)
        {
            double cl_result = AccountInfoDouble(ACCOUNT_BALANCE) - g_slh_balance_before;
            g_slh_pending        = false;
            g_slh_balance_before = 0.0;
            TPHistoryPush(cl_result, TPHReasonLabel());
            PrintFormat("TP/SL HISTORY: penutupan basket dicatat %.2f", cl_result);
        }

        if (g_basket_exec_side != 0)
        {
            // Penutupan PER SISI selesai — reset state sisi itu saja.
            int sd = (g_basket_exec_side > 0) ? 0 : 1;
            g_side_peak[sd]        = 0.0;
            g_side_last_modify[sd] = 0;
            g_side_last_parked[sd] = 0.0;
            g_unified_exit_active  = false;   // paksa hitung ulang unified utk sisa basket
            g_unified_last_target_profit_valid = false;
            g_unified_modify_passes_left = 1;
            // Bila sisi ini ternyata satu-satunya sisi (basket kini FLAT TOTAL),
            // reset PENUH SEKARANG — jangan tunggu monitor melihat open=0.
            if (CountOpenPositions() == 0)
            {
                Print("SWEEP/TP-SIDE DONE: basket flat total -> reset penuh siklus (peak bersih)");
                ResetAfterClearPositions();
            }
            else
                PrintFormat("TP-SIDE DONE: sisi %s ditutup tuntas — sisi lain lanjut", (sd == 0 ? "BUY" : "SELL"));
        }
        else
            ResetAfterClearPositions();

        int pause_sec = InpBasketTPPauseSec;
        if (pause_sec < 0) pause_sec = -pause_sec;
        g_basket_pause_until = TimeCurrent() + (datetime)pause_sec;

        bool stop_after = g_stop_after_closeall;
        g_stop_after_closeall = false;
        BasketExecResetState();

        if (stop_after)
            ExpertRemove();
        return;
    }
}

//+------------------------------------------------------------------+
//| PERHITUNGAN HARGA EXIT TERPADU (Unified TP/SL)                    |
//+------------------------------------------------------------------+
bool NeedsUnifiedExitModify(const double close_bid, const double close_ask, const int dir)
{
    if (!EffBasketTPReal()) return false;
    if (dir == 0) return false;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (point <= 0.0) point = 1e-9;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;

        double desired_sl = 0.0;
        double desired_tp = 0.0;

        if (dir > 0)
        {
            if (posInfo.PositionType() == POSITION_TYPE_BUY)       desired_tp = close_bid;
            else if (posInfo.PositionType() == POSITION_TYPE_SELL) desired_sl = close_ask;
        }
        else
        {
            if (posInfo.PositionType() == POSITION_TYPE_SELL)      desired_tp = close_ask;
            else if (posInfo.PositionType() == POSITION_TYPE_BUY)  desired_sl = close_bid;
        }

        double cur_sl = posInfo.StopLoss();
        double cur_tp = posInfo.TakeProfit();

        if (desired_sl > 0.0 && (cur_sl <= 0.0 || MathAbs(cur_sl - desired_sl) > point)) return true;
        if (desired_tp > 0.0 && (cur_tp <= 0.0 || MathAbs(cur_tp - desired_tp) > point)) return true;
    }
    return false;
}

bool ApplyUnifiedExitForBasket(const double target_profit, const double current_total_profit, const bool do_modify, const int side = 0)
{
    if (target_profit <= 0.0) return false;
    if (current_total_profit >= target_profit) return false;

    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tick_value = GetTickValueProfit();
    if (tick_size <= 0.0 || tick_value <= 0.0) return false;

    double buy_volume = 0.0;
    double sell_volume = 0.0;
    int total_positions = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (side > 0 && posInfo.PositionType() != POSITION_TYPE_BUY)  continue;
        if (side < 0 && posInfo.PositionType() != POSITION_TYPE_SELL) continue;

        double v = posInfo.Volume();
        if (v <= 0.0) continue;

        total_positions++;
        if (posInfo.PositionType() == POSITION_TYPE_BUY)
            buy_volume += v;
        else if (posInfo.PositionType() == POSITION_TYPE_SELL)
            sell_volume += v;
    }

    if (total_positions <= 0) return false;

    double net_volume = buy_volume - sell_volume;
    double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double net_eps = (vol_step > 0.0 ? vol_step * 0.5 : 1e-9);
    if (MathAbs(net_volume) <= net_eps)
    {
        g_unified_exit_active = false;
        g_unified_exit_dir = 0;
        g_unified_exit_bid = 0.0;
        g_unified_exit_ask = 0.0;
        if (!do_modify) return false;
        bool sent_any = false;
        for (int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if (!posInfo.SelectByIndex(i)) continue;
            if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
            if (posInfo.StopLoss() <= 0.0 && posInfo.TakeProfit() <= 0.0) continue;
            sent_any = trade.PositionModify(posInfo.Ticket(), 0.0, 0.0) || sent_any;
        }
        return sent_any;
    }

    double need_profit = target_profit - current_total_profit;
    if (need_profit <= 0.0) return false;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    int stops_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double min_dist = (stops_level_pts + 1) * point;
    double price_delta = need_profit * tick_size / (tick_value * net_volume);

    double spread = ask - bid;
    double close_bid = bid + price_delta;
    if (price_delta > 0.0 && close_bid < ask + min_dist)
        close_bid = ask + min_dist;
    if (price_delta < 0.0 && close_bid > bid - min_dist - spread)
        close_bid = bid - min_dist - spread;

    close_bid = NormalizeDouble(close_bid, digits);
    double close_ask = NormalizeDouble(close_bid + spread, digits);
    if (close_bid <= 0.0 || close_ask <= 0.0) return false;

    g_unified_exit_active = true;
    g_unified_exit_dir = (net_volume > 0.0 ? 1 : -1);
    g_unified_exit_bid = close_bid;
    g_unified_exit_ask = close_ask;

    if (!do_modify) return false;
    bool sent_any = false;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (side > 0 && posInfo.PositionType() != POSITION_TYPE_BUY)  continue;
        if (side < 0 && posInfo.PositionType() != POSITION_TYPE_SELL) continue;

        double desired_sl = 0.0;
        double desired_tp = 0.0;

        if (net_volume > 0.0)
        {
            if (posInfo.PositionType() == POSITION_TYPE_BUY)
                desired_tp = close_bid;
            else if (posInfo.PositionType() == POSITION_TYPE_SELL)
                desired_sl = close_ask;
        }
        else
        {
            if (posInfo.PositionType() == POSITION_TYPE_SELL)
                desired_tp = close_ask;
            else if (posInfo.PositionType() == POSITION_TYPE_BUY)
                desired_sl = close_bid;
        }

        double cur_sl = posInfo.StopLoss();
        double cur_tp = posInfo.TakeProfit();

        bool need_change = false;
        if (desired_sl <= 0.0) { if (cur_sl > 0.0) need_change = true; }
        else                   { if (MathAbs(cur_sl - desired_sl) > point) need_change = true; }

        if (desired_tp <= 0.0) { if (cur_tp > 0.0) need_change = true; }
        else                   { if (MathAbs(cur_tp - desired_tp) > point) need_change = true; }

        if (!need_change) continue;

        sent_any = trade.PositionModify(posInfo.Ticket(), desired_sl, desired_tp) || sent_any;
    }

    return sent_any;
}

//+------------------------------------------------------------------+
//| SWEEP TP PARSIAL — deteksi & akumulasi profit TP broker           |
//+------------------------------------------------------------------+
bool RecentBrokerTPClose(const int window_sec, int &out_side)
{
    out_side = 0;
    bool found = false, hit_buy = false, hit_sell = false;
    datetime now = TimeCurrent();
    if (!HistorySelect(now - 300, now + 60)) return false;
    for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
    {
        ulong tk = HistoryDealGetTicket(i);
        if (tk == 0) continue;
        if ((datetime)HistoryDealGetInteger(tk, DEAL_TIME) < now - window_sec) break;
        if (HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
        if (!MagicMatches(HistoryDealGetInteger(tk, DEAL_MAGIC))) continue;
        if ((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
        if ((ENUM_DEAL_REASON)HistoryDealGetInteger(tk, DEAL_REASON) != DEAL_REASON_TP) continue;
        found = true;
        ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE);
        if (dt == DEAL_TYPE_SELL) hit_buy = true;   // deal SELL menutup posisi BUY
        else if (dt == DEAL_TYPE_BUY) hit_sell = true;
    }
    if (hit_buy && !hit_sell) out_side = +1;
    else if (hit_sell && !hit_buy) out_side = -1;
    return found;
}

double SumRecentBrokerTPProfit(const int window_sec)
{
    double sum = 0.0;
    datetime now = TimeCurrent();
    if (!HistorySelect(now - 300, now + 60)) return 0.0;
    for (int i = HistoryDealsTotal() - 1; i >= 0; i--)
    {
        ulong tk = HistoryDealGetTicket(i);
        if (tk == 0) continue;
        if ((datetime)HistoryDealGetInteger(tk, DEAL_TIME) < now - window_sec) break;
        if (HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
        if (!MagicMatches(HistoryDealGetInteger(tk, DEAL_MAGIC))) continue;
        if ((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
        if ((ENUM_DEAL_REASON)HistoryDealGetInteger(tk, DEAL_REASON) != DEAL_REASON_TP) continue;
        sum += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) + HistoryDealGetDouble(tk, DEAL_COMMISSION);
    }
    return sum;
}

//+------------------------------------------------------------------+
//| FILTER MAX FLOATING (SL BASKET).                                  |
//| Bila total floating (profit+swap+komisi) seluruh posisi pada      |
//| symbol ini <= -InpMaxFloatingLoss -> CLOSE ALL via jalur resmi.    |
//| TIDAK stop EA. Latch g_maxfloat_fired anti-dobel.                 |
//+------------------------------------------------------------------+
void MaxFloatingRefresh()
{
    if (InpMaxFloatingLoss <= 0.0) return;
    if (g_maxfloat_fired || g_basket_exec_active || is_processing) return;

    double tp_, bp_, sp_; int bc_ = 0, sc_ = 0;
    CountOpenPositions(tp_, bc_, sc_, bp_, sp_);
    if ((bc_ + sc_) <= 0) return;

    if (tp_ <= -InpMaxFloatingLoss)
    {
        g_maxfloat_fired = true;
        g_tp_profit_pending = 0.0;       g_tp_profit_pending_valid = false;
        g_tp_balance_before = 0.0;       g_tp_balance_before_valid = false;
        Print(StringFormat("FILTER MAX FLOATING: floating %.2f <= -%.2f — CLOSE ALL",
                           tp_, InpMaxFloatingLoss));
        BasketExecStart("MAX_FLOATING_SL", 0.0);
    }
}

//+------------------------------------------------------------------+
//| GARIS VISUAL TP (hanya saat mode VIRTUAL)                         |
//+------------------------------------------------------------------+
string BasketLineTPName()      { return UIName("tpsl_tp"); }
string BasketLineLabelTPName() { return UIName("tpsl_tp_lbl"); }
string SideLineBName()         { return UIName("tpsl_sb"); }
string SideLineSName()         { return UIName("tpsl_ss"); }
string SideLineBLblName()      { return UIName("tpsl_sb_lbl"); }
string SideLineSLblName()      { return UIName("tpsl_ss_lbl"); }

void BasketTPSLVisDeleteAll()
{
    ObjectDelete(0, BasketLineTPName());
    ObjectDelete(0, BasketLineLabelTPName());
}

void SideTPVisDeleteAll()
{
    ObjectDelete(0, SideLineBName());  ObjectDelete(0, SideLineBLblName());
    ObjectDelete(0, SideLineSName());  ObjectDelete(0, SideLineSLblName());
}
void SideTPVisDeleteOne(const int sd)
{
    if (sd == 0) { ObjectDelete(0, SideLineBName()); ObjectDelete(0, SideLineBLblName()); }
    else         { ObjectDelete(0, SideLineSName()); ObjectDelete(0, SideLineSLblName()); }
}

bool BasketTPSLVisEnsureLine(const string name, const double price, const color clr,
                             const string label_name, const string label_text)
{
    if (ObjectFind(0, name) < 0)
    {
        if (!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price)) return false;
        ObjectSetInteger(0, name, OBJPROP_BACK,       true);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
        ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
        ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_DASH);
        ObjectSetInteger(0, name, OBJPROP_ZORDER,     2);
        ObjectSetString(0,  name, OBJPROP_TOOLTIP,    label_text);
    }
    double cur = ObjectGetDouble(0, name, OBJPROP_PRICE);
    if (MathAbs(cur - price) > 0.0)
        ObjectSetDouble(0, name, OBJPROP_PRICE, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);

    if (ObjectFind(0, label_name) < 0)
    {
        if (!ObjectCreate(0, label_name, OBJ_TEXT, 0, TimeCurrent(), price)) return true;
        ObjectSetInteger(0, label_name, OBJPROP_BACK,       true);
        ObjectSetInteger(0, label_name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, label_name, OBJPROP_HIDDEN,     true);
        ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE,   7);
        ObjectSetString(0,  label_name, OBJPROP_FONT,       "Courier New");
        ObjectSetInteger(0, label_name, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
        ObjectSetInteger(0, label_name, OBJPROP_ZORDER,     3);
    }
    ObjectSetDouble(0,  label_name, OBJPROP_PRICE,   price);
    ObjectSetInteger(0, label_name, OBJPROP_TIME,    TimeCurrent());
    ObjectSetString(0,  label_name, OBJPROP_TEXT,    " " + label_text);
    ObjectSetInteger(0, label_name, OBJPROP_COLOR,   clr);
    return true;
}

void SideTPVisSync()
{
    if (EffSideTPReal() || InpSideTargetProfit <= 0.0) { SideTPVisDeleteAll(); return; }

    double tp_ = 0.0, bp_ = 0.0, sp_ = 0.0; int b_ = 0, s_ = 0;
    CountOpenPositions(tp_, b_, s_, bp_, sp_);
    if (b_ <= 0 || s_ <= 0) { SideTPVisDeleteAll(); return; }

    double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tick_value = GetTickValueProfit();
    if (tick_size <= 0.0 || tick_value <= 0.0) { SideTPVisDeleteAll(); return; }

    double buy_volume = 0.0, sell_volume = 0.0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (posInfo.PositionType() == POSITION_TYPE_BUY)       buy_volume  += posInfo.Volume();
        else if (posInfo.PositionType() == POSITION_TYPE_SELL) sell_volume += posInfo.Volume();
    }

    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    for (int sd = 0; sd < 2; sd++)
    {
        double side_profit = (sd == 0) ? bp_ : sp_;
        double side_netvol = (sd == 0) ? buy_volume : -sell_volume;
        double need = InpSideTargetProfit - side_profit;
        if (need <= 0.0 || MathAbs(side_netvol) < 1e-9) { SideTPVisDeleteOne(sd); continue; }

        double price = NormalizeDouble(bid + need * tick_size / (tick_value * side_netvol), digits);
        if (price <= 0.0) { SideTPVisDeleteOne(sd); continue; }

        if (sd == 0)
            BasketTPSLVisEnsureLine(SideLineBName(), price, clrLimeGreen, SideLineBLblName(),
                                    StringFormat("TP-SIDE BUY %.2f", InpSideTargetProfit));
        else
            BasketTPSLVisEnsureLine(SideLineSName(), price, clrOrangeRed, SideLineSLblName(),
                                    StringFormat("TP-SIDE SELL %.2f", InpSideTargetProfit));
    }
}

void BasketTPSLVisSync()
{
    if (!InpShowUI) { BasketTPSLVisDeleteAll(); SideTPVisDeleteAll(); return; }
    SideTPVisSync();
    if (EffBasketTPReal()) { BasketTPSLVisDeleteAll(); return; }

    double total_profit = 0.0, buy_profit = 0.0, sell_profit = 0.0;
    int buy_pos = 0, sell_pos = 0;
    int open_positions = CountOpenPositions(total_profit, buy_pos, sell_pos, buy_profit, sell_profit);

    if (open_positions <= 0 || EffTargetProfit() <= 0.0) { BasketTPSLVisDeleteAll(); return; }

    double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tick_value = GetTickValueProfit();
    if (tick_size <= 0.0 || tick_value <= 0.0) { BasketTPSLVisDeleteAll(); return; }

    double buy_volume = 0.0, sell_volume = 0.0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        double v = posInfo.Volume();
        if (v <= 0.0) continue;
        if (posInfo.PositionType() == POSITION_TYPE_BUY)       buy_volume  += v;
        else if (posInfo.PositionType() == POSITION_TYPE_SELL) sell_volume += v;
    }

    double net_volume = buy_volume - sell_volume;
    double vol_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double net_eps    = (vol_step > 0.0 ? vol_step * 0.5 : 1e-9);
    if (MathAbs(net_volume) <= net_eps) { BasketTPSLVisDeleteAll(); return; }

    double need_profit = EffTargetProfit() - total_profit;
    if (need_profit <= 0.0) { BasketTPSLVisDeleteAll(); return; }

    double point           = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    digits          = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    int    stops_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double ask             = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid             = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread          = ask - bid;
    double min_dist        = (stops_level_pts + 1) * point;

    double price_delta = need_profit * tick_size / (tick_value * net_volume);
    double close_bid   = bid + price_delta;
    if (price_delta > 0.0 && close_bid < ask + min_dist)
        close_bid = ask + min_dist;
    if (price_delta < 0.0 && close_bid > bid - min_dist - spread)
        close_bid = bid - min_dist - spread;
    close_bid          = NormalizeDouble(close_bid, digits);
    double close_ask   = NormalizeDouble(close_bid + spread, digits);
    if (close_bid <= 0.0 || close_ask <= 0.0) { BasketTPSLVisDeleteAll(); return; }

    double tp_price = (net_volume > 0.0) ? close_bid : close_ask;
    string tp_lbl = StringFormat("Basket TP%d  +%.2f$", BasketTPTier() + 1, EffTargetProfit());
    BasketTPSLVisEnsureLine(BasketLineTPName(), tp_price, clrYellow, BasketLineLabelTPName(), tp_lbl);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| PANEL UI "GRID CLASSIC"                                          |
//| Tiru dari panel HEDGING (Bang iNo) lalu DISESUAIKAN dengan cara   |
//| kerja EA GRID CLASSIC. MURNI TAMPILAN — hanya membaca state,      |
//| tidak pernah mengubah state maupun memanggil trade.* (kecuali     |
//| tombol CLOSE ALL yang memakai jalur resmi BasketExec).            |
//+------------------------------------------------------------------+
#define CLR_BG      C'11,18,32'
#define CLR_BG2     C'17,26,43'
#define CLR_BORDER  C'30,58,95'
#define CLR_SEP     C'30,58,95'
#define CLR_HDRBAR  C'20,38,66'
#define CLR_TXT     C'220,230,245'
#define CLR_DIM     C'122,138,165'
#define CLR_GREEN   C'0,224,138'
#define CLR_RED     C'255,77,94'
#define CLR_YELLOW  C'255,197,66'
#define CLR_BLUE    C'77,166,255'
#define CLR_ORANGE  C'255,154,60'
#define CLR_PURPLE  C'170,120,255'
#define CLR_CYAN    C'0,220,220'
#define CLR_TRACK   C'26,40,64'
#define CLR_PAIR    C'150,205,255'
#define CLR_MAGIC   C'225,90,215'
#define CLR_MODE    C'170,255,60'
#define CLR_W_POS   C'225,90,215'   // magenta — jejak posisi terburuk

//--- deklarasi maju (dipakai panel, didefinisikan di blok ENTRY GRID CLASSIC)
double GridLastEntryPrice(const int dir);

//--- pembungkus objek panel
void PnlLbl(const string sfx, const int x, const int y, const string txt,
            const int fsz, const color clr, const ENUM_ANCHOR_POINT anc)
{
    UIEnsureLabel(sfx, x, y, txt, fsz, clr, "Consolas", anc, 110);
}

void PnlDel(const string sfx) { ObjectDelete(0, UIName(sfx)); }

int PnlBtnW(const string txt, const int fsz) { return UITextW(txt, fsz) + UIS(24); }

void PnlActionBtn(const string sfx, const int x, const int y, const int bw, const int bh,
                  const string txt, const color accent, const bool usable)
{
    color cl = usable ? accent : CLR_DIM;
    color bd = usable ? accent : CLR_BORDER;
    UIEnsureRect(sfx + "_btn", x, y, bw, bh, CLR_BG2, bd, 106);
    PnlLbl(sfx + "_txt", x + bw / 2, y + bh / 2, txt, UIFont(9), cl, ANCHOR_CENTER);
    ObjectSetInteger(0, UIName(sfx + "_btn"), OBJPROP_SELECTABLE, usable);
    ObjectSetInteger(0, UIName(sfx + "_txt"), OBJPROP_SELECTABLE, usable);
}

void PnlToggle(const string sfx, const int x, const int y, const int bw, const int bh,
               const bool enabled, const bool usable)
{
    color cl, bd;
    if (!usable)      { cl = CLR_DIM;   bd = CLR_BORDER; }
    else if (enabled) { cl = CLR_GREEN; bd = CLR_GREEN;  }
    else              { cl = CLR_DIM;   bd = CLR_BORDER; }
    UIEnsureRect(sfx + "_btn", x, y, bw, bh, CLR_BG2, bd, 106);
    PnlLbl(sfx + "_txt", x + bw / 2, y + bh / 2, (enabled && usable) ? "ON" : "OFF",
           UIFont(9), cl, ANCHOR_CENTER);
    ObjectSetInteger(0, UIName(sfx + "_btn"), OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0, UIName(sfx + "_txt"), OBJPROP_SELECTABLE, true);
}

//--- gradasi P/L
color PLColorGrad(const double v)
{
    if (v > 0.0)  return CLR_GREEN;
    if (v == 0.0) return CLR_DIM;
    return CLR_RED;
}

//--- nama hari & bulan (WIB)
string HariID(const int dow)
{
    switch (dow)
    {
        case 0: return "Minggu"; case 1: return "Senin"; case 2: return "Selasa";
        case 3: return "Rabu";   case 4: return "Kamis"; case 5: return "Jumat";
        default: return "Sabtu";
    }
}
string BulanID(const int m)
{
    switch (m)
    {
        case 1: return "Januari";  case 2: return "Februari"; case 3: return "Maret";
        case 4: return "April";    case 5: return "Mei";      case 6: return "Juni";
        case 7: return "Juli";     case 8: return "Agustus";  case 9: return "September";
        case 10:return "Oktober";  case 11:return "November"; default: return "Desember";
    }
}

string RunTimeText()
{
    long sec = (long)(TimeCurrent() - g_ea_start_time);
    if (sec < 0) sec = 0;
    long d = sec / 86400; sec -= d * 86400;
    long h = sec / 3600;  sec -= h * 3600;
    long m = sec / 60;    sec -= m * 60;
    return StringFormat("%03d:%02d:%02d:%02d", (int)d, (int)h, (int)m, (int)sec);
}

string GridSideText()
{
    if (InpGridSide == GRID_BUY_ONLY)  return "BUY ONLY";
    if (InpGridSide == GRID_SELL_ONLY) return "SELL ONLY";
    if (InpGridSide == GRID_AUTO)      return "AUTO";
    return "BUY & SELL";
}

string GridRegimeText()
{
    if (InpGridSide != GRID_AUTO) return "-";
    switch (g_auto_regime)
    {
        case MKT_BULL_STRONG: return "BULL  (S&D)";
        case MKT_BEAR_STRONG: return "BEAR  (S&D)";
        case MKT_BREAKOUT:    return "BREAKOUT (MOM)";
        default:              return "SIDEWAY (S&R)";
    }
}

color GridRegimeColor()
{
    switch (g_auto_regime)
    {
        case MKT_BULL_STRONG: return CLR_GREEN;
        case MKT_BEAR_STRONG: return CLR_RED;
        case MKT_BREAKOUT:    return CLR_ORANGE;
        default:              return CLR_YELLOW;
    }
}

//--- total lot per sisi
void GridSideLot(double &b_lot, double &s_lot)
{
    b_lot = 0.0; s_lot = 0.0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (posInfo.PositionType() == POSITION_TYPE_BUY)       b_lot += posInfo.Volume();
        else if (posInfo.PositionType() == POSITION_TYPE_SELL) s_lot += posInfo.Volume();
    }
}

//--- harga entry rata-rata per sisi
double GridAvgEntry(const int dir)
{
    double sum = 0.0, vol = 0.0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (dir > 0 && posInfo.PositionType() != POSITION_TYPE_BUY)  continue;
        if (dir < 0 && posInfo.PositionType() != POSITION_TYPE_SELL) continue;
        sum += posInfo.PriceOpen() * posInfo.Volume();
        vol += posInfo.Volume();
    }
    return (vol > 0.0) ? sum / vol : 0.0;
}

//--- harga re-entry berikutnya (posisi terakhir -/+ jarak grid)
double GridNextEntry(const int dir)
{
    double last = GridLastEntryPrice(dir);
    if (last <= 0.0) return 0.0;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (point <= 0.0) point = 1e-9;
    double dist = (double)InpGridDistancePoints * point;
    return (dir > 0) ? (last - dist) : (last + dist);
}

//--- Selisih harga HARIAN (vs open hari ini). MURNI KOSMETIK untuk panel.
//    Return: delta harga mentah (dalam poin harga, bukan point). 0 bila gagal.
double DailyChangeRaw()
{
    double open_today = iOpen(_Symbol, PERIOD_D1, 0);
    if (open_today <= 0.0) return 0.0;
    double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    if (price <= 0.0) price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if (price <= 0.0) return 0.0;
    return price - open_today;
}

string PanelStatusText(color &out_clr)
{
    if (IsEAExpired())              { out_clr = CLR_DIM;    return "EXPIRED"; }
    if (g_basket_exec_active)       { out_clr = CLR_BLUE;   return "CLOSING " + TPHReasonLabel(); }
    if (IsBasketPauseActive())      { out_clr = CLR_PURPLE; return StringFormat("PAUSE %ds", (int)(g_basket_pause_until - TimeCurrent())); }
    if (g_maxfloat_fired)           { out_clr = CLR_ORANGE; return "SL BASKET"; }
    if (!IsAlgoTradingAllowedNow()) { out_clr = CLR_DIM;    return "OFF"; }
    out_clr = CLR_GREEN;            return "NORMAL";
}

void PnlPreCreateRects(const int px, const int py)
{
    if (g_pnl_inited) return;
    string rects[] = {"pnl_bg", "hdrbar", "st_bg",
                      "z0", "z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8", "z9", "z10",
                      "s1", "s2", "s3", "s4", "s5", "s6",
                      "e_trk", "e_fil",
                      "ca_btn"};
    for (int i = 0; i < ArraySize(rects); i++)
        UIEnsureRect(rects[i], px, py, 1, 1, CLR_BG, CLR_BG, 100);
    g_pnl_inited = true;
}

//+------------------------------------------------------------------+
//| RENDER PANEL GRID CLASSIC                                         |
//+------------------------------------------------------------------+
void PanelRender()
{
    if (!InpShowUI) return;

    int px = UIS(18);
    int py = UIS(40);
    string title = "GRID CLASSIC v" + EA_VERSION;

    PnlPreCreateRects(px, py);

    //---------------- MODE DILIPAT ----------------
    if (g_pnl_collapsed)
    {
        string dead[] = {"st", "mg", "mode_txt", "mg_id",
                         "l_sts", "l_grid", "l_pos", "l_exi", "l_akn", "l_wkt",
                         "g_side_l", "g_side_v", "g_reg_l", "g_reg_v", "g_lot_l", "g_lot_v", "g_dist_l", "g_dist_v",
                         "g_max_l", "g_max_v", "g_nb_l", "g_nb_v", "g_ns_l", "g_ns_v", "g_day_l", "g_day_v",
                         "h0", "h1", "h2",
                         "l_pos1", "l_lot1", "l_pl1", "l_avg1",
                         "e_tp_l", "e_tp_v", "e_pk_l", "e_pk_v", "e_ws_l", "e_ws_v",
                         "l_wst", "l_wpos", "l_wlot", "l_wpl", "wh0", "wh1", "wh2",
                         "a_bal_l", "a_bal_v", "a_eq_l", "a_eq_v",
                         "w_date", "w_time", "w_run_l", "w_run_v", "ca_txt", "pnl_cpy"};
        for (int i = 0; i < ArraySize(dead); i++) PnlDel(dead[i]);
        for (int c = 0; c < 3; c++)
        {
            PnlDel("p1_" + (string)c); PnlDel("o1_" + (string)c);
            PnlDel("g1_" + (string)c); PnlDel("v1_" + (string)c);
            PnlDel("wp_" + (string)c); PnlDel("wo_" + (string)c); PnlDel("wg_" + (string)c);
        }
        string hide[] = {"hdrbar", "st_bg", "z0", "z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8", "z9", "z10",
                         "s1", "s2", "s3", "s4", "s5", "s6", "ca_btn", "e_trk", "e_fil"};
        for (int i = 0; i < ArraySize(hide); i++)
            UIEnsureRect(hide[i], px, py, 1, 1, CLR_BG, CLR_BG, 100);

        string s_copy_c = "Copyright : by \"Bang iNo\"";
        int wc = UIS(30) + UITextW(title, UIFont(13)) + UIS(16)
               + UITextW(s_copy_c, UIFont(10)) + UIS(10);
        g_pnl_panel_w = wc;
        UIEnsureRect("pnl_bg", px, py, wc, UIS(30), CLR_BG, CLR_BORDER, 100);
        PnlLbl("pnl_btn", px + UIS(8), py + UIS(7), "[+]", UIFont(10), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("pnl_ttl", px + UIS(30), py + UIS(7), title, UIFont(13), CLR_TXT, ANCHOR_LEFT_UPPER);
        PnlLbl("pnl_cpy", px + wc - UIS(10), py + UIS(9), s_copy_c, UIFont(10), CLR_DIM, ANCHOR_RIGHT_UPPER);
        ObjectSetInteger(0, UIName("pnl_btn"), OBJPROP_SELECTABLE, true);
        ChartRedraw(0);
        return;
    }

    //================= DATA (read-only) =================
    double t_pl = 0.0, b_pl = 0.0, s_pl = 0.0;
    int b_cnt = 0, s_cnt = 0;
    CountOpenPositions(t_pl, b_cnt, s_cnt, b_pl, s_pl);

    double b_lot = 0.0, s_lot = 0.0;
    GridSideLot(b_lot, s_lot);

    double b_avg = GridAvgEntry(+1);
    double s_avg = GridAvgEntry(-1);

    string hdr[3] = {"BUY", "SELL", "TOTAL"};
    string pos1[3], lot1[3], pl1[3], avg1[3];
    pos1[0] = (string)b_cnt;  pos1[1] = (string)s_cnt;  pos1[2] = (string)(b_cnt + s_cnt);
    lot1[0] = StringFormat("%.2f", b_lot); lot1[1] = StringFormat("%.2f", s_lot); lot1[2] = StringFormat("%.2f", b_lot + s_lot);
    pl1[0]  = StringFormat("%+.2f", b_pl); pl1[1]  = StringFormat("%+.2f", s_pl); pl1[2]  = StringFormat("%+.2f", t_pl);
    avg1[0] = (b_avg > 0.0) ? DoubleToString(b_avg, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) : "-";
    avg1[1] = (s_avg > 0.0) ? DoubleToString(s_avg, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) : "-";
    avg1[2] = "-";

    //--- tabel WORST (jejak terburuk): BUY / SELL / TOTAL
    string wpos[3], wlot[3], wpl[3];
    for (int c = 0; c < 3; c++)
    {
        wpos[c] = (string)g_worst_cnt[c];
        wlot[c] = StringFormat("%.2f", g_worst_lot[c]);
        wpl[c]  = StringFormat("%+.2f", g_worst_pl[c]);
    }
    int tier = BasketTPTier();

    //--- TP efektif (grid TP bila diisi, jika tidak pakai modul EXIT)
    bool  grid_tp_mode = (InpGridBasketTP > 0.0);
    double tp_target   = grid_tp_mode ? InpGridBasketTP : EffTargetProfit();
    string s_tp        = StringFormat("%.2f / %.2f", t_pl, tp_target);
    double tp_r        = (tp_target > 0.0) ? MathMax(0.0, MathMin(1.0, g_basket_peak / tp_target)) : 0.0;
    color  tp_c        = (t_pl < 0.0) ? CLR_RED
                       : (g_basket_peak >= tp_target) ? CLR_GREEN
                       : ((tp_r >= 0.5) ? CLR_YELLOW : CLR_BLUE);

    //--- re-entry berikutnya
    double nb = GridNextEntry(+1);
    double ns = GridNextEntry(-1);
    int    dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    string s_nb = (nb > 0.0) ? DoubleToString(nb, dg) : "-";
    string s_ns = (ns > 0.0) ? DoubleToString(ns, dg) : "-";

    //--- status & identitas
    color  st_c; string st_t = PanelStatusText(st_c);
    string s_pair = _Symbol;
    string s_mgid = StringFormat("#%I64u", InpMagic);

    //--- lebar kolom
    string labels[4] = {"  Posisi", "  Lot", "  P/L", "  Avg entry"};
    int labelw = 0;
    for (int i = 0; i < 4; i++) labelw = MathMax(labelw, UITextW(labels[i], UIFont(11)));

    int colw[3];
    for (int c = 0; c < 3; c++)
    {
        int mw = UITextW(hdr[c], UIFont(11));
        mw = MathMax(mw, UITextW(pos1[c], UIFont(11)));
        mw = MathMax(mw, UITextW(lot1[c], UIFont(11)));
        mw = MathMax(mw, UITextW(pl1[c],  UIFont(11)));
        mw = MathMax(mw, UITextW(avg1[c], UIFont(11)));
        colw[c] = mw;
    }

    int pad = UIS(10);
    int gap = UIS(14);
    int colR[3];
    colR[0] = px + pad + labelw + gap + colw[0];
    colR[1] = colR[0] + gap + colw[1];
    colR[2] = colR[1] + gap + colw[2];

    //--- baris waktu
    MqlDateTime dt; TimeToStruct(TimeWIBNow(), dt);
    string s_date = StringFormat("%s, %d %s %d", HariID(dt.day_of_week), dt.day, BulanID(dt.mon), dt.year);
    string s_time = StringFormat("%02d:%02d:%02d WIB", dt.hour, dt.min, dt.sec);

    //--- lebar panel
    int w = colR[2] - px + pad;
    string s_copy = "Copyright : by \"Bang iNo\"";
    w = MathMax(w, UIS(30) + UITextW(title, UIFont(13)) + UIS(16) + UITextW(s_copy, UIFont(10)) + UIS(10));

    string gl[] = {"Side", "Lot awal", "Jarak grid", "Max grid", "Next BUY", "Next SELL",
                   "Balance", "Equity", "Run time"};
    string gr[] = {GridSideText(), StringFormat("%.2f", InpInitialLot),
                   StringFormat("%d pt", InpGridDistancePoints),
                   StringFormat("%d / %d", b_cnt + s_cnt, InpMaxGridPositions),
                   s_nb, s_ns,
                   StringFormat("%.2f", AccountInfoDouble(ACCOUNT_BALANCE)),
                   StringFormat("%.2f", AccountInfoDouble(ACCOUNT_EQUITY)),
                   RunTimeText()};
    for (int i = 0; i < ArraySize(gl); i++)
        w = MathMax(w, pad + UITextW(gl[i], UIFont(11)) + gap + UITextW(gr[i], UIFont(11)) + pad);

    string wide[] = {"  Avg entry", "Puncak Basket", "Worst Basket", "Daily"};
    for (int i = 0; i < ArraySize(wide); i++)
        w = MathMax(w, pad + UITextW(wide[i], UIFont(11)) + gap + UITextW("0000.00 | +0.00%", UIFont(11)) + pad);

    int btn_f  = UIFont(9);
    int w_ca   = PnlBtnW("CLOSE ALL", btn_f);
    w = MathMax(w, pad + UITextW("STATUS", UIFont(11)) + gap + w_ca + pad);
    w = MathMax(w, pad + UIS(14) + UITextW(st_t, UIFont(11)) + gap
                    + UITextW(s_pair, UIFont(11)) + UIS(8) + UITextW(s_mgid, UIFont(11)) + pad);

    // rata kanan kolom data ke tepi panel
    colR[2] = px + w - pad;
    colR[1] = colR[2] - gap - colw[2];
    colR[0] = colR[1] - gap - colw[1];

    g_pnl_panel_w = w;

    //================= GAMBAR =================
    int rh     = UIS(22);
    int txt_h  = UITextH("0", UIFont(11));
    int btn_h  = rh - UIS(3);
    int btn_dy = (txt_h - btn_h) / 2;
    int y      = py + UIS(30);

    // header bar
    UIEnsureRect("hdrbar", px, py, w, UIS(30), CLR_HDRBAR, CLR_BORDER, 101);
    PnlLbl("pnl_btn", px + UIS(8), py + UIS(7), "[-]", UIFont(10), CLR_DIM, ANCHOR_LEFT_UPPER);
    PnlLbl("pnl_ttl", px + UIS(30), py + UIS(7), title, UIFont(13), CLR_TXT, ANCHOR_LEFT_UPPER);
    PnlLbl("pnl_cpy", px + w - UIS(10), py + UIS(9), s_copy, UIFont(10), CLR_DIM, ANCHOR_RIGHT_UPPER);
    ObjectSetInteger(0, UIName("pnl_btn"), OBJPROP_SELECTABLE, true);

    // ---- STATUS (+ tombol CLOSE ALL rata kanan)
    y += UIS(9);
    PnlLbl("l_sts", px + pad, y, "STATUS", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
    {
        int ca_x = px + w - pad - w_ca;
        PnlActionBtn("ca", ca_x, y + btn_dy, w_ca, btn_h, "CLOSE ALL", CLR_RED, (b_cnt + s_cnt) > 0);
    }
    y += rh;

    UIEnsureRect("st_bg", px + pad, y, UIS(8), txt_h, st_c, st_c, 103);
    PnlLbl("st", px + pad + UIS(14), y, st_t, UIFont(11), st_c, ANCHOR_LEFT_UPPER);
    {
        int mg_r = px + w - pad;
        PnlLbl("mg_id", mg_r, y, s_mgid, UIFont(11), CLR_MAGIC, ANCHOR_RIGHT_UPPER);
        int pair_r = mg_r - UITextW(s_mgid, UIFont(11)) - UIS(8);
        PnlLbl("mg", pair_r, y, s_pair, UIFont(11), CLR_PAIR, ANCHOR_RIGHT_UPPER);
    }
    y += rh;

    UIEnsureRect("s1", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- GRID
    PnlLbl("l_grid", px + pad, y, "GRID", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    {
        int vx = px + w - pad;
        UIEnsureRect("z0", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("g_side_l", px + pad, y, "Side", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_side_v", vx, y, GridSideText(), UIFont(11), CLR_MODE, ANCHOR_RIGHT_UPPER); y += rh;

        if (InpGridSide == GRID_AUTO)
        {
            PnlLbl("g_reg_l", px + pad, y, "Regime", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
            PnlLbl("g_reg_v", vx, y, GridRegimeText(), UIFont(11), GridRegimeColor(), ANCHOR_RIGHT_UPPER); y += rh;
        }
        else { PnlDel("g_reg_l"); PnlDel("g_reg_v"); }

        PnlLbl("g_lot_l", px + pad, y, "Lot awal", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_lot_v", vx, y, StringFormat("%.2f", InpInitialLot), UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER); y += rh;

        UIEnsureRect("z1", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("g_dist_l", px + pad, y, "Jarak grid", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_dist_v", vx, y, StringFormat("%d pt", InpGridDistancePoints), UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER); y += rh;

        PnlLbl("g_max_l", px + pad, y, "Max grid", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_max_v", vx, y, StringFormat("%d / %d", b_cnt + s_cnt, InpMaxGridPositions), UIFont(11),
               ((InpMaxGridPositions > 0 && (b_cnt + s_cnt) >= InpMaxGridPositions) ? CLR_RED : CLR_TXT), ANCHOR_RIGHT_UPPER); y += rh;

        UIEnsureRect("z2", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("g_nb_l", px + pad, y, "Next BUY", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_nb_v", vx, y, s_nb, UIFont(11), CLR_GREEN, ANCHOR_RIGHT_UPPER); y += rh;

        PnlLbl("g_ns_l", px + pad, y, "Next SELL", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("g_ns_v", vx, y, s_ns, UIFont(11), CLR_RED, ANCHOR_RIGHT_UPPER); y += rh;

        // Selisih harga HARIAN (kosmetik): angka mentah | persen. Merah saat
        // minus, biru saat plus. Delta 0 / tidak tersedia -> abu.
        {
            double dchg   = DailyChangeRaw();
            double op_day = iOpen(_Symbol, PERIOD_D1, 0);
            double dpct   = (op_day > 0.0) ? (dchg / op_day * 100.0) : 0.0;
            int    dp     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            color  dclr   = (dchg > 0.0) ? CLR_BLUE : ((dchg < 0.0) ? CLR_RED : CLR_DIM);
            string dtxt   = (op_day > 0.0)
                            ? StringFormat("%s | %+.2f%%", DoubleToString(dchg, dp), dpct)
                            : "-";
            PnlLbl("g_day_l", px + pad, y, "Daily", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
            PnlLbl("g_day_v", vx, y, dtxt, UIFont(11), dclr, ANCHOR_RIGHT_UPPER); y += rh;
        }
    }

    UIEnsureRect("s2", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- POSISI
    PnlLbl("l_pos", px + pad, y, "POSISI", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    for (int c = 0; c < 3; c++)
        PnlLbl("h" + (string)c, colR[c], y, hdr[c], UIFont(11), CLR_DIM, ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("z3", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
    PnlLbl("l_pos1", px + pad, y, "  Posisi", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("p1_" + (string)c, colR[c], y, pos1[c], UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER);
    y += rh;

    PnlLbl("l_lot1", px + pad, y, "  Lot", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("o1_" + (string)c, colR[c], y, lot1[c], UIFont(11), CLR_YELLOW, ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("z4", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
    PnlLbl("l_pl1", px + pad, y, "  P/L", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("g1_" + (string)c, colR[c], y, pl1[c], UIFont(11), PLColorGrad(c == 0 ? b_pl : (c == 1 ? s_pl : t_pl)), ANCHOR_RIGHT_UPPER);
    y += rh;

    PnlLbl("l_avg1", px + pad, y, "  Avg entry", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("v1_" + (string)c, colR[c], y, avg1[c], UIFont(11), CLR_DIM, ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("s3", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- EXIT
    PnlLbl("l_exi", px + pad, y, "EXIT", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    {
        int vx = px + w - pad;
        UIEnsureRect("z5", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("e_tp_l", px + pad, y, grid_tp_mode ? "TP Grid" : "TP Basket", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("e_tp_v", vx, y, s_tp, UIFont(11), tp_c, ANCHOR_RIGHT_UPPER); y += rh;

        PnlLbl("e_pk_l", px + pad, y, "Puncak Basket", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("e_pk_v", vx, y, StringFormat("%.2f", g_basket_peak), UIFont(11), CLR_GREEN, ANCHOR_RIGHT_UPPER); y += rh;

        // Progress bar puncak vs target — BARIS SENDIRI dengan jarak lega,
        // supaya tidak menempel ke teks di atas/bawahnya.
        {
            int bar_h = UIS(8);
            int bar_y = y + UIS(4);
            UIEnsureRect("e_trk", px + pad, bar_y, w - pad * 2, bar_h, CLR_TRACK, CLR_BORDER, 104);
            int fw = (int)MathRound((w - pad * 2) * tp_r);
            if (fw <= 0) UIEnsureRect("e_fil", px + pad, bar_y, 1, 1, CLR_TRACK, CLR_TRACK, 105);
            else         UIEnsureRect("e_fil", px + pad, bar_y, fw, bar_h, tp_c, tp_c, 105);
        }
        y += rh;

        // Worst Basket (peak drawdown) -> tingkat TP berjenjang
        UIEnsureRect("z8", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("e_ws_l", px + pad, y, "Worst Basket", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("e_ws_v", vx, y, StringFormat("%.2f  (TP%d)", g_basket_worst, tier + 1), UIFont(11),
               (g_basket_worst < 0.0 ? CLR_ORANGE : CLR_DIM), ANCHOR_RIGHT_UPPER); y += rh;
    }

    UIEnsureRect("s4", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- JEJAK (WORST) — tabel BUY / SELL / TOTAL, snapshot saat floating
    //      TOTAL paling rendah pada siklus berjalan.
    PnlLbl("l_wst", px + pad, y, "JEJAK (WORST)", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    for (int c = 0; c < 3; c++)
        PnlLbl("wh" + (string)c, colR[c], y, hdr[c], UIFont(11), CLR_DIM, ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("z9", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
    PnlLbl("l_wpos", px + pad, y, "  Posisi", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("wp_" + (string)c, colR[c], y, wpos[c], UIFont(11),
               (g_worst_cnt[c] > 0 ? CLR_W_POS : CLR_DIM), ANCHOR_RIGHT_UPPER);
    y += rh;

    PnlLbl("l_wlot", px + pad, y, "  Lot", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("wo_" + (string)c, colR[c], y, wlot[c], UIFont(11),
               (g_worst_lot[c] > 0.0 ? CLR_YELLOW : CLR_DIM), ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("z10", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
    PnlLbl("l_wpl", px + pad, y, "  P/L", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
    for (int c = 0; c < 3; c++)
        PnlLbl("wg_" + (string)c, colR[c], y, wpl[c], UIFont(11), PLColorGrad(g_worst_pl[c]), ANCHOR_RIGHT_UPPER);
    y += rh;

    UIEnsureRect("s6", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- AKUN
    PnlLbl("l_akn", px + pad, y, "AKUN", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    {
        int vx = px + w - pad;
        double a_bal = AccountInfoDouble(ACCOUNT_BALANCE);
        double a_eq  = AccountInfoDouble(ACCOUNT_EQUITY);
        double a_dd  = (a_bal > 0.0 && a_eq < a_bal) ? ((a_bal - a_eq) / a_bal * 100.0) : 0.0;

        UIEnsureRect("z6", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("a_bal_l", px + pad, y, "Balance", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("a_bal_v", vx, y, StringFormat("%.2f", a_bal), UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER); y += rh;

        PnlLbl("a_eq_l", px + pad, y, "Equity", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("a_eq_v", vx, y, StringFormat("%.2f (%.2f%% DD)", a_eq, a_dd), UIFont(11),
               ((a_dd >= 20.0) ? CLR_RED : ((a_dd >= 5.0) ? CLR_ORANGE : CLR_TXT)), ANCHOR_RIGHT_UPPER); y += rh;
    }

    UIEnsureRect("s5", px, y, w, 1, CLR_SEP, CLR_SEP, 102); y += UIS(8);

    // ---- WAKTU
    PnlLbl("l_wkt", px + pad, y, "WAKTU", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER); y += rh;
    {
        int vx = px + w - pad;
        UIEnsureRect("z7", px + UIS(2), y - UIS(2), w - UIS(4), rh, CLR_BG2, CLR_BG2, 103);
        PnlLbl("w_date", px + pad, y, s_date, UIFont(11), CLR_TXT, ANCHOR_LEFT_UPPER);
        PnlLbl("w_time", vx, y, s_time, UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER); y += rh;

        PnlLbl("w_run_l", px + pad, y, "Run time", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
        PnlLbl("w_run_v", vx, y, RunTimeText(), UIFont(11), CLR_BLUE, ANCHOR_RIGHT_UPPER); y += rh;
    }

    // background induk
    UIEnsureRect("pnl_bg", px, py, w, (y - py) + UIS(6), CLR_BG, CLR_BORDER, 100);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| AUTO SIDE — pemilihan sisi otomatis dari KONDISI MARKET           |
//|                                                                  |
//|  SIDEWAY      -> metode SUPPORT & RESISTANCE  (buy di support,    |
//|                  sell di resistance, tengah range dua arah)       |
//|  STRONG TREND -> metode SUPPLY & DEMAND       (searah tren dari   |
//|                  zona demand/supply)                              |
//|  BREAKOUT     -> metode BREAKOUT MOMENTUM     (M15/H1/H4/D1,      |
//|                  hanya sisi arah breakout)                        |
//|                                                                  |
//| Semua fungsi di sini READ-ONLY (tidak trading). Dipakai murni     |
//| untuk memutuskan sisi mana yang boleh entry pada mode AUTO.       |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES AutoHTF()
{
    if (InpAutoHTF == PERIOD_CURRENT) return (ENUM_TIMEFRAMES)_Period;
    return InpAutoHTF;
}
ENUM_TIMEFRAMES AutoBreakTF()
{
    if (InpAutoBreakTF == PERIOD_CURRENT) return (ENUM_TIMEFRAMES)_Period;
    return InpAutoBreakTF;
}

//--- ATR per timeframe (handle di-cache)
double AutoATR(const ENUM_TIMEFRAMES tf)
{
    static ENUM_TIMEFRAMES htf[16];
    static int             hha[16];
    static int             cnt = 0;
    for (int i = 0; i < cnt; i++)
        if (htf[i] == tf && hha[i] != INVALID_HANDLE)
        {
            double b[1];
            if (CopyBuffer(hha[i], 0, 0, 1, b) > 0) return b[0];
            return 0.0;
        }
    int period = (InpAutoATRPeriod > 0) ? InpAutoATRPeriod : 14;
    int h = iATR(_Symbol, tf, period);
    if (h == INVALID_HANDLE) return 0.0;
    if (cnt < 16) { htf[cnt] = tf; hha[cnt] = h; cnt++; }
    double b[1];
    if (CopyBuffer(h, 0, 0, 1, b) > 0) return b[0];
    return 0.0;
}

//--- deteksi swing high / low (fraktal sederhana) -> array
bool AutoSwingHighs(const ENUM_TIMEFRAMES tf, const int look, const int k, double &out[])
{
    ArrayResize(out, 0);
    for (int i = k; i <= look; i++)
    {
        double hi = iHigh(_Symbol, tf, i);
        if (hi <= 0.0) continue;
        bool is = true;
        for (int j = 1; j <= k && is; j++)
            if (iHigh(_Symbol, tf, i - j) >= hi || iHigh(_Symbol, tf, i + j) >= hi) is = false;
        if (is) { int m = ArraySize(out); ArrayResize(out, m + 1); out[m] = hi; }
    }
    return (ArraySize(out) > 0);
}
bool AutoSwingLows(const ENUM_TIMEFRAMES tf, const int look, const int k, double &out[])
{
    ArrayResize(out, 0);
    for (int i = k; i <= look; i++)
    {
        double lo = iLow(_Symbol, tf, i);
        if (lo <= 0.0) continue;
        bool is = true;
        for (int j = 1; j <= k && is; j++)
            if (iLow(_Symbol, tf, i - j) <= lo || iLow(_Symbol, tf, i + j) <= lo) is = false;
        if (is) { int m = ArraySize(out); ArrayResize(out, m + 1); out[m] = lo; }
    }
    return (ArraySize(out) > 0);
}

//--- range S&R: resistance tertinggi & support terendah dari swing
bool AutoHTFRange(double &res, double &sup, double &mid)
{
    double sh[], sl[];
    int look = (InpAutoSRLookback > 0) ? InpAutoSRLookback : 40;
    int k    = (InpAutoSwingStrength > 0) ? InpAutoSwingStrength : 2;
    if (!AutoSwingHighs(AutoHTF(), look, k, sh)) return false;
    if (!AutoSwingLows (AutoHTF(), look, k, sl)) return false;
    int ns = ArraySize(sh), nn = ArraySize(sl);
    if (ns < 1 || nn < 1) return false;
    res = sh[0]; sup = sl[0];
    for (int i = 1; i < ns; i++) if (sh[i] > res) res = sh[i];
    for (int i = 1; i < nn; i++) if (sl[i] < sup) sup = sl[i];
    mid = (res + sup) / 2.0;
    return (res > sup);
}

//--- BREAKOUT MOMENTUM pada satu timeframe: +1 bull / -1 bear / 0
int AutoBreakoutOnTF(const ENUM_TIMEFRAMES tf)
{
    double atr = AutoATR(tf);
    if (atr <= 0.0) return 0;
    double hi = iHigh(_Symbol, tf, 1);
    double lo = iLow (_Symbol, tf, 1);
    double cl = iClose(_Symbol, tf, 1);
    double op = iOpen (_Symbol, tf, 1);
    if (hi <= 0.0 || lo <= 0.0 || cl <= 0.0 || op <= 0.0) return 0;

    double buf  = InpAutoBreakoutBufferATR * atr;
    int    look = (InpAutoSRLookback > 0) ? InpAutoSRLookback : 20;

    double hh = 0.0, ll = 0.0;
    for (int i = 2; i <= look + 1; i++)
    {
        double h = iHigh(_Symbol, tf, i);
        double l = iLow (_Symbol, tf, i);
        if (h > hh) hh = h;
        if (ll == 0.0 || l < ll) ll = l;
    }
    if (hh <= 0.0 || ll <= 0.0) return 0;

    if (cl > op && cl > hh + buf) return +1;
    if (cl < op && cl < ll - buf) return -1;
    return 0;
}

//--- cari breakout pada M15 / H1 / H4 / D1 (mulai dari TF terdekat)
int AutoBreakoutDir()
{
    ENUM_TIMEFRAMES htf = AutoHTF();
    int dir = AutoBreakoutOnTF(AutoBreakTF());
    if (dir != 0) return dir;

    if (htf != PERIOD_M15) { dir = AutoBreakoutOnTF(PERIOD_M15); if (dir != 0) return dir; }
    if (htf != PERIOD_H1)  { dir = AutoBreakoutOnTF(PERIOD_H1);  if (dir != 0) return dir; }
    if (htf != PERIOD_H4)  { dir = AutoBreakoutOnTF(PERIOD_H4);  if (dir != 0) return dir; }
    if (InpAutoD1Breakout && htf != PERIOD_D1)
    { dir = AutoBreakoutOnTF(PERIOD_D1); if (dir != 0) return dir; }

    return 0;
}

//--- STRONG TREND (Supply & Demand): N candle kuat beruntun searah
int AutoStrongTrendDir()
{
    ENUM_TIMEFRAMES htf = AutoHTF();
    if (AutoATR(htf) <= 0.0) return 0;
    int need = (InpAutoStrongBars > 0) ? InpAutoStrongBars : 3;
    if (need > 10) need = 10;

    int bull = 0, bear = 0;
    for (int i = 1; i <= need; i++)
    {
        double op = iOpen (_Symbol, htf, i);
        double cl = iClose(_Symbol, htf, i);
        double hi = iHigh (_Symbol, htf, i);
        double lo = iLow  (_Symbol, htf, i);
        if (hi <= lo) return 0;
        double body = MathAbs(cl - op);
        double rng  = hi - lo;
        bool strong = (rng > 0.0 && body >= InpAutoStrongBodyRatio * rng);
        if (strong && cl > op)      bull++;
        else if (strong && cl < op) bear++;
    }
    if (bull >= need) return +1;
    if (bear >= need) return -1;
    return 0;
}

//--- BIAS arah (bar terakhir + posisi harga vs mid range)
int AutoBiasDir()
{
    ENUM_TIMEFRAMES htf = AutoHTF();
    int bars = (InpAutoBiasBars > 0) ? InpAutoBiasBars : 3;
    if (bars > 10) bars = 10;

    double c1 = iClose(_Symbol, htf, 1);
    double cN = iClose(_Symbol, htf, 1 + bars);
    if (c1 <= 0.0 || cN <= 0.0) return 0;

    int up = 0, dn = 0;
    for (int i = 1; i <= bars; i++)
    {
        double o = iOpen (_Symbol, htf, i);
        double c = iClose(_Symbol, htf, i);
        if (c > o) up++;
        else if (c < o) dn++;
    }
    if (c1 > cN && up >= dn) return +1;
    if (c1 < cN && dn >= up) return -1;
    return 0;
}

//--- deteksi regime market (urutan prioritas: breakout -> strong -> sideway)
ENUM_MKT_REGIME AutoDetectRegime()
{
    if (AutoATR(AutoHTF()) <= 0.0) return MKT_SIDEWAY;

    int bdir = AutoBreakoutDir();
    if (bdir != 0) return MKT_BREAKOUT;

    int sdir = AutoStrongTrendDir();
    if (sdir > 0) return MKT_BULL_STRONG;
    if (sdir < 0) return MKT_BEAR_STRONG;

    return MKT_SIDEWAY;
}

//--- arah dari zona S&R / S&D: +1 buy (di demand/support), -1 sell (supply/resistance)
int AutoZoneDir()
{
    double atr = AutoATR(AutoHTF());
    if (atr <= 0.0) return 0;
    double res, sup, mid;
    if (!AutoHTFRange(res, sup, mid)) return 0;

    double price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
    if (price <= 0.0) return 0;

    double zone = InpAutoZoneATR * atr;
    if (zone <= 0.0) zone = atr;

    if (price <= sup + zone) return +1;
    if (price >= res - zone) return -1;
    return 0;
}

//--- KEPUTUSAN SISI AUTO (inti)
void AutoSideDecision(bool &buy_en, bool &sell_en, ENUM_MKT_REGIME &regime, int &bias)
{
    regime = AutoDetectRegime();
    bias   = AutoBiasDir();
    buy_en = false; sell_en = false;

    int zone_dir = AutoZoneDir();

    if (regime == MKT_BREAKOUT)
    {
        int bdir = AutoBreakoutDir();
        if (bdir > 0)      buy_en  = true;
        else if (bdir < 0) sell_en = true;
    }
    else if (regime == MKT_BULL_STRONG || regime == MKT_BEAR_STRONG)
    {
        // Supply & Demand — searah tren, entry dari zona demand/supply
        if (zone_dir > 0)      buy_en  = true;
        else if (zone_dir < 0) sell_en = true;
        else
        {
            if (regime == MKT_BULL_STRONG) buy_en  = true;
            else                           sell_en = true;
        }
    }
    else // SIDEWAY — Support & Resistance
    {
        if (zone_dir > 0)      buy_en  = true;
        else if (zone_dir < 0) sell_en = true;
        else { buy_en = true; sell_en = true; }   // tengah range -> dua arah (grid)
    }

    // Opsi: jangan entry melawan bias
    if (InpAutoRespectBias && bias != 0)
    {
        if (bias > 0 && sell_en && !buy_en) sell_en = false;
        if (bias < 0 && buy_en  && !sell_en) buy_en  = false;
    }
}

//+------------------------------------------------------------------+
//| ENTRY GRID CLASSIC                                               |
//| Grid klasik: entry pertama sebesar lot awal, lalu RE-ENTRY tiap   |
//| harga bergerak melawan posisi terakhir SEJAUH jarak grid (poin).  |
//| Lot tetap (tanpa martingale). Sisi dapat dipilih: Buy / Sell /    |
//| Buy & Sell. Jumlah posisi dibatasi InpMaxGridPositions.           |
//+------------------------------------------------------------------+
bool GridSideBuyEnabled()  { return (InpGridSide == GRID_BUY_ONLY  || InpGridSide == GRID_BOTH || InpGridSide == GRID_AUTO); }
bool GridSideSellEnabled() { return (InpGridSide == GRID_SELL_ONLY || InpGridSide == GRID_BOTH || InpGridSide == GRID_AUTO); }

void EntryDbg(const string msg)
{
    if (!InpEntryDebug) return;
    static datetime last = 0;
    datetime now = TimeCurrent();
    if (last > 0 && (now - last) < 5) return;
    last = now;
    Print("ENTRY-DBG | ", msg);
}

double GridNormalizeLot(double lot)
{
    double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (vstep <= 0.0) vstep = 0.01;
    lot = MathRound(lot / vstep) * vstep;
    if (vmin > 0.0 && lot < vmin) lot = vmin;
    if (vmax > 0.0 && lot > vmax) lot = vmax;
    return NormalizeDouble(lot, 8);
}

// Harga entry posisi TERAKHIR pada arah dir (+1 BUY / -1 SELL). 0 = tidak ada.
double GridLastEntryPrice(const int dir)
{
    double last = 0.0;
    datetime tlast = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if (!posInfo.SelectByIndex(i)) continue;
        if (posInfo.Symbol() != _Symbol || !MagicMatches(posInfo.Magic())) continue;
        if (dir > 0 && posInfo.PositionType() != POSITION_TYPE_BUY)  continue;
        if (dir < 0 && posInfo.PositionType() != POSITION_TYPE_SELL) continue;
        datetime t = (datetime)posInfo.Time();
        if (t >= tlast) { tlast = t; last = posInfo.PriceOpen(); }
    }
    return last;
}

bool GridOpenPosition(const int dir, const double lot)
{
    double price  = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    price = NormalizeDouble(price, digits);

    trade.SetAsyncMode(false);   // hasil sinkron agar retcode pasti
    bool ok = (dir > 0) ? trade.Buy (lot, _Symbol, price, 0.0, 0.0, "GRID CLASSIC")
                        : trade.Sell(lot, _Symbol, price, 0.0, 0.0, "GRID CLASSIC");
    if (!ok)
        PrintFormat("GRID ENTRY FAIL | %s lot=%.2f | rc=%d | %s",
                    (dir > 0 ? "BUY" : "SELL"), lot, (int)trade.ResultRetcode(),
                    trade.ResultRetcodeDescription());
    else
        PrintFormat("GRID ENTRY %s | lot=%.2f | price=%.5f | ticket=%I64u",
                    (dir > 0 ? "BUY" : "SELL"), lot, trade.ResultPrice(),
                    (ulong)trade.ResultOrder());
    trade.SetAsyncMode(true);
    return ok;
}

void EntryEngine()
{
    if (IsEAExpired())            return;
    if (g_basket_exec_active)     return;
    if (g_maxfloat_fired)         return;   // latch SL basket aktif -> berhenti entry
    if (InpInitialLot <= 0.0)     return;
    if (InpGridDistancePoints <= 0) return;

    double tp_, bp_, sp_; int bc = 0, sc = 0;
    int open = CountOpenPositions(tp_, bc, sc, bp_, sp_);

    //--- Sisi efektif (AUTO -> keputusan dari kondisi market). Keputusan
    //    AUTO di-cache per bar HTF: deteksi (scan bar) hanya 1x per bar,
    //    bukan tiap tick — jauh lebih ringan & tetap reaktif.
    bool side_buy  = GridSideBuyEnabled();
    bool side_sell = GridSideSellEnabled();
    if (InpGridSide == GRID_AUTO)
    {
        datetime bar_now = iTime(_Symbol, AutoHTF(), 0);
        if (!g_auto_cache_valid || bar_now != g_auto_cache_bar)
        {
            int bias = 0;
            AutoSideDecision(g_auto_cache_buy, g_auto_cache_sell, g_auto_regime, bias);
            g_auto_bias        = bias;
            g_auto_cache_bar   = bar_now;
            g_auto_cache_valid = true;
        }
        side_buy  = g_auto_cache_buy;
        side_sell = g_auto_cache_sell;
    }

    if (InpMaxGridPositions > 0 && open >= InpMaxGridPositions)
    {
        EntryDbg(StringFormat("max grid tercapai (%d/%d) — tidak entry lagi", open, InpMaxGridPositions));
        return;
    }

    if (IsBasketPauseActive())          return;
    if (!IsAlgoTradingAllowedNow())     return;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (point <= 0.0) point = 1e-9;
    double dist = (double)InpGridDistancePoints * point;
    double lot  = GridNormalizeLot(InpInitialLot);
    if (lot <= 0.0) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if (InpGridSide == GRID_AUTO && !side_buy && !side_sell) return;

    //==================================================================
    // ENTRY PER SISI — MANDIRI (independen), BUKAN bergantian.
    // Setiap sisi punya siklus gridnya SENDIRI:
    //   - Bila sisi itu belum punya posisi -> buka posisi AWAL sisi itu
    //     (walau sisi lain sedang terbuka). Jadi sisi yang sudah selesai
    //     (mis. kena TP per-sisi) bisa memulai grid baru sendiri.
    //   - Bila sisi itu sudah punya posisi -> RE-ENTRY bila harga bergerak
    //     melawan posisi TERAKHIR sisi ITU sejauh jarak grid.
    // Tidak ada lagi ketergantungan pada jumlah posisi total (open==0).
    //==================================================================
    if (side_buy)
    {
        if (bc == 0)
            GridOpenPosition(+1, lot);                     // awal grid BUY (mandiri)
        else
        {
            double lastBuy = GridLastEntryPrice(+1);
            if (lastBuy > 0.0 && (lastBuy - ask) >= dist)
                GridOpenPosition(+1, lot);                 // re-entry BUY
        }
    }
    if (side_sell)
    {
        if (sc == 0)
            GridOpenPosition(-1, lot);                     // awal grid SELL (mandiri)
        else
        {
            double lastSell = GridLastEntryPrice(-1);
            if (lastSell > 0.0 && (bid - lastSell) >= dist)
                GridOpenPosition(-1, lot);                 // re-entry SELL
        }
    }
}

//+------------------------------------------------------------------+
//| MESIN EXIT — dipanggil dari OnTick                                |
//+------------------------------------------------------------------+
void ExitEngine()
{
    if (is_processing) return;

    if (g_basket_pause_until > 0 && TimeCurrent() >= g_basket_pause_until)
        g_basket_pause_until = 0;

    MaxFloatingRefresh();

    double total_profit = 0;
    double buy_profit = 0, sell_profit = 0;
    int buy_pos = 0, sell_pos = 0;
    int open_positions = CountOpenPositions(total_profit, buy_pos, sell_pos, buy_profit, sell_profit);

    // TP BASKET KHUSUS GRID — bila InpGridBasketTP > 0, tutup SEMUA saat
    // floating >= target tsb (dipakai alih-alih trailing-lock CARA EXIT).
    if (InpGridBasketTP > 0.0 && open_positions > 0 && !g_basket_exec_active && !is_processing)
    {
        if (total_profit >= InpGridBasketTP)
        {
            double rc_p = 0.0, rc_bp = 0.0, rc_sp = 0.0; int rc_b = 0, rc_s = 0;
            CountOpenPositions(rc_p, rc_b, rc_s, rc_bp, rc_sp);
            if (rc_p >= InpGridBasketTP)
            {
                PrintFormat("GRID TP BASKET hit: floating=%.2f >= %.2f. Closing all...", rc_p, InpGridBasketTP);
                g_tp_profit_pending = rc_p;
                g_tp_profit_pending_valid = true;
                if (!g_tp_balance_before_valid)
                {
                    g_tp_balance_before = AccountInfoDouble(ACCOUNT_BALANCE);
                    g_tp_balance_before_valid = true;
                }
                BasketExecStart("TP", rc_p);
                return;
            }
        }
    }

    // Rekam PEAK DRAWDOWN basket berjalan (basis TP Berjenjang)
    if (open_positions > 0 && total_profit < g_basket_worst)
        g_basket_worst = total_profit;
    // Jejak terburuk (snapshot saat TOTAL floating paling rendah): per sisi
    // disimpan P/L, jumlah posisi, dan total lot pada momen terburuk itu.
    if (open_positions > 0 && total_profit < g_worst_pl[2])
    {
        double wb_lot, ws_lot; GridSideLot(wb_lot, ws_lot);
        g_worst_pl[0]  = buy_profit;  g_worst_pl[1]  = sell_profit;  g_worst_pl[2]  = total_profit;
        g_worst_cnt[0] = buy_pos;     g_worst_cnt[1] = sell_pos;     g_worst_cnt[2] = open_positions;
        g_worst_lot[0] = wb_lot;      g_worst_lot[1] = ws_lot;       g_worst_lot[2] = wb_lot + ws_lot;
    }

    if (g_basket_exec_active)
        return;

    // SWEEP TP PARSIAL — Unified TP terisi sebagian: jumlah posisi BERKURANG
    // (bukan habis) dan penutupan terakhir beralasan TP broker. Sisa tiket
    // ditutup via jalur resmi (retry+verifikasi) agar siklus FLAT tuntas.
    // Close manual satu tiket TIDAK memicu sweep (reason bukan TP).
    if (open_positions > 0 && g_prev_open_positions > open_positions && g_had_positions)
    {
        int tp_side = 0;
        if (RecentBrokerTPClose(10, tp_side))
        {
            PrintFormat("TP-SWEEP: TP terisi sebagian (%d -> %d posisi, side=%s) — tutup sisa agar siklus/sisi tuntas",
                        g_prev_open_positions, open_positions,
                        (tp_side == 0 ? "ALL" : (tp_side > 0 ? "BUY" : "SELL")));
            g_prev_open_positions = open_positions;
            if (!g_tp_profit_pending_valid)
            {
                double swept_ = SumRecentBrokerTPProfit(10);
                g_tp_profit_pending       = swept_ + total_profit;
                g_tp_profit_pending_valid = true;
                if (!g_tp_balance_before_valid)
                {
                    g_tp_balance_before       = AccountInfoDouble(ACCOUNT_BALANCE) - swept_;
                    g_tp_balance_before_valid = true;
                }
            }
            BasketExecStart("TP_SWEEP", total_profit, tp_side);
            return;
        }
    }
    g_prev_open_positions = open_positions;

    // RESET GLOBAL — posisi habis lewat jalur APAPUN (close manual, TP/SL
    // sisi broker) = siklus selesai.
    if (open_positions == 0 && g_had_positions)
    {
        Print("RESET: semua posisi tertutup di luar BasketExec -> reset siklus exit");
        ResetAfterClearPositions();
    }

    if (open_positions > 0) g_had_positions = true;
    if (open_positions == 0)
    {
        g_unified_exit_active = false;
        g_unified_exit_dir = 0;
        g_unified_exit_bid = 0.0;
        g_unified_exit_ask = 0.0;
    }

    if (IsBasketPauseActive()) return;

    bool ea_active = IsAlgoTradingAllowedNow();
    bool tp_should_close = false;

    // ── TRAILING LOCK PROFIT (BE dinamis) ─────────────────────────────
    // InpTargetProfit berperan sbg FLOOR (lantai), bukan TP tetap.
    // Target TAK berplafon: titik kunci trailing naik adaptif mengikuti
    // puncak floating (gap proporsional 25% dari puncak), tak pernah turun
    // di bawah floor. Basket ditutup saat floating BERBALIK turun menembus
    // titik kunci. Server real-TP "diparkir" jauh (2x puncak) agar tak
    // menutup dini — penutup sesungguhnya = cek retrace di bawah.
    double floor_profit = (EffTargetProfit() > 0.0) ? EffTargetProfit() : 1.0;
    if (open_positions <= 0) g_basket_peak = 0.0;
    double lock = floor_profit;

    // Saat DUA sisi terbuka & TP per-sisi aktif, field TP tiket dimiliki
    // jalur PER-SISI; target net-basket tetap dipantau VIRTUAL.
    int    sm_buy = 0, sm_sell = 0; double sm_p = 0.0, sm_bp = 0.0, sm_sp = 0.0;
    CountOpenPositions(sm_p, sm_buy, sm_sell, sm_bp, sm_sp);
    bool side_mode = (InpGridBasketTP <= 0.0 && InpSideTargetProfit > 0.0 && sm_buy > 0 && sm_sell > 0);
    bool side_real = (side_mode && EffSideTPReal());

    if (ea_active && open_positions > 0 && InpGridBasketTP <= 0.0)
    {
        if (total_profit > g_basket_peak) g_basket_peak = total_profit;

        bool armed = (g_basket_peak >= floor_profit);
        lock = MathMax(floor_profit, g_basket_peak * 0.75);   // gap adaptif 25% dari puncak

        double parked_target = MathMax(floor_profit, g_basket_peak * 2.0);
        ApplyUnifiedExitForBasket(parked_target, total_profit, false);
        bool do_modify = false;
        if (EffBasketTPReal() && g_unified_exit_active && !side_real)
        {
            bool target_changed = false;
            if (!g_unified_last_target_profit_valid)
                target_changed = true;
            else if (MathAbs(parked_target - g_unified_last_target_profit) > 0.0001)
                target_changed = true;

            if (target_changed)
                do_modify = true;
            else if (g_unified_modify_passes_left > 0)
                do_modify = true;
            else
            {
                int sec_since = 999999;
                if (g_unified_last_modify_time > 0)
                    sec_since = (int)(TimeCurrent() - g_unified_last_modify_time);
                if (sec_since >= 2 && NeedsUnifiedExitModify(g_unified_exit_bid, g_unified_exit_ask, g_unified_exit_dir))
                    do_modify = true;
            }
        }
        if (do_modify)
        {
            ApplyUnifiedExitForBasket(parked_target, total_profit, true);
            if (g_unified_modify_passes_left > 0) g_unified_modify_passes_left--;
            g_unified_last_modify_time = TimeCurrent();
            g_unified_last_target_profit = parked_target;
            g_unified_last_target_profit_valid = true;
        }

        // PENUTUP SESUNGGUHNYA: floating berbalik turun menembus titik kunci.
        // Syarat peak > lock: tanpa ini, pada tick pertama profit menyentuh
        // floor berlaku profit=peak=lock -> basket langsung ditutup di floor
        // dan trailing 25% tidak pernah bekerja.
        if (armed && g_basket_peak > lock && total_profit <= lock)
            tp_should_close = true;
    }

    // ─────────────────────────────────────────────────────────────────
    // TP PER-SISI — mekanisme IDENTIK Basket TP (trailing lock:
    // floor=InpSideTargetProfit, peak per sisi, kunci 75% puncak, parked
    // real-TP 2x puncak, recheck, BasketExec retry+verify, history, pause)
    // tapi hanya untuk SATU SISI. Aktif hanya saat DUA sisi terbuka.
    // ─────────────────────────────────────────────────────────────────
    if (side_mode && ea_active && !is_processing && !g_basket_exec_active)
    {
        for (int sd = 0; sd < 2; sd++)
        {
            int    side_sign = (sd == 0) ? +1 : -1;
            double sp_profit = (sd == 0) ? sm_bp : sm_sp;

            if (sp_profit > g_side_peak[sd]) g_side_peak[sd] = sp_profit;

            double s_floor  = InpSideTargetProfit;
            bool   s_armed  = (g_side_peak[sd] >= s_floor);
            double s_lock   = MathMax(s_floor, g_side_peak[sd] * 0.75);
            double s_parked = MathMax(s_floor, g_side_peak[sd] * 2.0);

            if (EffSideTPReal())
            {
                bool s_do = false;
                if (MathAbs(s_parked - g_side_last_parked[sd]) > 0.0001) s_do = true;
                else if (g_side_last_modify[sd] == 0 || (TimeCurrent() - g_side_last_modify[sd]) >= 2) s_do = true;
                if (s_do)
                {
                    ApplyUnifiedExitForBasket(s_parked, sp_profit, true, side_sign);
                    g_side_last_modify[sd] = TimeCurrent();
                    g_side_last_parked[sd] = s_parked;
                }
            }

            if (s_armed && g_side_peak[sd] > s_lock && sp_profit <= s_lock)
            {
                double rc_p2 = 0.0, rc_bp2 = 0.0, rc_sp2 = 0.0; int rc_b2 = 0, rc_s2 = 0;
                CountOpenPositions(rc_p2, rc_b2, rc_s2, rc_bp2, rc_sp2);
                double rc_side = (sd == 0) ? rc_bp2 : rc_sp2;
                int    rc_cnt  = (sd == 0) ? rc_b2  : rc_s2;
                if (rc_cnt > 0 && rc_side < s_floor) continue;   // lantai keamanan

                PrintFormat("TP-SIDE hit (%s): profit=%.2f USD (puncak=%.2f, kunci=%.2f, recheck=%.2f). Closing side...",
                            (sd == 0 ? "BUY" : "SELL"), sp_profit, g_side_peak[sd], s_lock, rc_side);

                g_tp_profit_pending = rc_side;
                g_tp_profit_pending_valid = true;
                if (!g_tp_balance_before_valid)
                {
                    g_tp_balance_before = AccountInfoDouble(ACCOUNT_BALANCE);
                    g_tp_balance_before_valid = true;
                }
                BasketExecStart((sd == 0 ? "TP_SIDE_BUY" : "TP_SIDE_SELL"), rc_side, side_sign);
                return;
            }
        }
    }
    // Puncak sisi di-reset saat sisi tsb kosong (siklus sisi selesai).
    if (sm_buy  == 0) { g_side_peak[0] = 0.0; g_side_last_parked[0] = 0.0; g_side_last_modify[0] = 0; }
    if (sm_sell == 0) { g_side_peak[1] = 0.0; g_side_last_parked[1] = 0.0; g_side_last_modify[1] = 0; }

    if (tp_should_close && !is_processing)
    {
        // Re-check profit terkini sebelum trigger (harga bisa bergerak sejak cek pertama)
        double recheck_profit = 0.0;
        int rc_buy = 0, rc_sell = 0;
        double rc_bp = 0.0, rc_sp = 0.0;
        int recheck_pos = CountOpenPositions(recheck_profit, rc_buy, rc_sell, rc_bp, rc_sp);

        // Lantai keamanan: jangan menutup bila profit terjun di bawah floor.
        double safety_threshold = floor_profit;
        if (recheck_pos > 0 && recheck_profit < safety_threshold)
        {
            tp_should_close = false;
        }
        else
        {
            Print(StringFormat("Trailing lock hit: profit=%.2f USD (puncak=%.2f, kunci=%.2f, recheck=%.2f). Closing all...",
                               total_profit, g_basket_peak, lock, recheck_profit));

            g_tp_profit_pending = recheck_profit;
            g_tp_profit_pending_valid = true;
            if (!g_tp_balance_before_valid)
            {
                g_tp_balance_before = AccountInfoDouble(ACCOUNT_BALANCE);
                g_tp_balance_before_valid = true;
            }
            BasketExecStart("TP", recheck_profit);
            return;
        }
    }

    BasketTPSLVisSync();
}

//+------------------------------------------------------------------+
//| Resume state dari posisi floating yang sudah ada                  |
//+------------------------------------------------------------------+
void ResumeFromExistingState()
{
    double total_profit = 0.0, buy_profit = 0.0, sell_profit = 0.0;
    int    buy_pos = 0, sell_pos = 0;
    int    open_pos = CountOpenPositions(total_profit, buy_pos, sell_pos, buy_profit, sell_profit);

    if (open_pos <= 0)
    {
        Print("RESUME CHECK: Tidak ada posisi floating aktif — modul EXIT siaga.");
        return;
    }

    g_had_positions       = true;
    g_prev_open_positions = open_pos;
    g_basket_worst        = MathMin(0.0, total_profit);
    g_basket_peak         = MathMax(0.0, total_profit);

    PrintFormat("RESUME: %d posisi ditemukan (%d BUY / %d SELL) | Floating: %.2f USD | TP aktif: TP%d (%.2f)",
                open_pos, buy_pos, sell_pos, total_profit, BasketTPTier() + 1, EffTargetProfit());
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    if (IsEAExpired())
    {
        string exp_str = TimeToString(EA_EXPIRED_DATE, TIME_DATE|TIME_MINUTES);
        MessageBox("CARA EXIT sudah EXPIRED sejak " + exp_str + ".\n"
                   "Hubungi: https://wa.me/6285648181181",
                   "EA EXPIRED", MB_OK|MB_ICONERROR);
        PrintFormat("EA EXPIRED sejak %s — EA dihentikan total.", exp_str);
        return INIT_FAILED;
    }

    trade.SetExpertMagicNumber(InpMagic);
    trade.SetAsyncMode(true);
    g_ea_start_time = TimeCurrent();

    g_ui_scale = (double)InpUIScalePercent / 100.0;
    if (g_ui_scale <= 0.0) g_ui_scale = 1.0;
    g_ui_prefix = StringFormat("CEX_%I64u_", InpMagic);

    ResumeFromExistingState();

    if (InpMagic == 0)
        Print("CARA EXIT: Magic 0 — modul mengelola SEMUA posisi & pending order pada ", _Symbol,
              " apapun magic-nya (manual maupun EA lain).");

    PrintFormat("GRID CLASSIC ENTRY: side=%s | lot awal=%.2f | jarak grid=%d poin | max grid=%d | TP basket grid=%.2f",
                (InpGridSide == GRID_BUY_ONLY ? "BUY ONLY" : (InpGridSide == GRID_SELL_ONLY ? "SELL ONLY" :
                 (InpGridSide == GRID_AUTO ? "AUTO (deteksi market)" : "BUY & SELL"))),
                InpInitialLot, InpGridDistancePoints, InpMaxGridPositions, InpGridBasketTP);

    if (InpShowUI)
    {
        UIDeleteAll();
        g_ui_inited = true;
        PanelRender();
        TPHistoryRender();
    }
    BasketTPSLVisSync();
    EventSetMillisecondTimer(200);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    UIDeleteAll();
    g_ui_inited = false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    if (is_processing) return;
    if (IsEAExpired()) return;

    if (g_basket_exec_active)
    {
        BasketExecProcess();
        BasketTPSLVisSync();
        return;
    }

    EntryEngine();
    ExitEngine();
}

//+------------------------------------------------------------------+
//| Expert timer function                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (is_processing) return;
    if (IsEAExpired()) return;

    if (g_basket_exec_active)
    {
        BasketExecProcess();
        BasketTPSLVisSync();
        return;
    }

    EntryEngine();
    ExitEngine();
    if (InpShowUI) { PanelRender(); TPHistoryRender(); }
}

//+------------------------------------------------------------------+
//| Trade transaction — pemicu refresh unified TP                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    string sym = trans.symbol;
    if (sym == "") sym = _Symbol;
    if (sym != _Symbol) return;

    if (InpMagic != 0)
    {
        // Pada TRADE_TRANSACTION_DEAL_ADD struct 'request' umumnya KOSONG
        // (magic=0). Magic yang benar diambil dari DEAL-nya sendiri.
        long deal_magic = 0;
        if (trans.deal > 0 && HistoryDealSelect(trans.deal))
            deal_magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
        else
            deal_magic = (long)request.magic;
        if ((ulong)deal_magic != InpMagic) return;
    }

    if (!EffBasketTPReal()) return;
    g_unified_modify_passes_left = 1;
}

//+------------------------------------------------------------------+
//| Chart event — lipat panel GRID CLASSIC & panel TP/SL HISTORY      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    if (id != CHARTEVENT_OBJECT_CLICK) return;

    // Panel GRID CLASSIC: tombol lipat
    if (sparam == UIName("pnl_btn"))
    {
        g_pnl_collapsed = !g_pnl_collapsed;
        PanelRender();
        TPHistoryRender();   // lebar panel berubah -> geser TP/SL HISTORY
        return;
    }

    // Tombol CLOSE ALL: tutup semua posisi symbol ini via jalur resmi
    if (sparam == UIName("ca_btn") || sparam == UIName("ca_txt"))
    {
        if (g_basket_exec_active || is_processing) return;
        double tp_, bp_, sp_; int bc_ = 0, sc_ = 0;
        CountOpenPositions(tp_, bc_, sc_, bp_, sp_);
        if ((bc_ + sc_) <= 0) return;

        g_tp_profit_pending = 0.0;       g_tp_profit_pending_valid = false;
        g_tp_balance_before = 0.0;       g_tp_balance_before_valid = false;
        Print("PANEL: CLOSE ALL ditekan — menutup semua posisi symbol ini.");
        BasketExecStart("MANUAL_CLOSEALL", 0.0);
        return;
    }

    if (sparam == UIName("tph_btn"))
    {
        g_tph_collapsed = !g_tph_collapsed;
        TPHistoryRender();
        return;
    }
}

//+------------------------------------------------------------------+
// v1.00 CHANGELOG — RILIS AWAL "CARA EXIT" (modul EXIT mandiri):
//  - ASAL: seluruh konsep EXIT diekstrak dari PUREGRID_EA v28.04 tanpa
//    perubahan mekanika. EA ini TIDAK punya logika entry sama sekali;
//    posisi dibuka manual oleh trader atau oleh EA lain.
//  - MAGIC 0 (default): modul mengambil alih SEMUA posisi & pending order
//    pada symbol tempat ia di-attach, APAPUN magic-nya. Inilah yang
//    membuatnya bisa dipakai sebagai alat bantu exit untuk trading manual.
//    Isi magic != 0 bila hanya ingin mengelola posisi EA tertentu.
//  - KOMPONEN EXIT YANG DIBAWA (lengkap):
//      (1) TRAILING LOCK BASKET — InpTargetProfit sbg FLOOR, titik kunci
//          adaptif 75% dari puncak floating, real-TP diparkir 2x puncak,
//          penutup sesungguhnya = retrace menembus titik kunci.
//      (2) TP BERJENJANG — tingkat dari PEAK DRAWDOWN basket berjalan
//          (g_basket_worst), step InpAutoGridStepUSD, TP1..TP4 via
//          EffTargetProfit(). Reset saat basket tutup.
//      (3) TP PER-SISI — mekanika trailing IDENTIK Basket TP tapi hanya
//          menutup satu sisi. Aktif hanya saat DUA sisi terbuka.
//      (4) REAL vs VIRTUAL TP — InpTPFieldMode AUTO/MANUAL,
//          EffBasketTPReal() / EffSideTPReal() sbg pintu baca tunggal.
//      (5) PERHITUNGAN HARGA UNIFIED — ApplyUnifiedExitForBasket() +
//          NeedsUnifiedExitModify(), hormati stops level & spread.
//      (6) EKSEKUTOR BASKET — state machine INIT -> SEND -> VERIFY ->
//          FORCE -> DONE, retry, verifikasi akhir, abort recheck TP,
//          jeda pasca-TP InpBasketTPPauseSec.
//      (7) SWEEP TP PARSIAL — RecentBrokerTPClose() +
//          SumRecentBrokerTPProfit(): TP broker terisi sebagian -> sisa
//          ditutup agar siklus/sisi tuntas & history mencatat total penuh.
//      (8) SL BASKET (MAX FLOATING) — InpMaxFloatingLoss, latch anti-dobel,
//          TIDAK menghentikan EA.
//      (9) TP/SL HISTORY — 20 baris terakhir + REASON (TP BASKET / TP BUY /
//          TP SELL / SL FLOAT / MANUAL) + total akumulasi.
//     (10) GARIS VISUAL TP — garis Basket TP (mode virtual) & garis TP
//          per-sisi, dgn label level TP aktif.
//     (11) RESUME — saat attach di atas posisi yang sudah floating, state
//          exit dipulihkan (peak, peak drawdown, tingkat TP).
//  - YANG SENGAJA TIDAK DIBAWA (milik EA induk, bukan konsep exit):
//    seluruh mesin entry & Recovery Grid, Auto Grid (jarak layer), tangga
//    lot Upstair, Side-by-Bollinger, Entry Spam, Filter Margin, Filter
//    Spread, Filter HMR, Filter Drawdown, Daily Max Profit, gate pra-entry
//    v28.03, dan panel UI monitoring besar. Yang tersisa dari UI hanya
//    panel TP/SL HISTORY ringkas + garis TP di chart.
//  - CATATAN InpAutoGridStepUSD: di EA induk parameter ini dipakai ganda
//    (Auto Grid + TP Berjenjang). Di sini HANYA dipakai TP Berjenjang.
//  - CATATAN PENTING dgn Magic 0: modul akan menutup posisi apa pun pada
//    symbol ini saat target/SL basket tercapai, termasuk posisi yang
//    dibuka EA lain. Pastikan chart ini memang diperuntukkan demikian.
//+------------------------------------------------------------------+
// GRID CLASSIC v1.00 — TAMBAHAN MESIN ENTRY (di atas modul CARA EXIT):
//  - ENTRY GRID KLASIK: entry pertama sebesar lot awal, lalu RE-ENTRY
//    tiap harga bergerak melawan posisi terakhir >= InpGridDistancePoints
//    (default 1000 poin). Lot TETAP (tanpa martingale/upstair).
//  - SISI PILIHAN: InpGridSide = Buy Only / Sell Only / Buy & Sell.
//  - LOT AWAL: InpInitialLot (default 0.01), dipakai juga untuk re-entry.
//  - BATAS POSISI: InpMaxGridPositions (default 1000; 0 = tak terbatas).
//  - TP BASKET KHUSUS GRID: InpGridBasketTP (USD). Bila > 0, EA menutup
//    SEMUA saat floating >= nilai tsb (dipakai alih-alih trailing-lock
//    CARA EXIT). Bila 0, seluruh modul EXIT CARA EXIT tetap aktif penuh.
//  - Mesin entry menghormati gate: jeda pasca-TP, algo trading, latch SL
//    basket, dan status eksekusi basket — agar tidak entry saat close-all.
//  - Semua fungsi EXIT (CARA EXIT) dipertahankan UTUH tanpa perubahan
//    mekanika. Entry hanya menambah OnInit/OnTick/OnTimer.
//+------------------------------------------------------------------+
// GRID CLASSIC v1.01 — PANEL UI (ditiru dari panel HEDGING, disesuaikan):
//  - PANEL "GRID CLASSIC" di KIRI chart, gaya HEDGING (header bar, zebra,
//    warna CYAN utk SECTION, tombol lipat [-]/[+], Copyright Bang iNo).
//  - SECTION STATUS : status + identitas (symbol & magic) + CLOSE ALL.
//  - SECTION GRID   : Side, Lot awal, Jarak grid, Max grid (dipakai/batas),
//                     Next BUY & Next SELL (harga re-entry berikutnya).
//  - SECTION POSISI : tabel BUY / SELL / TOTAL — Posisi, Lot, P/L,
//                     Avg entry (harga rata-rata per sisi).
//  - SECTION EXIT   : TP Basket (grid TP atau modul EXIT), Puncak Basket,
//                     Worst Basket (peak drawdown + tingkat TP berjenjang),
//                     plus bar progres puncak vs target.
//  - SECTION AKUN   : Balance, Equity (+DD%).
//  - SECTION WAKTU  : tanggal & jam WIB, Run time.
//  - Panel MURNI TAMPILAN (read-only) kecuali CLOSE ALL (jalur resmi
//    BasketExec). Lebar panel menggeser panel TP/SL HISTORY ke kanan.
//+------------------------------------------------------------------+
// GRID CLASSIC v1.02 — InpGridSide mode "AUTO" (sisi mengikuti market):
//  - AUTO memilih sisi entry dari KONDISI MARKET (read-only), dgn 3 metode:
//      (1) SIDEWAY          -> SUPPORT & RESISTANCE. Buy bila harga di
//          zona support, Sell bila di zona resistance, tengah range = dua
//          arah (cocok utk grid). Range diukur dari swing high/low HTF.
//      (2) STRONG TREND     -> SUPPLY & DEMAND. N candle kuat beruntun
//          (body >= InpAutoStrongBodyRatio) menentukan bull/bear; sisi
//          searah tren, entry dipicu dari zona demand/supply.
//      (3) BREAKOUT MOMENTUM-> breakout pada M15/H1/H4/D1 (dicek mulai TF
//          terdekat InpAutoBreakTF), hanya sisi arah breakout (buffer ATR).
//  - Prioritas deteksi regime: BREAKOUT -> STRONG TREND -> SIDEWAY.
//  - Input baru grup "AUTO SIDE": TF struktur, TF breakout, D1 on/off,
//    lookback swing, kekuatan swing, ambang range (xATR), rasio body,
//    jumlah candle kuat, buffer breakout, periode ATR, bar bias, lebar
//    zona (xATR), dan InpAutoRespectBias (jangan entry melawan bias).
//  - PANEL: baris "Regime" muncul di section GRID saat mode AUTO,
//    menampilkan metode aktif (SIDEWAY S&R / BULL S&D / BEAR S&D /
//    BREAKOUT MOM) dgn warna sesuai regime.
//  - Mode manual (Buy Only / Sell Only / Buy & Sell) TIDAK berubah.
//+------------------------------------------------------------------+
// GRID CLASSIC v1.04 — JEJAK (WORST) JADI TABEL 3 KOLOM:
//  - Section baru "JEJAK (WORST)" meniru section POSISI pada HEDGING:
//    kolom BUY / SELL / TOTAL, dengan baris Posisi, Lot, dan P/L.
//  - Nilainya = SNAPSHOT saat floating TOTAL paling rendah pada siklus
//    berjalan (bukan nilai terburuk per sisi masing-masing), jadi konsisten
//    seperti WORST di HEDGING. Di-reset tiap siklus selesai.
//  - Baris "Worst P/L" & "Worst Posisi" yang DUPLIKAT (nilainya sama dgn
//    Worst Basket) DIHAPUS. Section EXIT kini hanya: TP, Puncak Basket,
//    progress bar, dan Worst Basket (peak drawdown + tingkat TP).
//+------------------------------------------------------------------+
// GRID CLASSIC v1.05 — JEJAK PERSISTEN + SELISIH HARIAN:
//  - JEJAK (WORST) TIDAK LAGI di-reset saat siklus selesai. Nilainya
//    diakumulasi sejak EA di-start dan hanya hilang bila EA di-ATTACH
//    ULANG (atau terminal restart). Jadi rekor terburuk sepanjang sesi
//    tetap terlihat meski basket sudah beberapa kali TP.
//  - Baris baru "Daily" pada section GRID: selisih harga harian
//    (harga sekarang vs open D1) ditampilkan MENTAH + PERSEN, mis.
//    "-6789 | -3.48%" (MERAH saat minus) atau "6785 | +1.05%"
//    (BIRU saat plus). MURNI KOSMETIK — tidak dipakai logika entry/exit.
//+------------------------------------------------------------------+
// GRID CLASSIC v1.06 — ENTRY PER SISI MANDIRI (Buy & Sell):
//  - Mode Buy & Sell kini menjalankan DUA siklus grid yang INDEPENDEN,
//    bukan bergantian. Tiap sisi dicek sendiri:
//      * sisi belum punya posisi -> buka posisi AWAL sisi itu (walau sisi
//        lain masih terbuka). Sisi yang sudah selesai (kena TP per-sisi)
//        otomatis memulai grid baru sendiri tanpa menunggu sisi lain.
//      * sisi sudah punya posisi -> re-entry bila harga bergerak melawan
//        posisi TERAKHIR sisi itu sejauh jarak grid.
//  - Gerbang lama "entry hanya bila total posisi = 0" DIHAPUS karena itu
//    yang membuat kedua sisi saling mengunci / tampak bergantian.
//  - Berlaku juga untuk mode AUTO (sisi yang dipilih AUTO pun mandiri).
//+------------------------------------------------------------------+
