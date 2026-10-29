//+------------------------------------------------------------------+
//| EA_Breakout_BasketTP_v4.10.mq5                                   |
//| Entry 1 : INIT = market order tiap 0 posisi (komentar #1); arah  |
//|           dari DAILY CHANGE % (D1), segar tiap init              |
//| Layer   : #2 dst = MARKET instan 1 posisi, SEARAH init. Trigger  |
//|           RECOVERY: floating layer terakhir RUGI <= -N x lot/InpLot|
//| Lot     : Fix atau TANGGA (UPSTAIR) naik tiap N layer            |
//| Exit    : Basket TP — Unified Real TP di broker + eksekutor      |
//|           async (snapshot -> SEND -> VERIFY -> FORCE -> DONE)    |
//| Guard   : Max Posisi + TP, Hedge CL, Daily Max Profit            |
//| UI      : Panel BREAKOUT + TP/SL HISTORY + garis TP di chart     |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "4.10"
#property strict

#define EA_VERSION "4.10"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;
COrderInfo    orderInfo;

//--- Input Parameters
input group "=== SETTINGS ==="
input long   InpMagic           = 990011;  // Magic Number
input bool   InpShowLog         = false;   // Show Log Expert

input group "=== ENTRY ==="
input double InpLot             = 0.01;    // Lot dasar (layer #1)
input bool   InpLotUpstairOn    = false;   // AKTIFKAN TANGGA LOT (UPSTAIR). false = lot fix semua layer
input double InpLotUpstairStep  = 0.01;    // Tangga lot antar kelompok pasangan ( UPSTAIR). Contoh 0.01 -> 0.01 > 0.02 > 0.03
input int    InpLotStepLayer    = 3;       // Lot naik setiap N pasangan
input int    InpMaxSpreadPoints = 100;     // Max Spread (Points)

input group "=== LAYER (RE-ENTRY / RECOVERY) ==="
input double InpLayerTriggerUSD = 1.0;     // Pemicu RECOVERY layer baru (USD, tanda +/- diabaikan). Nilai = ambang pada lot awal (InpLot). Yang diukur = floating layer TERAKHIR (tertinggi) saja. Layer baru ditambah HANYA saat RUGI <= -(nilai x lot layer terakhir / InpLot) [jarak harga antar layer tetap walau lot naik]. Lot layer baru = lot upstair. Arah layer baru = arah INIT siklus berjalan. 0 = recovery nonaktif

input group "=== EXIT ==="
input double InpTPBasketUSD     = 5.0;     // Target Profit Basket (USD)
input bool   InpUseRealTP       = true;    // Pasang Unified Real TP di broker (exit serentak & instan)
input int    InpExitRetries     = 10;      // Maks siklus retry eksekutor exit
input int    InpPauseAfterTPSec = 3;       // Jeda (detik) setelah basket tuntas sebelum siklus baru
input bool   InpEnableHedgeCL   = true;    // Aktifkan Cut Loss saat Hedging (total lot Buy = total lot Sell)
input int    InpHedgeCLMinutes  = 1;      // Durasi hedging seimbang sebelum CL (menit)

input group "=== INIT (DAILY CHANGE %) ==="
input double InpInitDailyPct       = 2.0;      // Ambang daily change (%) untuk arah INIT. KETAT: harus LEBIH dari nilai ini. Daily change > +nilai -> BUY (biru/plus); < -nilai -> SELL (merah/minus); di antaranya -> TIDAK ada init (EA menunggu). Sumber: (harga sekarang - close D1 kemarin) / close kemarin x 100, dihitung dari candle D1

input group "=== LIMIT POSISI ==="
input int    InpMaxPositions    = 150;     // Batas jumlah posisi terbuka (satu basket). Tercapai -> re-entry layer baru DITAHAN. 0 = tanpa batas
input bool   InpMaxPosTP        = true;    // Saat batas posisi tercapai: tutup SELURUH basket begitu total floating > 0 (TP basket lebih awal, tanpa menunggu InpTPBasketUSD). false = hanya menahan re-entry

input group "=== DAILY LIMIT ==="
input bool   InpDailyEnable     = false;   // AKTIFKAN DAILY MAX PROFIT. false = fitur nonaktif (saklar panel tetap bisa dinyalakan manual)
input double InpDailyMaxProfit  = 1000.0;  // MAX PROFIT HARIAN (mata uang akun). Net = realized hari ini + floating. Tercapai -> tutup semua posisi & entry dikunci sampai ganti hari server. Nilai <= 0 dianggap 1000

input group "=== UI (TP/SL HISTORY + GARIS TP) ==="
input bool     InpShowUI          = true;  // Tampilkan panel BREAKOUT + TP/SL HISTORY & garis TP di chart
const int      InpUIScalePercent  = 70;    // Skala UI (%)
const int      InpMaxRetries      = 10;    // Maksimum percobaan ulang saat close/delete order
const int      InpRetrySleepMs    = 300;   // Jeda antar percobaan ulang (ms)

//--- State umum
double g_lastLoggedProfit    = 0.0;
int    g_lastLoggedPositions = -1;
int    g_prevOpenPositions   = 0;
bool   g_hadPositions        = false;
datetime g_pauseUntil        = 0;
int    g_initSide            = 0;   // arah INIT siklus berjalan: +1 BUY / -1 SELL (0 = belum ada); direset tiap siklus baru
int    g_lastInitSide        = 0;   // arah init terakhir; TIDAK direset
int    g_marketLayerNo       = 0;   // layer# market order re-entry yang baru dikirim, menunggu terbaca sbg posisi (0 = tidak ada)
datetime g_marketLayerTime   = 0;   // waktu pengiriman market order re-entry tsb (batas tunggu 5 detik)

datetime g_hedgeSince        = 0;   // waktu mulai terdeteksi Buy=Sell seimbang (0 = tidak sedang hedging)
datetime g_cycleStart        = 0;   // waktu siklus basket berjalan dimulai (untuk realized TP/SL history)
datetime g_eaStartTime       = 0;   // waktu EA di-attach (runtime panel)

//--- WORST TRACKER: jejak terburuk sejak EA di-attach. TIDAK PERNAH
//    direset oleh TP, CL, Daily Limit, maupun basket clear manapun.
//    Hanya nol saat EA dilepas & dipasang ulang ke chart (variabel
//    global MQL5 mempertahankan nilai selama EA masih terpasang,
//    termasuk saat input diubah / expert di-compile ulang).
//    MURNI PENCATATAN — tidak dibaca oleh logika entry/exit mana pun.
int    g_worstPos[3] = {0, 0, 0};        // [0]=BUY [1]=SELL [2]=TOTAL
double g_worstLot[3] = {0.0, 0.0, 0.0};
double g_worstPl[3]  = {0.0, 0.0, 0.0};  // floating paling minus [0]=BUY [1]=SELL [2]=TOTAL

//--- Saklar RUNTIME (panel). Nilai awal mengikuti input.
bool   g_spreadOn            = true;
bool   g_hedgeOn             = true;

//--- DAILY MAX PROFIT
bool   g_dailyOn             = false;
bool   g_dailyLocked         = false;
bool   g_dailyVerify         = false;
datetime g_dailyDay          = 0;
double g_dailyNetCache       = 0.0;

//--- State unified real TP
bool   g_unifiedActive   = false;
double g_unifiedBid      = 0.0;
double g_unifiedAsk      = 0.0;
int    g_unifiedDir      = 0;
datetime g_unifiedLastMod = 0;

//--- State eksekutor exit
enum ENUM_EXEC_STATE { EXEC_IDLE=0, EXEC_INIT=1, EXEC_SEND=2, EXEC_VERIFY=3, EXEC_FORCE=4, EXEC_DONE=5 };
bool     g_execActive = false;
int      g_execState  = EXEC_IDLE;
string   g_execReason = "";
datetime g_execNext   = 0;
int      g_execCycles = 0;
int      g_execForce  = 0;
ulong    g_execPos[];
ulong    g_execOrd[];

//======================================================================
// UI — STATE & PALET
//======================================================================
#define CLR_BG      C'11,18,32'
#define CLR_BG2     C'17,26,43'
#define CLR_BORDER  C'30,58,95'
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
#define CLR_W_POS   C'225,90,215'     // magenta   — Posisi WORST
#define CLR_W_LOT   C'255,125,190'    // pink      — Lot WORST
#define CLR_W_PLP   C'150,205,255'    // biru muda — P/L WORST bernilai +
#define CLR_W_PLN   C'255,150,60'     // oranye    — P/L WORST bernilai -

string   g_uiPrefix     = "";
double   g_uiScale      = 1.0;
int      g_pnlPanelW    = 0;
bool     g_pnlCollapsed = false;

//--- TP/SL HISTORY
#define TPH_MAX 20
double   g_tphVal[TPH_MAX];
datetime g_tphTime[TPH_MAX];
string   g_tphReason[TPH_MAX];
int      g_tphCount     = 0;
bool     g_tphCollapsed = false;
int      g_tphPanelW    = 0;
int      g_tpHitCount   = 0;

//+------------------------------------------------------------------+
void Log(string msg) { if(InpShowLog) Print(msg); }

bool IsMinePos() { return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
                           PositionGetInteger(POSITION_MAGIC) == InpMagic); }

//+------------------------------------------------------------------+
//| Parse nomor layer dari komentar "#N"                              |
//+------------------------------------------------------------------+
int ParseLayer(string comment)
{
   int pos = StringFind(comment, "#");
   if(pos < 0) return 0;
   int val = (int)StringToInteger(StringSubstr(comment, pos + 1));
   return (val > 0 ? val : 0);
}

//+------------------------------------------------------------------+
//| Hitung posisi + floating                                          |
//+------------------------------------------------------------------+
int CountOpenPositions(double &total_profit)
{
   int count = 0; total_profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
      count++;
      total_profit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   }
   return count;
}
int CountOpenPositions() { double d; return CountOpenPositions(d); }

int CountPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != (long)InpMagic) continue;
      count++;
   }
   return count;
}

int GetHighestLayer()
{
   int maxLayer = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      int lay = ParseLayer(PositionGetString(POSITION_COMMENT));
      if(lay > maxLayer) maxLayer = lay;
   }
   return maxLayer;
}

//+------------------------------------------------------------------+
//| Nomor layer tertinggi dari POSISI AKTIF + PENDING ORDER.          |
//| Dipakai saat menentukan nomor layer BARU agar tidak pernah        |
//| bentrok dengan pending pair yang sudah menggantung di broker      |
//| (mis. setelah EA restart/reattach, latch pending sempat ke-reset  |
//| padahal pending lama masih ada) -> anti komentar layer ganda.     |
//+------------------------------------------------------------------+
int GetHighestLayerAny()
{
   int maxLayer = GetHighestLayer();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != (long)InpMagic) continue;
      int lay = ParseLayer(orderInfo.Comment());
      if(lay > maxLayer) maxLayer = lay;
   }
   return maxLayer;
}

//+------------------------------------------------------------------+
//| Hitung posisi aktif pada satu nomor layer (0 = layer belum aktif). |
//| >= 2 berarti KEDUA leg pending pair layer itu ikut tereksekusi     |
//| (double-fill) — kondisi yang secara konsep tidak boleh terjadi.    |
//+------------------------------------------------------------------+
int CountPositionsByLayer(const int lay)
{
   if(lay <= 0) return 0;
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      if(ParseLayer(PositionGetString(POSITION_COMMENT)) == lay) n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| TANGGA LOT (UPSTAIR)                                              |
//|   UPSTAIR OFF : lot = InpLot untuk SEMUA layer (perilaku lama)    |
//|   UPSTAIR ON  : lot = InpLot + InpLotUpstairStep * floor((N-1)/L) |
//|                 N = nomor layer, L = InpLotStepLayer              |
//|   Contoh L=3, step 0.01 : #1..#3 = 0.01 | #4..#6 = 0.02 | dst     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) vstep = 0.01;
   lot = MathRound(lot / vstep) * vstep;
   if(vmin > 0.0 && lot < vmin) lot = vmin;
   if(vmax > 0.0 && lot > vmax) lot = vmax;
   int vdig = 2;
   if(vstep >= 1.0)       vdig = 0;
   else if(vstep >= 0.1)  vdig = 1;
   else if(vstep >= 0.01) vdig = 2;
   else                   vdig = 3;
   return NormalizeDouble(lot, vdig);
}

//+------------------------------------------------------------------+
//| LOT PER LAYER                                                    |
//|   UPSTAIR OFF : lot = InpLot untuk semua layer.                  |
//|   UPSTAIR ON  : InpLot + InpLotUpstairStep x floor((N-1)/L).     |
//|   baseOnly = true : paksa lot dasar (InpLot) tanpa tangga.       |
//|   Parameter dipertahankan untuk kompatibilitas; re-entry kini    |
//|   selalu mode upstair (recovery saja).                           |
//+------------------------------------------------------------------+
double LotForLayer(const int layerNo, const bool baseOnly = false)
{
   double up  = (InpLotUpstairStep < 0.0) ? 0.0 : InpLotUpstairStep;
   double lot = InpLot;
   if(InpLotUpstairOn && !baseOnly)
   {
      int n    = (layerNo < 1) ? 1 : layerNo;
      int step = (InpLotStepLayer < 1) ? 1 : InpLotStepLayer;
      int rung = (int)MathFloor((double)(n - 1) / (double)step);
      lot += up * (double)rung;
   }
   return NormalizeLot(lot);
}

//--- Nomor layer yang akan dipakai entry berikutnya (untuk panel "Lot next")
int NextLayerNo()
{
   int top = GetHighestLayerAny();
   return (top <= 0) ? 1 : top + 1;
}

//+------------------------------------------------------------------+
//| Statistik per sisi (panel)                                        |
//+------------------------------------------------------------------+
void SideStats(int &bc, int &sc, double &blot, double &slot, double &bpl, double &spl)
{
   bc = 0; sc = 0; blot = 0.0; slot = 0.0; bpl = 0.0; spl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
      double pl = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      if(posInfo.PositionType() == POSITION_TYPE_BUY) { bc++; blot += posInfo.Volume(); bpl += pl; }
      else                                            { sc++; slot += posInfo.Volume(); spl += pl; }
   }
}

//+------------------------------------------------------------------+
//| Realized profit (deal OUT symbol+magic ini) sejak waktu tertentu  |
//+------------------------------------------------------------------+
double RealizedSince(const datetime from)
{
   if(from <= 0) return 0.0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0.0;
   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)InpMagic) continue;
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
      sum += HistoryDealGetDouble(tk, DEAL_PROFIT)
           + HistoryDealGetDouble(tk, DEAL_SWAP)
           + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
   return sum;
}

//+------------------------------------------------------------------+
//| WORST TRACKER — jejak terburuk sejak EA di-attach (lihat deklarasi|
//| global). Dipanggil tiap EngineStep, PALING AWAL, tanpa syarat.    |
//+------------------------------------------------------------------+
void WorstTrack()
{
   int bc = 0, sc = 0; double blot = 0.0, slot = 0.0, bpl = 0.0, spl = 0.0;
   SideStats(bc, sc, blot, slot, bpl, spl);

   if(bc      > g_worstPos[0]) g_worstPos[0] = bc;
   if(sc      > g_worstPos[1]) g_worstPos[1] = sc;
   if(bc + sc > g_worstPos[2]) g_worstPos[2] = bc + sc;

   if(blot        > g_worstLot[0]) g_worstLot[0] = blot;
   if(slot        > g_worstLot[1]) g_worstLot[1] = slot;
   if(blot + slot > g_worstLot[2]) g_worstLot[2] = blot + slot;

   if(bc + sc > 0)
   {
      double tpl = bpl + spl;
      if(bpl < g_worstPl[0]) g_worstPl[0] = bpl;   // tiap sisi dicatat
      if(spl < g_worstPl[1]) g_worstPl[1] = spl;   // INDEPENDEN
      if(tpl < g_worstPl[2]) g_worstPl[2] = tpl;
   }
}

double GetTickValueProfit()
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
   if(tv > 0.0) return tv;
   return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
}

bool IsPauseActive() { return (g_pauseUntil > 0 && TimeCurrent() < g_pauseUntil); }

//+------------------------------------------------------------------+
//| Bulatkan harga ke kelipatan SYMBOL_TRADE_TICK_SIZE (bukan cuma    |
//| digits) — wajib untuk symbol synthetic/index yang tick_size-nya   |
//| tidak sama dengan point (sumber error "invalid price").           |
//+------------------------------------------------------------------+
double NormalizePriceToTick(const double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick_size <= 0.0) return NormalizeDouble(price, digits);
   double rounded = MathRound(price / tick_size) * tick_size;
   return NormalizeDouble(rounded, digits);
}

//+------------------------------------------------------------------+
//| Hitung harga exit basket (NET volume) TANPA mengubah tiket.       |
//| Dipakai oleh garis TP visual di chart. Rumusnya sama persis       |
//| dengan yang dipakai ApplyUnifiedTP — hanya tidak menulis apa pun. |
//+------------------------------------------------------------------+
bool ComputeBasketTPPrice(const double target_profit, const double current_profit,
                          double &out_bid, double &out_ask, int &out_dir)
{
   out_bid = 0.0; out_ask = 0.0; out_dir = 0;
   if(target_profit <= 0.0) return false;

   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = GetTickValueProfit();
   if(tick_size <= 0.0 || tick_value <= 0.0) return false;

   double buy_vol = 0.0, sell_vol = 0.0;
   int    total   = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
      double v = posInfo.Volume();
      if(v <= 0.0) continue;
      total++;
      if(posInfo.PositionType() == POSITION_TYPE_BUY) buy_vol += v; else sell_vol += v;
   }
   if(total <= 0) return false;

   double net_vol  = buy_vol - sell_vol;
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double net_eps  = (vol_step > 0.0 ? vol_step * 0.5 : 1e-9);
   if(MathAbs(net_vol) <= net_eps) return false;   // hedge sempurna: harga tak terdefinisi

   double need = target_profit - current_profit;
   if(need <= 0.0) return false;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    stopspt = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread  = ask - bid;
   double min_dist= (stopspt + 1) * point;

   double delta     = need * tick_size / (tick_value * net_vol);
   double close_bid = bid + delta;
   if(delta > 0.0 && close_bid < ask + min_dist)          close_bid = ask + min_dist;
   if(delta < 0.0 && close_bid > bid - min_dist - spread) close_bid = bid - min_dist - spread;

   close_bid = NormalizeDouble(close_bid, digits);
   double close_ask = NormalizeDouble(close_bid + spread, digits);
   if(close_bid <= 0.0 || close_ask <= 0.0) return false;

   out_bid = close_bid;
   out_ask = close_ask;
   out_dir = (net_vol > 0.0 ? 1 : -1);
   return true;
}

//+------------------------------------------------------------------+
//| UNIFIED REAL TP                                                   |
//| Hitung satu harga exit untuk seluruh basket (berdasar NET volume),|
//| lalu pasang TP/SL di setiap tiket sehingga broker menutup semua   |
//| serentak begitu harga tersentuh — tanpa menunggu tick EA.         |
//+------------------------------------------------------------------+
bool ApplyUnifiedTP(const double target_profit, const double current_profit, const bool do_modify)
{
   if(!InpUseRealTP) return false;
   if(target_profit <= 0.0) return false;

   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = GetTickValueProfit();
   if(tick_size <= 0.0 || tick_value <= 0.0) return false;

   double buy_vol = 0.0, sell_vol = 0.0;
   int    total   = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
      double v = posInfo.Volume();
      if(v <= 0.0) continue;
      total++;
      if(posInfo.PositionType() == POSITION_TYPE_BUY) buy_vol += v; else sell_vol += v;
   }
   if(total <= 0) return false;

   double net_vol  = buy_vol - sell_vol;
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double net_eps  = (vol_step > 0.0 ? vol_step * 0.5 : 1e-9);

   //--- Basket hedge sempurna (net 0): harga tidak bisa dihitung, bersihkan TP
   if(MathAbs(net_vol) <= net_eps)
   {
      g_unifiedActive = false; g_unifiedDir = 0;
      if(!do_modify) return false;
      bool sent = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
         if(posInfo.StopLoss() <= 0.0 && posInfo.TakeProfit() <= 0.0) continue;
         sent = trade.PositionModify(posInfo.Ticket(), 0.0, 0.0) || sent;
      }
      return sent;
   }

   double need = target_profit - current_profit;
   if(need <= 0.0) return false;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    stopspt = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread  = ask - bid;
   double min_dist= (stopspt + 1) * point;

   double delta     = need * tick_size / (tick_value * net_vol);
   double close_bid = bid + delta;
   if(delta > 0.0 && close_bid < ask + min_dist)             close_bid = ask + min_dist;
   if(delta < 0.0 && close_bid > bid - min_dist - spread)    close_bid = bid - min_dist - spread;

   close_bid = NormalizeDouble(close_bid, digits);
   double close_ask = NormalizeDouble(close_bid + spread, digits);
   if(close_bid <= 0.0 || close_ask <= 0.0) return false;

   g_unifiedActive = true;
   g_unifiedDir    = (net_vol > 0.0 ? 1 : -1);
   g_unifiedBid    = close_bid;
   g_unifiedAsk    = close_ask;

   if(!do_modify) return false;

   bool sent_any = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;

      double d_sl = 0.0, d_tp = 0.0;
      if(net_vol > 0.0)
      {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) d_tp = close_bid;
         else                                            d_sl = close_ask;
      }
      else
      {
         if(posInfo.PositionType() == POSITION_TYPE_SELL) d_tp = close_ask;
         else                                             d_sl = close_bid;
      }

      double cur_sl = posInfo.StopLoss();
      double cur_tp = posInfo.TakeProfit();
      bool need_change = false;
      if(d_sl <= 0.0) { if(cur_sl > 0.0) need_change = true; }
      else            { if(MathAbs(cur_sl - d_sl) > point) need_change = true; }
      if(d_tp <= 0.0) { if(cur_tp > 0.0) need_change = true; }
      else            { if(MathAbs(cur_tp - d_tp) > point) need_change = true; }
      if(!need_change) continue;

      sent_any = trade.PositionModify(posInfo.Ticket(), d_sl, d_tp) || sent_any;
   }
   return sent_any;
}

//======================================================================
// DAILY MAX PROFIT
//   Batas hari : 00:00 WAKTU SERVER
//   Cakupan    : symbol ini + magic EA
//   Net        : realized hari ini + floating berjalan
//   Trigger    : net >= batas -> kunci entry + tutup SEMUA posisi
//   Kunci lepas: ganti hari server, atau saklar panel dimatikan
//======================================================================
double DailyLimitValue()
{
   return (InpDailyMaxProfit > 0.0) ? InpDailyMaxProfit : 1000.0;
}

datetime DailyServerDayStart()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

double DailyRealizedProfit() { return RealizedSince(DailyServerDayStart()); }

double DailyNetProfit()
{
   double fl = 0.0;
   CountOpenPositions(fl);
   return DailyRealizedProfit() + fl;
}

bool DailyLockActive() { return (g_dailyOn && g_dailyLocked); }

//--- dipanggil tiap EngineStep SEBELUM mesin entry/exit
void DailyLimitCheck()
{
   //--- ganti hari server -> kunci dilepas, hitungan mulai dari nol
   datetime today = DailyServerDayStart();
   if(g_dailyDay != today)
   {
      g_dailyDay = today;
      if(g_dailyLocked)
      {
         g_dailyLocked = false;
         g_dailyVerify = false;
         Log("[DAILY] Hari server berganti -> kunci entry DILEPAS");
      }
   }

   if(!g_dailyOn) { g_dailyNetCache = 0.0; return; }

   //--- Perhitungan net menyapu history hari berjalan; dibatasi 1x/detik
   //    supaya tidak membebani timer 200 ms. Cukup responsif untuk trigger.
   static uint last_calc = 0;
   uint nowms = GetTickCount();
   if(last_calc != 0 && (nowms - last_calc) < 1000 && !g_dailyVerify) return;
   last_calc = nowms;

   g_dailyNetCache = DailyNetProfit();

   //--- VERIFIKASI ULANG PASCA PENUTUPAN: dijalankan hanya setelah posisi
   //    benar-benar nol & eksekutor selesai, supaya net yang dibaca murni
   //    realized tanpa floating.
   if(g_dailyLocked && g_dailyVerify)
   {
      if(CountOpenPositions() == 0 && !g_execActive)
      {
         g_dailyVerify = false;
         if(g_dailyNetCache < DailyLimitValue())
         {
            g_dailyLocked = false;
            Log(StringFormat("[DAILY] Hasil akhir %.2f < batas %.2f -> kunci DILEPAS, entry dilanjutkan",
                             g_dailyNetCache, DailyLimitValue()));
         }
         else
            Log(StringFormat("[DAILY] Hasil akhir %.2f >= batas %.2f -> kunci DIPERTAHANKAN",
                             g_dailyNetCache, DailyLimitValue()));
      }
   }

   if(g_dailyLocked) return;
   if(g_dailyNetCache < DailyLimitValue()) return;

   //--- trigger tercapai: kunci dulu, lalu tutup seluruh posisi
   g_dailyLocked = true;
   g_dailyVerify = true;
   Log(StringFormat("[DAILY-LIMIT] TERCAPAI | net=%.2f >= batas=%.2f | entry DIKUNCI + tutup semua posisi",
                    g_dailyNetCache, DailyLimitValue()));

   if((CountOpenPositions() + CountPendingOrders()) > 0 && !g_execActive)
   {
      double fl = 0.0; CountOpenPositions(fl);
      ExecStart("DAILY_MAXPROFIT", fl);
      ExecProcess();
   }
}

//======================================================================
// UI — HELPER DASAR
//======================================================================
int UIS(const int v) { return (int)MathRound((double)v * g_uiScale); }
int UIFont(const int v)
{
   int r = (int)MathRound((double)v * g_uiScale);
   return (r < 1 ? 1 : r);
}
string UIName(const string suffix) { return g_uiPrefix + suffix; }

bool UIEnsureRect(const string suffix, const int x, const int y, const int w, const int h,
                  const color bg, const color border, const int z)
{
   string name = UIName(suffix);
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0)) return false;
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

bool UIEnsureLabel(const string suffix, const int x, const int y, const string text,
                   const int font_size, const color clr, const string font,
                   const ENUM_ANCHOR_POINT anchor, const int z)
{
   string name = UIName(suffix);
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0)) return false;
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
   if(StringLen(g_uiPrefix) == 0) return;
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string n = ObjectName(0, i, -1, -1);
      if(StringFind(n, g_uiPrefix) == 0) ObjectDelete(0, n);
   }
}

int UITextW(const string txt, const int fontsize, const string font = "Consolas")
{
   TextSetFont(font, -fontsize * 10);
   uint tw = 0, th = 0;
   if(!TextGetSize(txt, tw, th)) return (int)StringLen(txt) * fontsize;
   return (int)tw;
}

void PnlLbl(const string sfx, const int x, const int y, const string txt,
            const int fsz, const color clr, const ENUM_ANCHOR_POINT anc)
{
   UIEnsureLabel(sfx, x, y, txt, fsz, clr, "Consolas", anc, 110);
}
void PnlDel(const string sfx) { ObjectDelete(0, UIName(sfx)); }

int PnlBtnW(const string txt, const int fsz) { return UITextW(txt, fsz) + UIS(24); }

void PnlToggle(const string sfx, const int x, const int y, const int bw, const int bh,
               const bool enabled, const bool usable)
{
   color cl, bd;
   if(!usable)      { cl = CLR_DIM;   bd = CLR_BORDER; }
   else if(enabled) { cl = CLR_GREEN; bd = CLR_GREEN;  }
   else             { cl = CLR_DIM;   bd = CLR_BORDER; }

   UIEnsureRect(sfx + "_btn", x, y, bw, bh, CLR_BG2, bd, 106);
   PnlLbl(sfx + "_txt", x + bw / 2, y + bh / 2, (enabled && usable) ? "ON" : "OFF",
          UIFont(9), cl, ANCHOR_CENTER);
   ObjectSetInteger(0, UIName(sfx + "_btn"), OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, UIName(sfx + "_txt"), OBJPROP_SELECTABLE, true);
}

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

//--- warna gradasi P/L
color PLColor(const double v)
{
   if(v > 0.0)  return CLR_GREEN;
   if(v == 0.0) return CLR_DIM;
   return CLR_RED;
}
color LayerColor(const int lay)
{
   if(lay <= 1) return CLR_GREEN;
   if(lay <= 3) return CLR_YELLOW;
   if(lay <= 6) return CLR_ORANGE;
   return CLR_RED;
}

//+------------------------------------------------------------------+
//| Campur warna & gradasi — dipakai baris LIVE agar intensitasnya    |
//| mengikuti seberapa dekat nilai sekarang dengan rekor WORST-nya.   |
//+------------------------------------------------------------------+
int UIRedC  (const color c) { return (int)( (uint)c        & 0xFF); }
int UIGreenC(const color c) { return (int)(((uint)c >>  8) & 0xFF); }
int UIBlueC (const color c) { return (int)(((uint)c >> 16) & 0xFF); }
color UIRGB(const int r, const int g, const int b)
{
   int rr = (r < 0) ? 0 : ((r > 255) ? 255 : r);
   int gg = (g < 0) ? 0 : ((g > 255) ? 255 : g);
   int bb = (b < 0) ? 0 : ((b > 255) ? 255 : b);
   return (color)((bb << 16) | (gg << 8) | rr);
}
color UIMix(const color a, const color b, const double r)
{
   double t = (r < 0.0) ? 0.0 : ((r > 1.0) ? 1.0 : r);
   return UIRGB((int)MathRound(UIRedC(a)   + (UIRedC(b)   - UIRedC(a))   * t),
                (int)MathRound(UIGreenC(a) + (UIGreenC(b) - UIGreenC(a)) * t),
                (int)MathRound(UIBlueC(a)  + (UIBlueC(b)  - UIBlueC(a))  * t));
}

//--- POSISI LIVE — putih -> ungu, mengikuti kedekatan dengan rekor WORST
color PosColor(const int pos, const int worst)
{
   if(pos <= 0) return CLR_DIM;
   double r = (worst > 0) ? MathMin(1.0, (double)pos / (double)worst) : 1.0;
   return UIMix(CLR_TXT, CLR_PURPLE, r);
}
//--- LOT LIVE — kuning -> oranye -> merah, mengikuti kedekatan dgn rekor
color LotColor(const double lot, const double worst)
{
   if(lot <= 0.0) return CLR_DIM;
   double r = (worst > 0.0) ? MathMin(1.0, lot / worst) : 1.0;
   if(r <= 0.5) return UIMix(CLR_YELLOW, CLR_ORANGE, r / 0.5);
   return UIMix(CLR_ORANGE, CLR_RED, (r - 0.5) / 0.5);
}
//--- P/L LIVE — hijau bila untung; merah menggelap mengikuti kedekatan
//    dengan rekor floating terburuk (ref = |g_worstPl[sisi]|)
color PLColorGrad(const double v, const double ref)
{
   if(v > 0.0)  return CLR_GREEN;
   if(v == 0.0) return CLR_DIM;
   double r = (ref > 0.0) ? MathMin(1.0, MathAbs(v) / ref) : 1.0;
   int red   = 255;
   int green = (int)MathRound(150.0 * (1.0 - r)) + 40;
   int blue  = (int)MathRound(120.0 * (1.0 - r)) + 50;
   return UIRGB(red, green, blue);
}

//======================================================================
// UI — WAKTU (WIB MURNI = GMT+7, tanpa penyesuaian apa pun)
//======================================================================
datetime TimeWIBNow()
{
   datetime gmt = TimeGMT();
   if(gmt <= 0) gmt = TimeLocal();
   return gmt + 7 * 3600;
}
string HariID(const int dow)
{
   switch(dow)
   {
      case 0: return "Minggu";  case 1: return "Senin"; case 2: return "Selasa";
      case 3: return "Rabu";    case 4: return "Kamis"; case 5: return "Jumat";
      default: return "Sabtu";
   }
}
string BulanID(const int m)
{
   switch(m)
   {
      case 1: return "Januari";  case 2: return "Februari"; case 3: return "Maret";
      case 4: return "April";    case 5: return "Mei";      case 6: return "Juni";
      case 7: return "Juli";     case 8: return "Agustus";  case 9: return "September";
      case 10:return "Oktober";  case 11:return "November"; default: return "Desember";
   }
}
string RunTimeText()
{
   long sec = (long)(TimeCurrent() - g_eaStartTime);
   if(sec < 0) sec = 0;
   long d = sec / 86400; sec -= d * 86400;
   long h = sec / 3600;  sec -= h * 3600;
   long m = sec / 60;    sec -= m * 60;
   return StringFormat("%03d:%02d:%02d:%02d", (int)d, (int)h, (int)m, (int)sec);
}

//======================================================================
// GARIS TP DI CHART
//   Digambar hanya saat Real TP OFF (mode virtual). Saat Real TP ON,
//   garis TP sudah digambar sendiri oleh terminal dari field TP tiket,
//   sehingga garis EA tidak perlu ditumpuk.
//======================================================================
string TPLineName()    { return UIName("tp_line"); }
string TPLineLblName() { return UIName("tp_line_lbl"); }

void TPLineDelete()
{
   ObjectDelete(0, TPLineName());
   ObjectDelete(0, TPLineLblName());
}

void TPLineSync()
{
   if(!InpShowUI)   { TPLineDelete(); return; }
   if(InpUseRealTP) { TPLineDelete(); return; }

   double fl = 0.0;
   if(CountOpenPositions(fl) <= 0) { TPLineDelete(); return; }

   double lbid = 0.0, lask = 0.0; int ldir = 0;
   if(!ComputeBasketTPPrice(InpTPBasketUSD, fl, lbid, lask, ldir)) { TPLineDelete(); return; }

   double price = (ldir > 0 ? lbid : lask);
   string txt   = StringFormat("TP BASKET %.2f", InpTPBasketUSD);
   string nm    = TPLineName();
   string lb    = TPLineLblName();

   if(ObjectFind(0, nm) < 0)
   {
      if(!ObjectCreate(0, nm, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(0, nm, OBJPROP_BACK, true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, nm, OBJPROP_ZORDER, 2);
   }
   ObjectSetDouble(0, nm, OBJPROP_PRICE, price);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, CLR_YELLOW);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, txt);

   if(ObjectFind(0, lb) < 0)
   {
      if(!ObjectCreate(0, lb, OBJ_TEXT, 0, TimeCurrent(), price)) return;
      ObjectSetInteger(0, lb, OBJPROP_BACK, true);
      ObjectSetInteger(0, lb, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lb, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, lb, OBJPROP_FONTSIZE, 7);
      ObjectSetString(0, lb, OBJPROP_FONT, "Courier New");
      ObjectSetInteger(0, lb, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lb, OBJPROP_ZORDER, 3);
   }
   ObjectSetDouble(0, lb, OBJPROP_PRICE, price);
   ObjectSetInteger(0, lb, OBJPROP_TIME, TimeCurrent());
   ObjectSetString(0, lb, OBJPROP_TEXT, " " + txt);
   ObjectSetInteger(0, lb, OBJPROP_COLOR, CLR_YELLOW);
}

//======================================================================
// TP/SL HISTORY (panel kanan)
//======================================================================
string TPHReasonLabel(const string reason)
{
   if(reason == "TP_BASKET")       return "TP BASKET";
   if(reason == "TP_SWEEP")        return "SISA TP";
   if(reason == "CL_HEDGE")        return "CL HEDGE";
   if(reason == "TP_MAXPOS")       return "TP MAXPOS";
   if(reason == "DAILY_MAXPROFIT") return "DAILY";
   if(reason == "MANUAL_CLOSEALL") return "MANUAL";
   if(reason == "TP_BROKER")       return "TP BROKER";
   return (reason == "" ? "-" : reason);
}

void TPHistoryRender()
{
   if(!InpShowUI) return;
   int px   = UIS(18) + g_pnlPanelW + UIS(12);
   int py   = UIS(40);
   int rowh = UIS(28);
   int w    = UIS(34) + UITextW("TP/SL HISTORY", UIFont(13)) + UIS(14);

   if(!g_tphCollapsed)
      for(int wi = 0; wi < g_tphCount; wi++)
      {
         string wt = StringFormat("%s | %-10s| %+.2f",
                                  TimeToString(g_tphTime[wi], TIME_MINUTES), g_tphReason[wi], g_tphVal[wi]);
         w = MathMax(w, UIS(8) + UITextW(wt, UIFont(11)) + UIS(14));
      }
   g_tphPanelW = w;

   int rows = g_tphCollapsed ? 0 : g_tphCount;
   int hgt  = UIS(28) + rows * rowh + ((rows > 0) ? UIS(24) : UIS(4));

   UIEnsureRect ("tph_bg", px, py, w, hgt, (color)C'12,17,28', (color)C'40,55,75', 50);
   UIEnsureLabel("tph_btn", px + UIS(8), py + UIS(6), g_tphCollapsed ? "[+]" : "[-]",
                 UIFont(10), (color)C'150,165,190', "Consolas", ANCHOR_LEFT_UPPER, 60);
   UIEnsureLabel("tph_ttl", px + UIS(34), py + UIS(6), "TP/SL HISTORY", UIFont(13),
                 (color)C'200,210,225', "Consolas", ANCHOR_LEFT_UPPER, 60);
   ObjectSetInteger(0, UIName("tph_btn"), OBJPROP_SELECTABLE, true);

   double tot = 0.0;
   for(int i = 0; i < TPH_MAX; i++)
   {
      string ln = "tph_r" + (string)i;
      if(g_tphCollapsed || i >= g_tphCount) { ObjectDelete(0, UIName(ln)); continue; }
      tot += g_tphVal[i];
      color c = (g_tphVal[i] >= 0.0) ? (color)C'0,220,120' : (color)C'255,80,90';
      string txt = StringFormat("%s | %-10s| %+.2f",
                                TimeToString(g_tphTime[i], TIME_MINUTES), g_tphReason[i], g_tphVal[i]);
      UIEnsureLabel(ln, px + UIS(8), py + UIS(28) + i * rowh, txt, UIFont(11), c,
                    "Consolas", ANCHOR_LEFT_UPPER, 60);
   }
   if(!g_tphCollapsed && g_tphCount > 0)
   {
      color tc = (tot >= 0.0) ? (color)C'0,220,120' : (color)C'255,80,90';
      UIEnsureLabel("tph_tot", px + UIS(8), py + UIS(28) + g_tphCount * rowh + UIS(2),
                    StringFormat("TOTAL: %+.2f  (%dx close)", tot, g_tpHitCount),
                    UIFont(11), tc, "Consolas", ANCHOR_LEFT_UPPER, 60);
   }
   else ObjectDelete(0, UIName("tph_tot"));
   ChartRedraw(0);
}

void TPHistoryPush(const double profit, const string reason)
{
   for(int i = (int)MathMin(g_tphCount, TPH_MAX - 1); i > 0; i--)
   {
      g_tphVal[i]    = g_tphVal[i-1];
      g_tphTime[i]   = g_tphTime[i-1];
      g_tphReason[i] = g_tphReason[i-1];
   }
   g_tphVal[0]    = profit;
   g_tphTime[0]   = TimeWIBNow();
   g_tphReason[0] = TPHReasonLabel(reason);
   if(g_tphCount < TPH_MAX) g_tphCount++;
   g_tpHitCount++;
   Log(StringFormat("[TPH] %s | %+.2f", g_tphReason[0], profit));
   if(InpShowUI) { PanelRender(); TPHistoryRender(); }
}

//======================================================================
// PANEL UTAMA
//======================================================================
//--- rect WAJIB dibuat lebih dulu supaya tidak menimpa label
void PnlPreCreateRects(const int px, const int py)
{
   string rects[] = {"pnl_bg","hdrbar","st_bg",
                     "s1","s2","s3","s4","s5","s6","s7",
                     "tpa_trk","tpa_fil",
                     "spd_btn","hdg_btn","dlim_btn","ca_btn"};
   for(int i = 0; i < ArraySize(rects); i++)
      if(ObjectFind(0, UIName(rects[i])) < 0)
         UIEnsureRect(rects[i], px, py, 1, 1, CLR_BG, CLR_BG, 100);
}

string StatusText(color &out_clr)
{
   if(g_execActive)      { out_clr = CLR_PURPLE; return "EXIT " + g_execReason; }
   if(DailyLockActive()) { out_clr = CLR_ORANGE; return "DAILY LOCK"; }
   if(IsPauseActive())   { out_clr = CLR_YELLOW; return "PAUSE"; }
   if(CountOpenPositions() > 0) { out_clr = CLR_GREEN; return "RUNNING"; }
   out_clr = CLR_DIM; return "FLAT";
}

void PanelRender()
{
   if(!InpShowUI) return;

   int px = UIS(18);
   int py = UIS(40);
   int hh = UIS(32);   // tinggi header bar — dipakai mode dilipat & mode terbuka
   string title   = "BREAKOUT BASKET v" + EA_VERSION;
   string s_copy  = "Copyright : by \"Bang iNo\"";

   PnlPreCreateRects(px, py);

   //---------------- MODE DILIPAT ----------------
   if(g_pnlCollapsed)
   {
      string dead[] = {"st","mg","mg_id","l_live",
                       "l_pos","l_lot","l_pl","l_lay",
                       "wst_ttl","wst_pos_lbl","wst_lot_lbl","wst_pl_lbl",
                       "lay_a_l","lay_a_v","lay_p_l","lay_p_v","lay_n_l","lay_n_v","l_exi",
                       "tpa_l","tpa_v","rtp_l","rtp_v","tpp_l","tpp_v","l_ent","mxp_l","mxp_v",
                       "trg_l","trg_v","spd_l","trd_l","trd_v","gap_lbl","gap_val","spd_v","hdg_l","spd_txt",
                       "hdg_v","l_akn","hdg_txt",
                       "bal_l","bal_v","eq_l","eq_v","dlim_l","dlim_v","l_wkt","dlim_txt",
                       "t_ttl","t_tgl_l","t_tgl_v","t_jam_l","t_jam_v","t_run_l","t_run_v",
                       "ca_txt"};
      for(int i = 0; i < ArraySize(dead); i++) PnlDel(dead[i]);
      for(int c = 0; c < 3; c++)
      {
         PnlDel("h" + (string)c);
         PnlDel("p_" + (string)c);
         PnlDel("o_" + (string)c);
         PnlDel("g_" + (string)c);
         PnlDel("wst_pos_" + (string)c);
         PnlDel("wst_lot_" + (string)c);
         PnlDel("wst_pl_" + (string)c);
      }
      //--- rect TIDAK dihapus (merusak urutan gambar saat panel dibuka lagi),
      //    cukup dikecilkan 1x1 DAN dimatikan klik-nya supaya tombol yang
      //    tersembunyi tidak ikut menangkap klik di area header.
      string hide[] = {"hdrbar","st_bg","s1","s2","s3","s4","s5","s6","s7",
                       "tpa_trk","tpa_fil","spd_btn","hdg_btn","dlim_btn","ca_btn"};
      for(int i = 0; i < ArraySize(hide); i++)
      {
         UIEnsureRect(hide[i], px, py, 1, 1, CLR_BG, CLR_BG, 100);
         ObjectSetInteger(0, UIName(hide[i]), OBJPROP_SELECTABLE, false);
      }

      int wc = UIS(30) + UITextW(title, UIFont(13)) + UIS(16) + UITextW(s_copy, UIFont(10)) + UIS(10);
      g_pnlPanelW = wc;
      UIEnsureRect("pnl_bg", px, py, wc, hh, CLR_BG, CLR_BORDER, 100);
      PnlLbl("pnl_btn", px + UIS(8),  py + UIS(9), "[+]",  UIFont(10), CLR_DIM, ANCHOR_LEFT_UPPER);
      PnlLbl("pnl_ttl", px + UIS(30), py + UIS(9), title,  UIFont(13), CLR_TXT, ANCHOR_LEFT_UPPER);
      PnlLbl("pnl_cpy", px + wc - UIS(12), py + UIS(11), s_copy, UIFont(10), CLR_DIM, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, UIName("pnl_btn"), OBJPROP_SELECTABLE, true);
      ChartRedraw(0);
      return;
   }

   //================= DATA (read-only) =================
   int    bc = 0, sc = 0;
   double blot = 0.0, slot = 0.0, bpl = 0.0, spl = 0.0;
   SideStats(bc, sc, blot, slot, bpl, spl);
   double tpl = bpl + spl;

   int    topLayer  = GetHighestLayer();
   int    nextLayer = NextLayerNo();
   double nextLot   = LotForLayer(nextLayer);   // recovery: lot upstair/fix (tidak ada lagi lot dasar pemicu untung)

   string hdr[3]  = {"BUY", "SELL", "TOTAL"};
   string cpos[3], clot[3], cpl[3];
   cpos[0] = (string)bc;  cpos[1] = (string)sc;  cpos[2] = (string)(bc + sc);
   clot[0] = StringFormat("%.2f", blot); clot[1] = StringFormat("%.2f", slot); clot[2] = StringFormat("%.2f", blot + slot);
   cpl[0]  = StringFormat("%+.2f", bpl); cpl[1]  = StringFormat("%+.2f", spl); cpl[2]  = StringFormat("%+.2f", tpl);

   //--- WORST (HISTORY TERBURUK) — teks kolom
   string wpos[3], wlot[3], wpl[3];
   wpos[0] = (string)g_worstPos[0]; wpos[1] = (string)g_worstPos[1]; wpos[2] = (string)g_worstPos[2];
   wlot[0] = StringFormat("%.2f", g_worstLot[0]); wlot[1] = StringFormat("%.2f", g_worstLot[1]); wlot[2] = StringFormat("%.2f", g_worstLot[2]);
   wpl[0]  = StringFormat("%+.2f", g_worstPl[0]); wpl[1]  = StringFormat("%+.2f", g_worstPl[1]); wpl[2]  = StringFormat("%+.2f", g_worstPl[2]);

   //--- lebar KOLOM LABEL: dihitung dari SELURUH label kiri di semua
   //    section, supaya satu grid label|nilai konsisten dari atas ke
   //    bawah panel (bukan hanya pada tabel LIVE).
   string labels[] = {"LIVE", "  Posisi", "  Lot", "  P/L", "HISTORY TERBURUK",
                      "LAYER", "  Aktif", "  Arah Init", "  Lot next",
                      "EXIT", "  TP Basket", "  Real TP", "  Harga TP", "  Maks Posisi",
                      "ENTRY / GUARD", "  Trigger", "  Spread", "  Hedge CL",
                      "AKUN", "  Balance", "  Equity", "  Daily Lock",
                      "WAKTU", "  Tanggal", "  Jam", "  Runtime"};
   int labelw = 0;
   for(int i = 0; i < ArraySize(labels); i++) labelw = MathMax(labelw, UITextW(labels[i], UIFont(11)));

   int colw[3];
   for(int c = 0; c < 3; c++)
   {
      int mw = UITextW(hdr[c], UIFont(11));
      mw = MathMax(mw, UITextW(cpos[c], UIFont(11)));
      mw = MathMax(mw, UITextW(clot[c], UIFont(11)));
      mw = MathMax(mw, UITextW(cpl[c],  UIFont(11)));
      mw = MathMax(mw, UITextW(wpos[c], UIFont(11)));
      mw = MathMax(mw, UITextW(wlot[c], UIFont(11)));
      mw = MathMax(mw, UITextW(wpl[c],  UIFont(11)));
      colw[c] = MathMax(mw, UIS(34));
   }

   int pad = UIS(14);
   int gap = UIS(20);
   int colR[3];
   colR[0] = px + pad + labelw + gap + colw[0];
   colR[1] = colR[0] + gap + colw[1];
   colR[2] = colR[1] + gap + colw[2];

   //--- baris teks lebar-penuh
   MqlDateTime dt; TimeToStruct(TimeWIBNow(), dt);
   string s_date = StringFormat("%s, %d %s %d", HariID(dt.day_of_week), dt.day, BulanID(dt.mon), dt.year);
   string s_time = StringFormat("%02d:%02d:%02d WIB", dt.hour, dt.min, dt.sec);
   string s_run  = RunTimeText();

   int    sp_now  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool   sp_off  = (InpMaxSpreadPoints <= 0);
   string s_spd   = sp_off ? StringFormat("%d / off", sp_now)
                           : StringFormat("%d / %d", sp_now, InpMaxSpreadPoints);
   color  spd_c   = (!g_spreadOn || sp_off) ? CLR_DIM
                  : ((sp_now > InpMaxSpreadPoints) ? CLR_RED : CLR_GREEN);

   //--- ARAH INIT siklus berjalan (dari DAILY CHANGE %) + nilai persen LIVE
   bool   dcOk = false;
   double dcPct = DailyChangePct(dcOk);
   string s_ini; color ini_c;
   if(g_initSide > 0)      { s_ini = StringFormat("BUY (%+.2f%%)", dcPct);  ini_c = CLR_BLUE;  }   // biru / plus
   else if(g_initSide < 0) { s_ini = StringFormat("SELL (%+.2f%%)", dcPct); ini_c = CLR_RED;   }   // merah / minus
   else if(dcOk)           { s_ini = StringFormat("tunggu (%+.2f%%)", dcPct); ini_c = CLR_DIM; }
   else                    { s_ini = "tunggu (-)"; ini_c = CLR_DIM; }

   //--- HEDGE CL
   string s_hdg; color hdg_c;
   if(!g_hedgeOn) { s_hdg = "off"; hdg_c = CLR_DIM; }
   else if(g_hedgeSince == 0) { s_hdg = StringFormat("siaga / %dm", InpHedgeCLMinutes); hdg_c = CLR_GREEN; }
   else
   {
      int el = (int)((TimeCurrent() - g_hedgeSince) / 60);
      s_hdg = StringFormat("%dm / %dm", el, InpHedgeCLMinutes);
      hdg_c = CLR_ORANGE;
   }

   //--- DAILY
   string s_daily = StringFormat("%.2f / %.0f", g_dailyNetCache, DailyLimitValue());
   color  daily_c = (!g_dailyOn) ? CLR_DIM
                  : (g_dailyLocked ? CLR_ORANGE : ((g_dailyNetCache >= 0.0) ? CLR_GREEN : CLR_RED));

   //--- RECOVERY: layer berikutnya hanya dipicu saat layer terakhir RUGI
   double thrL    = MathAbs(InpLayerTriggerUSD) * (topLayer > 0 ? LayerLotRatio(topLayer) : 1.0);  // ambang rugi: x lot layer terakhir / InpLot
   double topFl   = 0.0;
   if(topLayer > 0) TopLayerFloating(topLayer, topFl);   // floating layer tertinggi saja
   string s_trg   = (InpLayerTriggerUSD == 0.0) ? "off"
                  : ((topLayer <= 0) ? "-"
                     : StringFormat("#%d %+.2f / -%.2f", topLayer, topFl, thrL));
   color  trg_c   = (InpLayerTriggerUSD == 0.0 || topLayer <= 0) ? CLR_DIM
                  : ((topFl <= -thrL) ? CLR_ORANGE : CLR_DIM);

   //--- HARGA TP
   string s_tpp; color tpp_c = CLR_DIM;
   {
      double lbid = 0.0, lask = 0.0; int ldir = 0;
      if((bc + sc) > 0 && ComputeBasketTPPrice(InpTPBasketUSD, tpl, lbid, lask, ldir))
      {
         s_tpp = DoubleToString((ldir > 0 ? lbid : lask), _Digits);
         tpp_c = CLR_YELLOW;
      }
      else s_tpp = "-";
   }

   //--- BATAS POSISI
   int    posNow = bc + sc;
   string s_mxp; color mxp_c;
   if(InpMaxPositions <= 0) { s_mxp = "off"; mxp_c = CLR_DIM; }
   else
   {
      s_mxp = StringFormat("%d / %d  (TP %s)", posNow, InpMaxPositions, (InpMaxPosTP ? "on" : "off"));
      mxp_c = (posNow >= InpMaxPositions) ? CLR_RED
            : ((posNow * 10 >= InpMaxPositions * 8) ? CLR_ORANGE : CLR_DIM);
   }

   //--- lebar panel
   color st_c = CLR_DIM; string s_status = StatusText(st_c);
   string s_lotnext = StringFormat("%.2f  (#%d%s)", nextLot, nextLayer,
                                   (InpLotUpstairOn ? " upstair" : " fix"));
   int w = colR[2] + pad - px;
   w = MathMax(w, UIS(30) + UITextW(title, UIFont(13)) + UIS(16) + UITextW(s_copy, UIFont(10)) + UIS(10));
   w = MathMax(w, pad * 2 + UITextW(s_date, UIFont(11)) + UIS(20));
   w = MathMax(w, pad * 2 + UITextW("Runtime  " + s_run, UIFont(11)) + UIS(20));
   //--- kolom kanan: nilai terpanjang tidak boleh menabrak label kiri
   {
      string rights[9];
      rights[0] = s_status;
      rights[1] = s_lotnext;
      rights[2] = s_trg;
      rights[3] = s_ini;
      rights[4] = s_tpp;
      rights[5] = StringFormat("%+.2f / %.2f", tpl, InpTPBasketUSD);
      rights[6] = s_daily;
      rights[7] = s_hdg;
      rights[8] = s_mxp;
      int rmax = 0;
      for(int i = 0; i < 9; i++) rmax = MathMax(rmax, UITextW(rights[i], UIFont(11)));
      //--- +UIS(70) menyediakan ruang tombol ON/OFF pada baris bersaklar
      //    plus sedikit napas ekstra supaya tidak terkesan mepet
      w = MathMax(w, pad * 2 + labelw + gap + rmax + UIS(70));
   }
   g_pnlPanelW = w;

   //--- tabel LIVE & HISTORY TERBURUK tetap RATA KANAN: bila panel melebar karena
   //    teks kolom kanan (Trigger, Maks Posisi, dst), geser ketiga kolom
   //    agar kolom terakhir kembali menempel tepi kanan panel
   {
      int shiftR = (px + w - pad) - colR[2];
      if(shiftR > 0) { colR[0] += shiftR; colR[1] += shiftR; colR[2] += shiftR; }
   }

   int rh      = UIS(24);   // tinggi baris normal
   int statusH = UIS(26);   // tinggi bar STATUS
   int gapPre  = UIS(8);    // jarak sebelum garis pemisah section
   int gapPost = UIS(12);   // jarak setelah garis pemisah, sebelum judul section
   int y       = py;

   //--- HEADER BAR (ukuran w & hh sudah pasti; TIDAK bergantung tinggi
   //    total, jadi aman digambar lebih dulu)
   UIEnsureRect("hdrbar", px, py, w, hh, CLR_HDRBAR, CLR_BORDER, 101);
   PnlLbl("pnl_btn", px + UIS(10), py + UIS(9), "[-]", UIFont(10), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("pnl_ttl", px + UIS(32), py + UIS(9), title, UIFont(13), CLR_TXT, ANCHOR_LEFT_UPPER);
   PnlLbl("pnl_cpy", px + w - UIS(12), py + UIS(11), s_copy, UIFont(10), CLR_DIM, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, UIName("pnl_btn"), OBJPROP_SELECTABLE, true);

   y = py + hh;

   //--- STATUS bar
   UIEnsureRect("st_bg", px, y, w, statusH, CLR_BG2, CLR_BG2, 102);
   PnlLbl("st", px + pad, y + UIS(6), "STATUS", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("mg", px + w - pad, y + UIS(6), s_status, UIFont(11), st_c, ANCHOR_RIGHT_UPPER);
   y += statusH + UIS(6);

   //--- SYMBOL | MAGIC
   PnlLbl("mg_id", px + pad, y, _Symbol, UIFont(11), CLR_PAIR, ANCHOR_LEFT_UPPER);
   PnlLbl("l_live", px + w - pad, y, StringFormat("#%I64d", InpMagic), UIFont(11), CLR_MAGIC, ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= SECTION LIVE =================
   y += gapPre;
   UIEnsureRect("s1", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("l_pos", px + pad, y, "LIVE", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   for(int c = 0; c < 3; c++)
      PnlLbl("h" + (string)c, colR[c], y, hdr[c], UIFont(11), CLR_DIM, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("l_lot", px + pad, y, "  Posisi", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("p_0", colR[0], y, cpos[0], UIFont(11), PosColor(bc, g_worstPos[0]), ANCHOR_RIGHT_UPPER);
   PnlLbl("p_1", colR[1], y, cpos[1], UIFont(11), PosColor(sc, g_worstPos[1]), ANCHOR_RIGHT_UPPER);
   PnlLbl("p_2", colR[2], y, cpos[2], UIFont(11), PosColor(bc + sc, g_worstPos[2]), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("l_pl", px + pad, y, "  Lot", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("o_0", colR[0], y, clot[0], UIFont(11), LotColor(blot, g_worstLot[0]), ANCHOR_RIGHT_UPPER);
   PnlLbl("o_1", colR[1], y, clot[1], UIFont(11), LotColor(slot, g_worstLot[1]), ANCHOR_RIGHT_UPPER);
   PnlLbl("o_2", colR[2], y, clot[2], UIFont(11), LotColor(blot + slot, g_worstLot[2]), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("l_lay", px + pad, y, "  P/L", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("g_0", colR[0], y, cpl[0], UIFont(11), PLColorGrad(bpl, MathAbs(g_worstPl[0])), ANCHOR_RIGHT_UPPER);
   PnlLbl("g_1", colR[1], y, cpl[1], UIFont(11), PLColorGrad(spl, MathAbs(g_worstPl[1])), ANCHOR_RIGHT_UPPER);
   PnlLbl("g_2", colR[2], y, cpl[2], UIFont(11), PLColorGrad(tpl, MathAbs(g_worstPl[2])), ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= SECTION HISTORY TERBURUK (WORST) =================
   y += gapPre;
   UIEnsureRect("s2", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("wst_ttl", px + pad, y, "HISTORY TERBURUK", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   PnlLbl("wst_pos_lbl", px + pad, y, "  Posisi", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("wst_pos_0", colR[0], y, wpos[0], UIFont(11), (g_worstPos[0] > 0 ? CLR_W_POS : CLR_DIM), ANCHOR_RIGHT_UPPER);
   PnlLbl("wst_pos_1", colR[1], y, wpos[1], UIFont(11), (g_worstPos[1] > 0 ? CLR_W_POS : CLR_DIM), ANCHOR_RIGHT_UPPER);
   PnlLbl("wst_pos_2", colR[2], y, wpos[2], UIFont(11), (g_worstPos[2] > 0 ? CLR_W_POS : CLR_DIM), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("wst_lot_lbl", px + pad, y, "  Lot", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("wst_lot_0", colR[0], y, wlot[0], UIFont(11), (g_worstLot[0] > 0.0 ? CLR_W_LOT : CLR_DIM), ANCHOR_RIGHT_UPPER);
   PnlLbl("wst_lot_1", colR[1], y, wlot[1], UIFont(11), (g_worstLot[1] > 0.0 ? CLR_W_LOT : CLR_DIM), ANCHOR_RIGHT_UPPER);
   PnlLbl("wst_lot_2", colR[2], y, wlot[2], UIFont(11), (g_worstLot[2] > 0.0 ? CLR_W_LOT : CLR_DIM), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("wst_pl_lbl", px + pad, y, "  P/L", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   for(int c = 0; c < 3; c++)
      PnlLbl("wst_pl_" + (string)c, colR[c], y, wpl[c], UIFont(11),
             (g_worstPl[c] == 0.0 ? CLR_DIM : (g_worstPl[c] > 0.0 ? CLR_W_PLP : CLR_W_PLN)),
             ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= SECTION LAYER =================
   y += gapPre;
   UIEnsureRect("s3", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("lay_a_l", px + pad, y, "LAYER", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   PnlLbl("lay_a_v", px + pad, y, "  Aktif", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("lay_p_l", px + w - pad, y, (topLayer <= 0 ? "-" : "#" + IntegerToString(topLayer)),
          UIFont(11), LayerColor(topLayer), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("lay_p_v", px + pad, y, "  Arah Init", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("lay_n_l", px + w - pad, y, s_ini, UIFont(11), ini_c, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("lay_n_v", px + pad, y, "  Lot next", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("l_exi", px + w - pad, y, s_lotnext, UIFont(11), CLR_YELLOW, ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= SECTION EXIT =================
   y += gapPre;
   UIEnsureRect("s4", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("tpa_l", px + pad, y, "EXIT", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   {
      string s_tpprog = StringFormat("%+.2f / %.2f", tpl, InpTPBasketUSD);
      PnlLbl("tpa_v", px + pad, y, "  TP Basket", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
      PnlLbl("rtp_l", px + w - pad, y, s_tpprog, UIFont(11), PLColor(tpl), ANCHOR_RIGHT_UPPER);
      //--- progress bar, mengisi ruang antara label & angka
      int trk_x = px + pad + labelw + gap;
      int trk_w = (px + w - pad) - trk_x - UITextW(s_tpprog, UIFont(11)) - UIS(12);
      if(trk_w < UIS(20)) trk_w = UIS(20);
      double rat = (InpTPBasketUSD > 0.0) ? (tpl / InpTPBasketUSD) : 0.0;
      if(rat < 0.0) rat = 0.0;
      if(rat > 1.0) rat = 1.0;
      int fil_w = (int)MathRound(trk_w * rat);
      UIEnsureRect("tpa_trk", trk_x, y + UIS(8), trk_w, UIS(6), CLR_TRACK, CLR_TRACK, 104);
      UIEnsureRect("tpa_fil", trk_x, y + UIS(8), (fil_w < 1 ? 1 : fil_w), UIS(6),
                   (rat >= 1.0 ? CLR_GREEN : CLR_BLUE), (rat >= 1.0 ? CLR_GREEN : CLR_BLUE), 105);
   }
   y += rh;

   PnlLbl("rtp_v", px + pad, y, "  Real TP", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("tpp_l", px + w - pad, y, (InpUseRealTP ? "ON" : "virtual"),
          UIFont(11), (InpUseRealTP ? CLR_GREEN : CLR_DIM), ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("tpp_v", px + pad, y, "  Harga TP", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("l_ent", px + w - pad, y, s_tpp, UIFont(11), tpp_c, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("mxp_l", px + pad, y, "  Maks Posisi", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("mxp_v", px + w - pad, y, s_mxp, UIFont(11), mxp_c, ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= SECTION ENTRY / GUARD =================
   int tgl_w  = PnlBtnW("OFF", UIFont(9));
   int tgl_h  = UIS(16);
   int tgl_x  = px + w - pad - tgl_w;

   y += gapPre;
   UIEnsureRect("s5", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("trg_l", px + pad, y, "ENTRY / GUARD", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   PnlLbl("trg_v", px + pad, y, "  Trigger", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("spd_l", px + w - pad, y, s_trg, UIFont(11), trg_c, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("spd_v", px + pad, y, "  Spread", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("hdg_l", tgl_x - UIS(12), y, s_spd, UIFont(11), spd_c, ANCHOR_RIGHT_UPPER);
   PnlToggle("spd", tgl_x, y + UIS(2), tgl_w, tgl_h, g_spreadOn, !sp_off);
   y += rh;

   PnlLbl("hdg_v", px + pad, y, "  Hedge CL", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("l_akn", tgl_x - UIS(12), y, s_hdg, UIFont(11), hdg_c, ANCHOR_RIGHT_UPPER);
   PnlToggle("hdg", tgl_x, y + UIS(2), tgl_w, tgl_h, g_hedgeOn, InpEnableHedgeCL);
   y += rh;

   //================= SECTION AKUN =================
   y += gapPre;
   UIEnsureRect("s6", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("bal_l", px + pad, y, "AKUN", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   PnlLbl("bal_v", px + pad, y, "  Balance", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("eq_l", px + w - pad, y, StringFormat("%.2f", AccountInfoDouble(ACCOUNT_BALANCE)),
          UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("eq_v", px + pad, y, "  Equity", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("dlim_l", px + w - pad, y, StringFormat("%.2f", AccountInfoDouble(ACCOUNT_EQUITY)),
          UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("dlim_v", px + pad, y, "  Daily Lock", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("l_wkt", tgl_x - UIS(12), y, s_daily, UIFont(11), daily_c, ANCHOR_RIGHT_UPPER);
   PnlToggle("dlim", tgl_x, y + UIS(2), tgl_w, tgl_h, g_dailyOn, true);
   y += rh;

   //================= SECTION WAKTU =================
   y += gapPre;
   UIEnsureRect("s7", px + pad, y, w - pad * 2, 1, CLR_BORDER, CLR_BORDER, 103);
   y += gapPost;
   PnlLbl("t_ttl", px + pad, y, "WAKTU", UIFont(11), CLR_CYAN, ANCHOR_LEFT_UPPER);
   y += rh;

   PnlLbl("t_tgl_l", px + pad, y, "  Tanggal", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("t_tgl_v", px + w - pad, y, s_date, UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("t_jam_l", px + pad, y, "  Jam", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("t_jam_v", px + w - pad, y, s_time, UIFont(11), CLR_TXT, ANCHOR_RIGHT_UPPER);
   y += rh;

   PnlLbl("t_run_l", px + pad, y, "  Runtime", UIFont(11), CLR_DIM, ANCHOR_LEFT_UPPER);
   PnlLbl("t_run_v", px + w - pad, y, s_run, UIFont(11), CLR_DIM, ANCHOR_RIGHT_UPPER);
   y += rh;

   //================= TOMBOL CLOSE ALL =================
   y += gapPre;
   {
      int caw = PnlBtnW("CLOSE ALL", UIFont(9));
      int cah = UIS(20);
      bool usable = ((bc + sc + CountPendingOrders()) > 0) && !g_execActive;
      PnlActionBtn("ca", px + w - pad - caw, y, caw, cah, "CLOSE ALL", CLR_RED, usable);
      y += cah;
   }
   y += UIS(16);   // margin bawah supaya tombol tidak mepet ke tepi kartu

   //--- LATAR KARTU: tinggi ditentukan TERAKHIR dari total y yang benar-benar
   //    terpakai, bukan formula tebakan — kartu selalu pas, tidak pernah
   //    terpotong maupun menyisakan ruang kosong berlebih di bawah.
   UIEnsureRect("pnl_bg", px, py, w, (y - py), CLR_BG, CLR_BORDER, 100);

   ChartRedraw(0);
}

//--- render lengkap (panel + history + garis TP), dibatasi ~4x/detik
//    supaya pengukuran teks tidak membebani tiap tick.
uint g_uiLastRender = 0;
void UIRenderAll(const bool force = false)
{
   if(!InpShowUI) return;
   uint now = GetTickCount();
   if(!force && g_uiLastRender != 0 && (now - g_uiLastRender) < 250) return;
   g_uiLastRender = now;
   PanelRender();
   TPHistoryRender();
   TPLineSync();
}

//======================================================================
// CLOSE ALL MANUAL (tombol panel) — sinkron + retry
//   InpMaxRetries  : batas percobaan ulang close/delete
//   InpRetrySleepMs: jeda antar percobaan
//   Sisa yang belum bersih diserahkan ke eksekutor async.
//======================================================================
void ManualCloseAllRetry()
{
   int attempt = 0;
   while(attempt < InpMaxRetries)
   {
      attempt++;
      trade.SetAsyncMode(false);

      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!orderInfo.SelectByIndex(i)) continue;
         if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != (long)InpMagic) continue;
         trade.OrderDelete(orderInfo.Ticket());
      }
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
         trade.PositionClose(posInfo.Ticket());
      }

      if(CountOpenPositions() == 0 && CountPendingOrders() == 0)
      {
         Log(StringFormat("[MANUAL-CLOSEALL] Bersih pada percobaan ke-%d", attempt));
         return;
      }
      Sleep(InpRetrySleepMs);
   }
   Log(StringFormat("[MANUAL-CLOSEALL] %d percobaan belum bersih -> diserahkan ke eksekutor async", InpMaxRetries));
}

//+------------------------------------------------------------------+
//| EKSEKUTOR EXIT (async + snapshot + verify + force retry)          |
//+------------------------------------------------------------------+
void ExecResetState()
{
   g_execActive = false;
   g_execState  = EXEC_IDLE;
   g_execNext   = 0;
   g_execCycles = 0;
   g_execForce  = 0;
   g_execReason = "";
   ArrayFree(g_execPos);
   ArrayFree(g_execOrd);
   trade.SetAsyncMode(false);
}

void ResetAfterClear()
{
   g_prevOpenPositions  = 0;
   g_hadPositions       = false;
   g_unifiedActive      = false;
   g_unifiedDir         = 0;
   g_unifiedLastMod     = 0;
   g_lastLoggedProfit   = 0.0;
   g_lastLoggedPositions= -1;
   g_initSide           = 0;   // siklus baru -> arah init dihitung ulang dari daily change %
   g_marketLayerNo      = 0;
   g_marketLayerTime    = 0;
   g_hedgeSince         = 0;
   g_cycleStart         = 0;   // siklus baru -> acuan realized TP/SL history direset
   TPLineDelete();             // basket kosong -> garis TP virtual dihapus
}

void ExecCollectSnapshot()
{
   ArrayFree(g_execPos);
   ArrayFree(g_execOrd);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != (long)InpMagic) continue;
      int n = ArraySize(g_execOrd);
      ArrayResize(g_execOrd, n + 1);
      g_execOrd[n] = orderInfo.Ticket();
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != (long)InpMagic) continue;
      int n = ArraySize(g_execPos);
      ArrayResize(g_execPos, n + 1);
      g_execPos[n] = posInfo.Ticket();
   }
}

bool ExecPositionExists(const ulong t)
{
   if(t == 0) return false;
   if(!PositionSelectByTicket(t)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return false;
   return true;
}
bool ExecOrderExists(const ulong t)
{
   if(t == 0) return false;
   if(!OrderSelect(t)) return false;
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   if(OrderGetInteger(ORDER_MAGIC) != InpMagic) return false;
   return true;
}

//--- Kirim SEMUA perintah close dalam satu loop tanpa jeda (async)
int ExecSendOps()
{
   trade.SetAsyncMode(true);       // tidak menunggu balasan server per tiket
   int sent = 0;

   for(int i = 0; i < ArraySize(g_execOrd); i++)
   {
      ulong t = g_execOrd[i];
      if(!ExecOrderExists(t)) continue;
      trade.OrderDelete(t);
      sent++;
   }
   for(int i = 0; i < ArraySize(g_execPos); i++)
   {
      ulong t = g_execPos[i];
      if(!ExecPositionExists(t)) continue;
      trade.PositionClose(t);
      sent++;
   }
   return sent;
}

bool ExecVerify(int &pos_left, int &ord_left)
{
   pos_left = CountOpenPositions();
   ord_left = CountPendingOrders();
   return (pos_left == 0 && ord_left == 0);
}

void ExecStart(const string reason, const double profit_snapshot)
{
   if(g_execActive) return;
   g_execActive = true;
   g_execState  = EXEC_INIT;
   g_execReason = reason;
   g_execNext   = TimeCurrent();
   g_execCycles = 0;
   g_execForce  = 0;
   Log(StringFormat("[EXIT-START] reason=%s | floating=%.2f | target=%.2f", reason, profit_snapshot, InpTPBasketUSD));
}

void ExecProcess()
{
   if(!g_execActive) return;
   datetime now = TimeCurrent();
   if(g_execNext > 0 && now < g_execNext) return;

   if(g_execState == EXEC_INIT)
   {
      ExecCollectSnapshot();
      Log(StringFormat("[EXIT-INIT] snapshot posisi=%d | pending=%d", ArraySize(g_execPos), ArraySize(g_execOrd)));
      g_execState = EXEC_SEND;
      g_execNext  = now;          // lanjut segera, tanpa jeda
      ExecProcess();              // rantai langsung supaya kirim di tick yang sama
      return;
   }

   if(g_execState == EXEC_SEND)
   {
      int sent = ExecSendOps();
      Log(StringFormat("[EXIT-SEND] terkirim=%d | siklus=%d/%d", sent, g_execCycles, InpExitRetries));
      g_execState = EXEC_VERIFY;
      g_execNext  = now;          // verifikasi pada tick/timer berikutnya (200 ms)
      return;
   }

   if(g_execState == EXEC_VERIFY)
   {
      int pl = 0, ol = 0;
      if(ExecVerify(pl, ol))
      {
         Log("[EXIT-VERIFY-OK] posisi=0 | pending=0");
         g_execState = EXEC_DONE;
         g_execNext  = now;
         ExecProcess();
         return;
      }
      g_execCycles++;
      Log(StringFormat("[EXIT-VERIFY-FAIL] sisa posisi=%d | pending=%d | retry %d", pl, ol, g_execCycles));
      ExecCollectSnapshot();
      g_execState = (g_execCycles >= InpExitRetries) ? EXEC_FORCE : EXEC_SEND;
      g_execNext  = now;
      return;
   }

   if(g_execState == EXEC_FORCE)
   {
      int sent = ExecSendOps();
      g_execForce++;
      Log(StringFormat("[EXIT-FORCE] terkirim=%d | force=%d", sent, g_execForce));
      int pl = 0, ol = 0;
      if(ExecVerify(pl, ol))
      {
         g_execState = EXEC_DONE;
         g_execNext  = now;
         ExecProcess();
         return;
      }
      ExecCollectSnapshot();
      // tidak pernah menyerah ke DONE selama masih ada sisa (anti basket pincang)
      g_execNext = now + (g_execForce >= (InpExitRetries * 2) ? 5 : 1);
      return;
   }

   if(g_execState == EXEC_DONE)
   {
      int pl = 0, ol = 0;
      if(!ExecVerify(pl, ol))
      {
         Log(StringFormat("[EXIT-DONE-RECHECK-FAIL] sisa posisi=%d | pending=%d", pl, ol));
         ExecCollectSnapshot();
         g_execState = EXEC_FORCE;
         g_execNext  = now;
         return;
      }
      Log(StringFormat("[EXIT-DONE] basket tuntas (reason=%s)", g_execReason));
      //--- catat hasil siklus ke TP/SL HISTORY (realized murni, bukan floating)
      {
         string rsn      = g_execReason;
         double realized = RealizedSince(g_cycleStart);
         ExecResetState();
         ResetAfterClear();
         TPHistoryPush(realized, rsn);
      }
      int p = InpPauseAfterTPSec; if(p < 0) p = 0;
      g_pauseUntil = TimeCurrent() + (datetime)p;
      return;
   }
}

//+------------------------------------------------------------------+
//| Deteksi TP broker terisi sebagian -> sapu sisanya                 |
//+------------------------------------------------------------------+
bool RecentBrokerTPClose(const int window_sec)
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 300, now + 60)) return false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if((datetime)HistoryDealGetInteger(tk, DEAL_TIME) < now - window_sec) break;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)InpMagic) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      ENUM_DEAL_REASON r = (ENUM_DEAL_REASON)HistoryDealGetInteger(tk, DEAL_REASON);
      if(r == DEAL_REASON_TP || r == DEAL_REASON_SL) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ENTRY                                                             |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;     // filter memang tidak dipakai
   if(!g_spreadOn)             return true;     // saklar panel: filter dimatikan runtime
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > InpMaxSpreadPoints)
   {
      Log(StringFormat("[FILTER-SPREAD] Spread %d > max %d poin. Entry ditunda.", sp, InpMaxSpreadPoints));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| DAILY CHANGE (%)                                                  |
//| = (harga sekarang - close D1 kemarin) / close D1 kemarin x 100.   |
//| Dihitung sendiri dari candle D1 (BUKAN properti simbol broker)    |
//| supaya benar juga di Strategy Tester. out_ok=false bila candle    |
//| D1 atau harga belum tersedia.                                     |
//+------------------------------------------------------------------+
double DailyChangePct(bool &out_ok)
{
   out_ok = false;
   double closePrev = iClose(_Symbol, PERIOD_D1, 1);
   if(closePrev <= 0.0) return 0.0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0) price = SymbolInfoDouble(_Symbol, SYMBOL_LAST);
   if(price <= 0.0) return 0.0;
   out_ok = true;
   return (price - closePrev) / closePrev * 100.0;
}

//+------------------------------------------------------------------+
//| ARAH INIT dari DAILY CHANGE %                                     |
//|   change > +ambang -> BUY  (+1)  [biru / plus]                    |
//|   change < -ambang -> SELL (-1)  [merah / minus]                  |
//|   di antaranya      -> 0 (TIDAK ada init; EA menunggu)            |
//| "Lebih dari" KETAT: tepat +ambang / -ambang BELUM memicu.         |
//+------------------------------------------------------------------+
int InitDirection(string &src)
{
   bool ok = false;
   double pct = DailyChangePct(ok);
   if(!ok) { src = "daily change: data candle D1 belum cukup"; return 0; }

   double thr = MathAbs(InpInitDailyPct);
   if(thr <= 0.0) { src = StringFormat("daily change %+.2f%% (ambang 0 -> nonaktif)", pct); return 0; }

   if(pct >  thr) { src = StringFormat("daily change %+.2f%% (> +%.2f%% -> BUY)", pct, thr); return  1; }
   if(pct < -thr) { src = StringFormat("daily change %+.2f%% (< -%.2f%% -> SELL)", pct, thr); return -1; }
   src = StringFormat("daily change %+.2f%% (di antara -%.2f%% s/d +%.2f%% -> tunggu)", pct, thr, thr);
   return 0;
}

//+------------------------------------------------------------------+
//| SISI INIT dari posisi yang terbuka                                |
//| = sisi posisi ber-komentar layer PALING RENDAH (bila sama, yang   |
//| paling dulu dibuka). Dipakai memulihkan g_initSide setelah        |
//| restart/reattach saat basket sedang berjalan.                     |
//+------------------------------------------------------------------+
int InitSideFromPositions()
{
   int  bestLay = 0, side = 0;
   long bestT = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      int lay = ParseLayer(PositionGetString(POSITION_COMMENT));
      if(lay <= 0) continue;
      long t = PositionGetInteger(POSITION_TIME_MSC);
      if(bestLay == 0 || lay < bestLay || (lay == bestLay && t < bestT))
      {
         bestLay = lay;
         bestT   = t;
         side    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      }
   }
   return side;
}

//+------------------------------------------------------------------+
//| Buang sisa pending order EA (mis. dari versi lama berbasis        |
//| breakout) supaya tidak ada entry di luar init market.             |
//+------------------------------------------------------------------+
void DeleteLegacyPendings()
{
   if(CountPendingOrders() <= 0) return;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != (long)InpMagic) continue;
      trade.OrderDelete(orderInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| INIT ENTRY — dipanggil saat 0 posisi (dan tidak pause/terkunci).  |
//| Arah dihitung SEGAR dari DAILY CHANGE % tiap kali init akan       |
//| dibuka, jadi setelah TP/CL arah selalu diperbarui. Di antara      |
//| -ambang..+ambang tidak ada init (EA menunggu). Market order #1.   |
//+------------------------------------------------------------------+
void InitEntry()
{
   DeleteLegacyPendings();

   string src;
   int dir = InitDirection(src);
   if(dir == 0) return;              // arah belum bisa ditentukan -> coba lagi tick berikutnya

   if(OpenMarketLayer(1, (dir > 0)))
   {
      g_initSide     = dir;
      g_lastInitSide = dir;
      Log(StringFormat("[INIT-ENTRY] Layer #1 %s | arah dari %s", (dir > 0 ? "BUY" : "SELL"), src));
   }
}

//+------------------------------------------------------------------+
//| FLOATING LAYER TERTINGGI                                          |
//| Jumlah (profit + swap) posisi ber-komentar layer tertinggi saja.  |
//| Bila layer itu punya lebih dari satu posisi (double-fill),        |
//| semuanya dijumlahkan. Kembali false bila layer tsb tak punya      |
//| posisi aktif.                                                     |
//+------------------------------------------------------------------+
bool TopLayerFloating(const int topLayer, double &outProfit)
{
   outProfit = 0.0;
   if(topLayer <= 0) return false;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      if(ParseLayer(PositionGetString(POSITION_COMMENT)) != topLayer) continue;
      outProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      found = true;
   }
   return found;
}

//+------------------------------------------------------------------+
//| RASIO LOT LAYER TERTINGGI                                         |
//| = total volume posisi layer tertinggi (double-fill dijumlahkan)   |
//| dibagi InpLot, minimal 1. Dipakai menskalakan ambang trigger sisi |
//| RUGI agar jarak HARGA antar layer tetap walau lot naik (nilai $   |
//| per poin ikut naik sebanding dengan lot).                         |
//+------------------------------------------------------------------+
double LayerLotRatio(const int topLayer)
{
   if(topLayer <= 0 || InpLot <= 0.0) return 1.0;
   double vol = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      if(ParseLayer(PositionGetString(POSITION_COMMENT)) != topLayer) continue;
      vol += PositionGetDouble(POSITION_VOLUME);
   }
   if(vol <= 0.0) return 1.0;
   return MathMax(1.0, vol / InpLot);
}

//+------------------------------------------------------------------+
//| RE-ENTRY MARKET INSTAN (layer #2 dst)                             |
//| Membuka SATU posisi market ber-komentar "#N" (bukan pending pair).|
//| Lot = LotForLayer(N, baseLot); baseLot=true -> lot dasar saja    |
//| (tanpa tangga per layer). Filter spread, Daily Lock, dan         |
//| penjaga anti-duplikat komentar tetap berlaku. Gagal -> false;     |
//| pemanggil mencoba lagi pada tick berikutnya.                      |
//+------------------------------------------------------------------+
bool OpenMarketLayer(const int layerNo, const bool isBuy, const bool baseLot = false)
{
   if(!SpreadOK()) return false;
   if(DailyLockActive())
   {
      Log("[DAILY-LOCK] Entry ditahan — batas profit harian tercapai.");
      return false;
   }
   if(CountPositionsByLayer(layerNo) > 0)
   {
      Log(StringFormat("[MARKET-SKIP] Layer #%d sudah punya posisi aktif -> market entry dibatalkan (anti duplikat)", layerNo));
      return false;
   }

   double lot = LotForLayer(layerNo, baseLot);
   if(lot <= 0.0) return false;
   string comment = "#" + IntegerToString(layerNo);

   trade.SetAsyncMode(false);
   trade.SetExpertMagicNumber(InpMagic);

   bool ok = isBuy ? trade.Buy (lot, _Symbol, 0.0, 0.0, 0.0, comment)
                   : trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);
   if(ok)
      Log(StringFormat("[MARKET-OK] Layer %s | %s | Lot %.2f (%s) | Ticket %I64u",
                       comment, (isBuy ? "BUY" : "SELL"), lot, (baseLot ? "dasar" : (InpLotUpstairOn ? "upstair" : "fix")),
                       trade.ResultOrder()));
   else
      Log(StringFormat("[MARKET-FAIL] Layer %s | %s | rc=%d | %s",
                       comment, (isBuy ? "BUY" : "SELL"), trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return ok;
}

//+------------------------------------------------------------------+
//| CEK RECOVERY LAYER (RE-ENTRY HANYA SAAT MINUS)                    |
//| Cek floating LAYER TERTINGGI saja (bukan total basket) terhadap   |
//| ambang berbasis |InpLayerTriggerUSD| (tidak dikali no. layer).    |
//|   Nilai = ambang pada lot awal (InpLot). Layer baru HANYA ditambah|
//|   saat RUGI: floating <= -(nilai x lot layer terakhir / InpLot),  |
//|   sehingga jarak harga antar layer tetap walau lot naik. Sisi     |
//|   UNTUNG TIDAK lagi memicu re-entry (recovery saja). Nilai 0 =    |
//|   recovery nonaktif.                                              |
//| Arah layer baru = arah INIT siklus berjalan (daily change %).     |
//| Lot layer baru = lot upstair (sesuai nomor layer).                |
//| Layer baru = 1 posisi MARKET instan. Satu layer per kejadian:     |
//| selama market order yang baru dikirim belum terbaca sebagai       |
//| posisi (maks 5 detik), trigger berikutnya ditahan.                |
//+------------------------------------------------------------------+
void CheckLayerTrigger()
{
   if(DailyLockActive()) return;      // batas profit harian tercapai -> tidak ada layer baru
   if(InpLayerTriggerUSD == 0.0) return;   // 0 = recovery nonaktif

   //--- BATAS POSISI: sudah penuh -> tidak ada layer baru
   if(InpMaxPositions > 0)
   {
      static bool s_maxLogged = false;
      if(CountOpenPositions() >= InpMaxPositions)
      {
         if(!s_maxLogged)
         {
            Log(StringFormat("[MAXPOS] Posisi mencapai batas %d -> re-entry layer baru ditahan%s", InpMaxPositions,
                             (InpMaxPosTP ? " | menunggu floating > 0 untuk TP basket" : "")));
            s_maxLogged = true;
         }
         return;
      }
      s_maxLogged = false;
   }

   int topLayer = GetHighestLayer();
   if(topLayer <= 0) return;

   //--- satu layer per kejadian: tunggu market order sebelumnya terbaca
   if(g_marketLayerNo > 0)
   {
      if(topLayer >= g_marketLayerNo)
      {
         g_marketLayerNo = 0; g_marketLayerTime = 0;       // sudah terbaca -> lanjut evaluasi
      }
      else if(TimeCurrent() - g_marketLayerTime < 5)
         return;                                           // masih menunggu
      else
      {
         g_marketLayerNo = 0; g_marketLayerTime = 0;       // lewat batas tunggu -> lepas
      }
   }

   //--- yang diukur: floating layer TERTINGGI saja (bukan total basket)
   double layerProfit = 0.0;
   if(!TopLayerFloating(topLayer, layerProfit)) return;

   double threshold = MathAbs(InpLayerTriggerUSD);  // ambang pada lot awal; tanda input diabaikan
   double lotRatio  = LayerLotRatio(topLayer);      // lot layer terakhir / InpLot (min 1)
   double thrLoss   = threshold * lotRatio;         // ambang RUGI: diskalakan mengikuti lot layer terakhir
   //--- RECOVERY SAJA: re-entry HANYA saat layer terakhir RUGI (minus)
   if(layerProfit > -thrLoss) return;

   //--- arah: SELALU arah INIT siklus berjalan (dipulihkan dari posisi bila EA baru di-attach)
   if(g_initSide == 0)
   {
      g_initSide = InitSideFromPositions();
      if(g_initSide != 0) g_lastInitSide = g_initSide;
   }
   if(g_initSide == 0) return;
   bool goBuy = (g_initSide > 0);

   int newLayer = GetHighestLayerAny() + 1;   // hindari bentrok dgn pending lama yg masih ada di broker
   Log(StringFormat("[LAYER-RECOVERY] Floating layer #%d $%.2f (rugi, ambang -$%.2f [x%.2f lot]) -> market %s layer #%d (arah: %s | lot %s)",
                    topLayer, layerProfit, thrLoss, lotRatio,
                    (goBuy ? "BUY" : "SELL"), newLayer, "init",
                    (InpLotUpstairOn ? "upstair" : "fix")));

   if(OpenMarketLayer(newLayer, goBuy))
   {
      g_marketLayerNo   = newLayer;
      g_marketLayerTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| HEDGE CUT-LOSS                                                     |
//| Jika TOTAL LOT Buy = TOTAL LOT Sell (kedua sisi punya posisi) dan  |
//| kondisi ini bertahan terus-menerus >= InpHedgeCLMinutes, basket    |
//| ditutup paksa (CL) lewat eksekutor async. Timer reset begitu       |
//| total lot Buy != Sell sebelum durasi tercapai.                     |
//| Perbandingan lot dilakukan dalam satuan SYMBOL_VOLUME_STEP broker  |
//| (bilangan bulat), tanpa toleransi di bawah 1 step.                 |
//+------------------------------------------------------------------+
bool CheckHedgeCL(const double basketProfit)
{
   if(!InpEnableHedgeCL) return false;
   if(!g_hedgeOn) { g_hedgeSince = 0; return false; }   // saklar panel OFF -> timer dilepas
   int buyCount = 0, sellCount = 0;
   double buyVol = 0.0, sellVol = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(!IsMinePos()) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { buyCount++; buyVol += v; }
      else                                                       { sellCount++; sellVol += v; }
   }

   //--- bandingkan total lot dalam satuan volume step broker (bilangan bulat),
   //    sehingga hanya lot yang diizinkan broker yang berlaku (tanpa toleransi
   //    desimal buatan seperti 0.005)
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) vstep = 0.01;
   long buySteps  = (long)MathRound(buyVol  / vstep);
   long sellSteps = (long)MathRound(sellVol / vstep);

   bool balanced = (buyCount > 0 && sellCount > 0 && buySteps == sellSteps);

   if(!balanced)
   {
      if(g_hedgeSince != 0) g_hedgeSince = 0;   // tidak seimbang lagi -> reset timer
      return false;
   }

   if(g_hedgeSince == 0)
   {
      g_hedgeSince = TimeCurrent();
      Log(StringFormat("[HEDGE-DETECT] Lot Buy=%.2f Sell=%.2f seimbang -> timer CL mulai (%d menit)", buyVol, sellVol, InpHedgeCLMinutes));
      return false;
   }

   int elapsedSec = (int)(TimeCurrent() - g_hedgeSince);
   int targetSec  = InpHedgeCLMinutes * 60;
   if(targetSec < 0) targetSec = 0;

   if(elapsedSec >= targetSec)
   {
      Log(StringFormat("[HEDGE-CL] Lot Buy=%.2f Sell=%.2f seimbang selama %d menit -> Cut Loss basket | floating=$%.2f",
                       buyVol, sellVol, InpHedgeCLMinutes, basketProfit));
      ExecStart("CL_HEDGE", basketProfit);
      ExecProcess();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| MESIN UTAMA (dipanggil dari OnTick & OnTimer)                     |
//+------------------------------------------------------------------+
void EngineStep()
{
   WorstTrack();   // jejak terburuk: dicatat tiap tick/timer, tanpa syarat, paling awal

   if(g_execActive) { ExecProcess(); if(InpShowUI) UIRenderAll(); return; }

   if(g_pauseUntil > 0 && TimeCurrent() >= g_pauseUntil) g_pauseUntil = 0;

   //--- DAILY MAX PROFIT dievaluasi PALING AWAL (dapat mengunci entry &
   //    memicu penutupan seluruh posisi lewat eksekutor yang sama).
   DailyLimitCheck();
   if(g_execActive) { ExecProcess(); if(InpShowUI) UIRenderAll(); return; }

   double basketProfit = 0.0;
   int positions = CountOpenPositions(basketProfit);

   //--- SWEEP: TP broker terisi sebagian (sebagian tiket tertutup serentak,
   //    sisanya tertinggal) -> tutup sisanya lewat eksekutor
   if(positions > 0 && g_hadPositions && g_prevOpenPositions > positions && RecentBrokerTPClose(10))
   {
      Log(StringFormat("[TP-SWEEP] TP broker terisi sebagian (%d -> %d posisi). Menyapu sisa...", g_prevOpenPositions, positions));
      g_prevOpenPositions = positions;
      ExecStart("TP_SWEEP", basketProfit);
      ExecProcess();
      if(InpShowUI) UIRenderAll();
      return;
   }
   g_prevOpenPositions = positions;

   //--- Basket habis lewat jalur apa pun (TP broker penuh / close manual)
   if(positions == 0 && g_hadPositions)
   {
      double realized = RealizedSince(g_cycleStart);
      Log("[RESET] Semua posisi tertutup -> siklus exit direset");
      TPHistoryPush(realized, "TP_BROKER");
      ResetAfterClear();
      int p = InpPauseAfterTPSec; if(p < 0) p = 0;
      g_pauseUntil = TimeCurrent() + (datetime)p;
      if(InpShowUI) UIRenderAll();
      return;
   }

   if(positions > 0)
   {
      g_hadPositions = true;
      if(g_cycleStart == 0) g_cycleStart = TimeCurrent() - 5;

      if(g_lastLoggedPositions != positions)
      {
         Log(StringFormat("[POSITION-ACTIVE] Posisi terbuka: %d | Layer tertinggi: #%d", positions, GetHighestLayer()));
         g_lastLoggedPositions = positions;
      }

      //--- Unified Real TP: broker yang menutup semua serentak
      if(InpUseRealTP)
      {
         ApplyUnifiedTP(InpTPBasketUSD, basketProfit, false);
         bool do_modify = (g_unifiedLastMod == 0) || ((TimeCurrent() - g_unifiedLastMod) >= 1);
         if(do_modify)
         {
            if(ApplyUnifiedTP(InpTPBasketUSD, basketProfit, true))
               Log(StringFormat("[UNIFIED-TP] Harga exit basket dipasang | Bid %s / Ask %s | target $%.2f",
                                DoubleToString(g_unifiedBid, _Digits), DoubleToString(g_unifiedAsk, _Digits), InpTPBasketUSD));
            g_unifiedLastMod = TimeCurrent();
         }
      }

      if(MathAbs(basketProfit - g_lastLoggedProfit) >= 0.10)
      {
         Log(StringFormat("[BASKET-PROGRESS] Floating $%.2f / Target $%.2f | Posisi %d", basketProfit, InpTPBasketUSD, positions));
         g_lastLoggedProfit = basketProfit;
      }

      //--- Jaring pengaman: target tercapai tapi TP broker belum tereksekusi
      //    (mode virtual, requote, atau stops level) -> eksekutor async
      if(basketProfit >= InpTPBasketUSD)
      {
         ExecStart("TP_BASKET", basketProfit);
         ExecProcess();
         if(InpShowUI) UIRenderAll();
         return;
      }

      //--- BATAS POSISI tercapai + opsi aktif: tutup SELURUH basket begitu total
      //    floating > 0 (TP basket lebih awal) lewat eksekutor yang sama
      if(InpMaxPositions > 0 && InpMaxPosTP && positions >= InpMaxPositions && basketProfit > 0.0)
      {
         Log(StringFormat("[MAXPOS-TP] Posisi %d >= batas %d | floating $%.2f > 0 -> tutup semua posisi & pending",
                          positions, InpMaxPositions, basketProfit));
         ExecStart("TP_MAXPOS", basketProfit);
         ExecProcess();
         if(InpShowUI) UIRenderAll();
         return;
      }

      //--- Cut Loss otomatis bila basket hedging (Buy=Sell) bertahan lama
      if(CheckHedgeCL(basketProfit)) { if(InpShowUI) UIRenderAll(); return; }

      CheckLayerTrigger();
      if(InpShowUI) UIRenderAll();
      return;
   }

   //--- Flat (0 posisi): INIT market order, arah dari DAILY CHANGE %
   //    dihitung SEGAR tiap init (termasuk setelah TP/CL)
   if(InpShowUI) UIRenderAll();
   if(IsPauseActive()) return;
   if(DailyLockActive()) return;                       // batas profit harian tercapai -> entry dikunci
   InitEntry();
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   EventSetMillisecondTimer(200);   // exit tetap jalan walau tick jarang

   g_eaStartTime = TimeCurrent();

   //--- saklar RUNTIME mengikuti input saat start
   g_spreadOn = (InpMaxSpreadPoints > 0);
   g_hedgeOn  = InpEnableHedgeCL;

   //--- DAILY MAX PROFIT
   g_dailyOn      = InpDailyEnable;
   g_dailyLocked  = false;
   g_dailyVerify  = false;
   g_dailyDay     = DailyServerDayStart();
   g_dailyNetCache= 0.0;

   //--- UI
   g_uiScale  = (double)InpUIScalePercent / 100.0;
   if(g_uiScale <= 0.0) g_uiScale = 1.0;
   g_uiPrefix = StringFormat("BRKT_%I64d_", InpMagic);
   g_pnlCollapsed = false;
   g_tphCollapsed = false;
   g_tphCount     = 0;
   g_tpHitCount   = 0;
   UIDeleteAll();

   //--- Sisa pending order dari versi lama (init berbasis breakout) dibuang:
   //    init sekarang market order dengan arah dari daily change %
   DeleteLegacyPendings();

   //--- Recovery siklus berjalan: ada posisi saat EA di-attach
   if(CountOpenPositions() > 0)
   {
      g_hadPositions = true;
      g_cycleStart   = TimeCurrent() - 5;
      g_initSide     = InitSideFromPositions();   // arah init dipulihkan dari posisi yang berjalan
      if(g_initSide != 0) g_lastInitSide = g_initSide;
   }

   Log(StringFormat("[INIT] EA v%s | %s | Magic %I64d | Lot %.2f (%s step %.2f / %d layer) | Init DailyChange %.2f%% (D1) | TP Basket $%.2f | Recovery Layer -%.2f | RealTP %s | HedgeCL %s (%d menit) | Daily %s (%.2f)",
                    EA_VERSION, _Symbol, InpMagic, InpLot,
                    (InpLotUpstairOn ? "UPSTAIR" : "FIX"), InpLotUpstairStep, InpLotStepLayer,
                    MathAbs(InpInitDailyPct),
                    InpTPBasketUSD, MathAbs(InpLayerTriggerUSD),
                    (InpUseRealTP ? "ON" : "OFF"),
                    (InpEnableHedgeCL ? "ON" : "OFF"), InpHedgeCLMinutes,
                    (InpDailyEnable ? "ON" : "OFF"), DailyLimitValue()));

   if(InpShowUI) UIRenderAll(true);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   TPLineDelete();
   UIDeleteAll();
   ChartRedraw(0);
   Log(StringFormat("[DEINIT] Reason code: %d", reason));
}

void OnTick()  { EngineStep(); }
void OnTimer() { EngineStep(); }

//+------------------------------------------------------------------+
//| KLIK PANEL                                                        |
//| Seluruh saklar di panel hanya override RUNTIME; nilai input tidak |
//| pernah diubah. Objek yang tidak punya fungsi di EA ini memang     |
//| tidak digambar, jadi tidak ada penanganan klik yang menganggur.   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(!InpShowUI) return;

   //--- lipat / buka panel utama
   if(sparam == UIName("pnl_btn"))
   {
      g_pnlCollapsed = !g_pnlCollapsed;
      UIRenderAll(true);
      return;
   }

   //--- lipat / buka TP/SL HISTORY
   if(sparam == UIName("tph_btn"))
   {
      g_tphCollapsed = !g_tphCollapsed;
      UIRenderAll(true);
      return;
   }

   //--- saklar FILTER SPREAD
   if(sparam == UIName("spd_btn") || sparam == UIName("spd_txt"))
   {
      if(InpMaxSpreadPoints <= 0) return;   // filter memang tidak dipakai
      g_spreadOn = !g_spreadOn;
      Log(StringFormat("[PANEL] FILTER SPREAD -> %s (batas %d point)", (g_spreadOn ? "ON" : "OFF"), InpMaxSpreadPoints));
      UIRenderAll(true);
      return;
   }

   //--- saklar HEDGE CUT-LOSS
   if(sparam == UIName("hdg_btn") || sparam == UIName("hdg_txt"))
   {
      if(!InpEnableHedgeCL) return;         // fitur dimatikan dari input
      g_hedgeOn = !g_hedgeOn;
      if(!g_hedgeOn) g_hedgeSince = 0;      // OFF -> timer dilepas
      Log(StringFormat("[PANEL] HEDGE CL -> %s (%d menit)", (g_hedgeOn ? "ON" : "OFF"), InpHedgeCLMinutes));
      UIRenderAll(true);
      return;
   }

   //--- saklar DAILY MAX PROFIT
   if(sparam == UIName("dlim_btn") || sparam == UIName("dlim_txt"))
   {
      g_dailyOn = !g_dailyOn;
      if(!g_dailyOn) { g_dailyLocked = false; g_dailyVerify = false; }
      Log(StringFormat("[PANEL] DAILY LIMIT -> %s (batas %.2f)", (g_dailyOn ? "ON" : "OFF"), DailyLimitValue()));
      UIRenderAll(true);
      return;
   }

   //--- CLOSE ALL manual
   if(sparam == UIName("ca_btn") || sparam == UIName("ca_txt"))
   {
      if(g_execActive) return;
      if((CountOpenPositions() + CountPendingOrders()) <= 0) return;
      Log("[PANEL] CLOSE ALL ditekan -> tutup seluruh posisi & pending");
      ManualCloseAllRetry();
      if(CountOpenPositions() == 0 && CountPendingOrders() == 0)
      {
         double realized = RealizedSince(g_cycleStart);
         ResetAfterClear();
         TPHistoryPush(realized, "MANUAL_CLOSEALL");
         int p = InpPauseAfterTPSec; if(p < 0) p = 0;
         g_pauseUntil = TimeCurrent() + (datetime)p;
      }
      else
      {
         double fl = 0.0; CountOpenPositions(fl);
         ExecStart("MANUAL_CLOSEALL", fl);
         ExecProcess();
      }
      UIRenderAll(true);
      return;
   }
}

//--- Setiap deal masuk/keluar: hitung ulang harga unified TP
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   string sym = trans.symbol; if(sym == "") sym = _Symbol;
   if(sym != _Symbol) return;
   g_unifiedLastMod = 0;        // paksa refresh unified TP pada langkah berikutnya

   if(g_execActive) ExecProcess();
}
//+------------------------------------------------------------------+

//======================================================================
// CHANGELOG
//======================================================================
// v1.00 - Breakout Buy Stop & Sell Stop, basket TP
// v1.01 - Logging detail
// v2.00 - Sistem layering: re-entry saat layer sebelumnya floating -$1,
//         flag layer #1/#2/#3 di komentar, tanpa batas layer
//
// v2.10 - EXIT DIROMBAK (mengadopsi mekanika modul CARA_EXIT):
//  1. UNIFIED REAL TP — satu harga exit dihitung dari NET volume seluruh
//     layer, lalu dipasang sebagai TP/SL riil di SETIAP tiket. Broker yang
//     menutup semua layer serentak pada harga itu, tanpa menunggu tick EA.
//     Harga dihitung ulang tiap detik dan tiap kali ada deal baru
//     (OnTradeTransaction), menghormati stops level & spread.
//  2. EKSEKUTOR ASYNC — jaring pengaman bila TP riil gagal/di-requote:
//     state machine INIT -> SEND -> VERIFY -> FORCE -> DONE. Snapshot tiket
//     diambil lebih dulu, lalu SEMUA perintah close dikirim dalam satu loop
//     dengan trade.SetAsyncMode(true) sehingga tidak menunggu balasan
//     server per tiket (inilah sumber "kurang serentak" di v2.00).
//  3. VERIFIKASI & RETRY — setelah kirim, EA menghitung sisa posisi/pending.
//     Belum bersih -> snapshot ulang & kirim lagi; melewati batas retry ->
//     mode FORCE tanpa jeda. Tidak pernah dianggap selesai sebelum
//     posisi=0 dan pending=0 (anti basket pincang).
//  4. TP-SWEEP — bila TP broker hanya terisi sebagian (sisa tiket
//     tertinggal), sisanya langsung disapu lewat eksekutor.
//  5. EventSetMillisecondTimer(200) — exit tetap diproses saat tick jarang.
//  6. Async HANYA dipakai di jalur exit; entry tetap sinkron agar ticket
//     dan retcode entry tetap terbaca.
//
// v2.20 - KOREKSI RE-ENTRY LAYER (bukan market instan):
//  1. Re-entry layer kini memasang PENDING PAIR (Buy Stop & Sell Stop),
//     sama seperti entry awal — bukan market order langsung. Fungsi
//     OpenLayer() dihapus, diganti PlacePendingPair(layerNo) yang dipakai
//     bersama oleh entry #1 dan re-entry layer berikutnya.
//  2. Layer baru terbentuk hanya ketika salah satu pending pair itu
//     tersentuh harga pasar; arah layer ditentukan sisi mana yang aktif,
//     bukan mengikuti arah layer sebelumnya.
//  3. LATCH g_pendingLayerNo: selama pending pair layer berikutnya masih
//     menggantung, trigger floating -$1 berikutnya ditahan (tidak dobel
//     pasang tiap tick). Latch lepas otomatis saat layer itu aktif.
//  4. Pembersihan pending diubah dari "hapus semua" menjadi PER-LAYER:
//     begitu satu layer aktif, hanya pending pasangannya (nomor layer
//     sama) yang dihapus — pending layer lain yang belum aktif tidak
//     tersentuh.
//  5. Saat basket TP tuntas (ResetAfterClear), latch pending layer ikut
//     direset ke 0 untuk siklus baru dari layer #1.
//
// v2.30 - FIX INVALID PRICE + TRIGGER PER SIDE:
//  1. FIX "invalid price" pada BuyStop/SellStop: harga kini dibulatkan ke
//     kelipatan SYMBOL_TRADE_TICK_SIZE lewat NormalizePriceToTick()
//     (sebelumnya hanya NormalizeDouble by digits) — symbol synthetic/
//     index (tick_size != point) menolak harga yang tidak presisi tick.
//  2. minDist entry kini juga dijaga minimal 1 tick_size, tidak cuma
//     dari STOPS_LEVEL/FREEZE_LEVEL poin (bisa 0 di sejumlah symbol).
//  3. CheckLayerTrigger() diubah dari floating GABUNGAN layer tertinggi
//     menjadi floating TERPISAH PER SIDE (Buy sendiri, Sell sendiri).
//     Re-entry layer berikutnya terpicu begitu SALAH SATU side floating
//     <= -InpLayerTriggerUSD, mengikuti layer sebelumnya per side.
//
// v2.40 - ANTI PENDING YATIM:
//  1. CheckOrphanPending() dipanggil tiap EngineStep (kecuali saat pause):
//     mendeteksi layer yang pending-nya cuma 1 (seharusnya pair 2, salah
//     satu leg gagal krn invalid price/ditolak broker) -> pending sisa
//     dihapus, pair lengkap dipasang ulang lewat PlacePendingPair(lay).
//  2. Rebuild langsung tanpa jeda/retry limit (sesuai kesepakatan).
//  3. Tetap pending stop (Buy Stop & Sell Stop) — konsep breakout tidak
//     diubah menjadi limit order.
//
// v2.50 - TRIGGER RE-ENTRY: TOTAL BASKET (bukan per-side):
//  1. CheckLayerTrigger() diubah dari floating TERPISAH PER SIDE (v2.30)
//     menjadi floating TOTAL SELURUH BASKET (semua posisi, semua layer
//     digabung jadi satu P/L). Re-entry layer berikutnya terpicu begitu
//     total floating basket <= -InpLayerTriggerUSD.
//  2. Default InpLayerTriggerUSD diubah dari 1.0 menjadi 2.0 (deskripsi
//     parameter tidak diubah; input tetap ditulis positif, tanpa tanda
//     minus, dikonversi via MathAbs()).
//
// v2.60 - TRIGGER RE-ENTRY: KELIPATAN PER LAYER (bukan tetap):
//  1. CheckLayerTrigger() diubah: threshold trigger kini
//     = topLayer x InpLayerTriggerUSD (bukan tetap -InpLayerTriggerUSD).
//     Layer #1 aktif -> trigger di -$2 (1x). Layer #2 aktif -> trigger di
//     -$4 (2x). Layer #3 aktif -> trigger di -$6 (3x). Dst, mengikuti
//     jumlah layer aktif tertinggi.
//  2. Cara kerja re-entry (pending pair Buy Stop & Sell Stop) tidak
//     berubah, hanya rumus threshold-nya.
//
// v2.70 - HEDGE CUT-LOSS:
//  1. Parameter baru: InpEnableHedgeCL (default true) & InpHedgeCLMinutes
//     (default 10).
//  2. CheckHedgeCL() ditambahkan: mendeteksi jumlah posisi Buy = jumlah
//     posisi Sell (sama-sama > 0). Timer mulai berjalan sejak kondisi ini
//     terdeteksi; reset ke 0 jika jumlah Buy != Sell sebelum durasi
//     tercapai.
//  3. Jika kondisi seimbang bertahan terus-menerus >= InpHedgeCLMinutes,
//     basket ditutup paksa (Cut Loss) lewat eksekutor async yang sama
//     dengan basket TP (SEND -> VERIFY -> FORCE -> DONE), floating apa
//     adanya.
//  4. Setelah CL, siklus baru dimulai dari layer #1 lewat ResetAfterClear
//     + InpPauseAfterTPSec, sama seperti basket TP normal. State
//     g_hedgeSince ikut direset di ResetAfterClear().
//  5. Pengecekan hedge CL dijalankan tiap EngineStep, setelah cek TP
//     basket dan sebelum CheckLayerTrigger (re-entry layer baru tidak
//     dipasang jika basket sedang dalam proses CL).
//
// v2.71 - FIX BUG: KOMENTAR LAYER GANDA (double #N):
//  1. Akar masalah: setelah EA restart/reattach/compile ulang, variabel
//     latch g_pendingLayerNo ke-reset ke 0 walau pending pair (Buy Stop
//     & Sell Stop) suatu layer masih LENGKAP menggantung di broker.
//     CheckLayerTrigger() lama menghitung nomor layer baru hanya dari
//     GetHighestLayer() (posisi AKTIF saja), sehingga saat threshold
//     floating tersentuh lagi, EA menembak PlacePendingPair() dengan
//     nomor yang SAMA dengan pending lama -> dua pasang pending/posisi
//     berbeda dengan komentar "#N" identik.
//  2. FIX 1 — GetHighestLayerAny(): nomor layer tertinggi kini dihitung
//     dari POSISI AKTIF + PENDING ORDER (bukan posisi saja). Nomor layer
//     baru = GetHighestLayerAny() + 1, sehingga tidak mungkin lagi
//     bentrok dengan pending yang sudah ada di broker. Rumus threshold
//     trigger (topLayer aktif x InpLayerTriggerUSD) TIDAK berubah,
//     konsep re-entry (pending pair Buy Stop/Sell Stop) TIDAK berubah.
//  3. FIX 2 — Recovery latch di OnInit(): saat EA start/restart, EA
//     memindai pending order yang masih ada di broker; jika ditemukan
//     layer > 1, g_pendingLayerNo dipulihkan ke nomor tsb sehingga
//     CheckLayerTrigger() tidak langsung menembak pending baru sebelum
//     pending lama tuntas (aktif jadi posisi atau dibersihkan).
//
// v2.72 - FIX BUG: KOMENTAR LAYER GANDA (jalur CheckOrphanPending):
//  1. Akar masalah (berbeda dari v2.71, celah yang belum tersentuh):
//     CheckOrphanPending() lama memvonis "yatim" HANYA dari jumlah
//     pending per layer (tersisa 1), tanpa memeriksa apakah layer itu
//     sudah punya POSISI AKTIF. Saat salah satu leg pair tersentuh harga
//     dan menjadi posisi, pending-nya hilang dari daftar order sehingga
//     layer itu tampak menyisakan 1 pending. Karena CheckOrphanPending()
//     dipanggil di AWAL EngineStep (sebelum cleanup pending per-layer),
//     sisa pending tsb dikira yatim -> dihapus lalu PlacePendingPair(lay)
//     dipanggil ulang dengan nomor layer yang SAMA -> muncul pasangan
//     Buy/Sell berkomentar "#N" kembar dengan posisi yang sudah aktif.
//  2. FIX — LayerHasPosition(lay): helper baru untuk cek apakah suatu
//     nomor layer sudah punya posisi aktif. CheckOrphanPending() kini
//     melewati (skip) layer yang sisa pending-nya 1 TAPI sudah punya
//     posisi aktif; sisa pending itu dibiarkan dibersihkan oleh logika
//     cleanup pending per-layer yang sudah ada (log [ORPHAN-SKIP]).
//  3. Yatim ASLI (pending tersisa 1 dan layer belum punya posisi sama
//     sekali, mis. leg ditolak broker/invalid price) tetap ditangani
//     seperti semula: sisa dihapus lalu pair lengkap dipasang ulang.
//  4. Konsep re-entry (pending pair Buy Stop/Sell Stop) dan rumus
//     threshold trigger (topLayer aktif x InpLayerTriggerUSD) TIDAK
//     berubah.
//
// v2.80 - FIX RE-ENTRY MACET (double #N) + ADOPSI UPSTAIR, DAILY LIMIT, UI:
//
//  A. FIX BUG UTAMA — RE-ENTRY BERHENTI TOTAL SETELAH DOUBLE-FILL
//     GEJALA (screenshot layer #8): sembilan posisi dengan komentar
//     #1..#7 unik lalu #8 MUNCUL DUA KALI (buy 94349 & sell 94319),
//     dan sesudah itu tidak ada lagi layer baru meski total floating
//     -87.61 sudah jauh melewati ambang 8 x $2 = $16.
//
//     AKAR MASALAH 1 — DOUBLE-FILL. Pending pair layer #8 (Buy Stop di
//     atas, Sell Stop di bawah) sama-sama tersentuh: harga menembus ke
//     atas lalu berbalik menembus ke bawah sebelum EA sempat mencabut
//     leg lawan. Dua leg satu layer menjadi dua POSISI berkomentar
//     "#8" — bukan pemasangan ulang seperti dugaan awal.
//
//     AKAR MASALAH 2 — LATCH TERKUNCI SELAMANYA (ini penyebab MACET).
//     Pelepasan latch g_pendingLayerNo dulu dikerjakan DI DALAM blok
//     "if(CountPendingOrders() > 0)" pada EngineStep(). Saat double-fill
//     terjadi, pending layer #8 habis (kedua-duanya jadi posisi); bila
//     tidak ada pending layer lain, blok itu tidak pernah dieksekusi
//     sehingga g_pendingLayerNo tetap bernilai 8. CheckLayerTrigger()
//     selalu keluar di baris pertama -> re-entry mati permanen.
//
//     PERBAIKAN:
//      1. ReleasePendingLatch() — pelepas latch BERDIRI SENDIRI,
//         dipanggil tiap EngineStep dan tiap OnTradeTransaction, tidak
//         lagi bergantung pada ada/tidaknya pending. Latch dilepas bila
//         (a) layer itu sudah punya posisi aktif, ATAU (b) layer itu
//         tidak menyisakan pending sama sekali.
//      2. CleanupPendingOfActiveLayers() — pembersihan pending per-layer
//         dipisah dari EngineStep menjadi fungsi mandiri, lalu ikut
//         dipanggil dari OnTradeTransaction. Begitu satu leg tereksekusi,
//         leg lawan dicabut pada detik yang sama (OCO manual) — jendela
//         double-fill dipersempit semaksimal mungkin dari sisi EA.
//      3. CheckLayerDoubleFill() — bila double-fill tetap lolos (gap/
//         lonjakan satu tick), EA MENCATAT saja lewat log
//         [LAYER-DOUBLEFILL]. Tidak ada posisi yang ditutup paksa agar
//         basket tidak dirusak; penomoran layer berikutnya tetap aman
//         karena memakai GetHighestLayerAny() + 1, dan re-entry tetap
//         berjalan karena latch sudah dilepas.
//      4. PlacePendingPair() diberi penjaga: menolak memasang pending
//         bila nomor layer itu SUDAH punya posisi aktif (anti duplikat
//         komentar dari jalur pemanggil mana pun).
//      5. CountPositionsByLayer() & CountPendingByLayer() — penghitung
//         per nomor layer yang dipakai ketiga fungsi di atas.
//
//  B. TANGGA LOT (UPSTAIR) — diadopsi dari modul HEDGING
//      1. Parameter baru: InpLotUpstairOn (saklar true/false),
//         InpLotUpstairStep (default 0.01), InpLotStepLayer (default 3).
//      2. LotForLayer(N) = InpLot + InpLotUpstairStep * floor((N-1)/L),
//         L = InpLotStepLayer, N = nomor LAYER (padanan "pasangan" pada
//         HEDGING). Contoh L=3 step 0.01: #1..#3 = 0.01 | #4..#6 = 0.02
//         | #7..#9 = 0.03, dst. Hasil dilewatkan NormalizeLot() (batas
//         & step volume broker).
//      3. InpLotUpstairOn = false -> lot FIX InpLot untuk semua layer,
//         yaitu perilaku v2.72 apa adanya (tidak ada perubahan perilaku
//         bagi pengguna lama).
//      4. Kedua leg pending pair satu layer selalu memakai lot yang sama.
//
//  C. DAILY MAX PROFIT — diadopsi dari modul HEDGING
//      1. Parameter baru: InpDailyEnable (default false),
//         InpDailyMaxProfit (default 1000.0; nilai <= 0 dianggap 1000).
//      2. Batas hari = 00:00 WAKTU SERVER. Net = realized hari ini
//         (deal OUT symbol + magic ini) + floating berjalan.
//      3. Net >= batas -> kunci dipasang lebih dulu, lalu SELURUH posisi
//         & pending ditutup lewat eksekutor async yang sama dengan
//         basket TP (reason DAILY_MAXPROFIT).
//      4. Verifikasi ulang pasca-flat: setelah posisi 0 dan eksekutor
//         selesai, net dibaca ulang. < batas -> kunci DILEPAS dan entry
//         dilanjutkan; >= batas -> kunci dipertahankan sampai ganti hari
//         server atau saklar panel dimatikan.
//      5. Saat terkunci: PlacePendingPair(), CheckLayerTrigger(), dan
//         entry layer #1 pada kondisi flat semuanya ditahan.
//
//  D. UI — PANEL + TP/SL HISTORY + GARIS TP
//      1. Parameter baru: InpShowUI (input), InpUIScalePercent,
//         InpMaxRetries, InpRetrySleepMs (ketiganya const, sesuai modul
//         HEDGING).
//      2. Helper UI identik: UIS/UIFont/UIName/UIEnsureRect/
//         UIEnsureLabel/UIDeleteAll/UITextW + PnlLbl/PnlToggle/
//         PnlActionBtn/PnlBtnW/PnlDel, palet warna dan font Consolas
//         sama.
//      3. Isi panel HANYA memuat fungsi yang benar-benar ada di EA ini
//         (tidak ada baris menganggur): STATUS, symbol & magic, LIVE
//         (Posisi/Lot/P.L per BUY-SELL-TOTAL), LAYER (aktif, pending,
//         lot next beserta nomor layer & mode lot), EXIT (TP Basket +
//         progress bar, Real TP, harga TP), ENTRY/GUARD (Trigger layer
//         berikutnya, Spread, Hedge CL), AKUN (Balance, Equity, Daily
//         Lock), WAKTU (tanggal & jam WIB, runtime), tombol CLOSE ALL.
//      4. Saklar panel yang bisa diklik: Spread, Hedge CL, Daily Lock.
//         Semuanya override RUNTIME saja — nilai input tidak pernah
//         diubah. Panel utama & TP/SL HISTORY dapat dilipat [-]/[+].
//      5. TP/SL HISTORY (panel kanan): 20 baris terakhir, nilai REALIZED
//         per siklus, label TP BASKET / SISA TP / CL HEDGE / DAILY /
//         MANUAL / TP BROKER, plus baris TOTAL.
//      6. Garis TP di chart digambar hanya saat Real TP OFF (mode
//         virtual). Saat Real TP ON, garis sudah digambar terminal dari
//         field TP tiket sehingga tidak ditumpuk.
//      7. Jam panel memakai WIB MURNI (GMT+7) tanpa penyesuaian apa pun.
//      8. Tombol CLOSE ALL memakai InpMaxRetries & InpRetrySleepMs:
//         penutupan sinkron berulang; bila masih ada sisa, diserahkan ke
//         eksekutor async (reason MANUAL_CLOSEALL).
//      9. Render dibatasi ~4x/detik supaya pengukuran teks tidak
//         membebani tiap tick.
//
//  E. LAIN-LAIN
//      1. ComputeBasketTPPrice() — perhitungan harga exit basket dipecah
//         dari ApplyUnifiedTP() supaya bisa dipakai garis TP & panel
//         tanpa menyentuh tiket. Rumus identik, perilaku ApplyUnifiedTP
//         tidak berubah.
//      2. SpreadOK() kini menghormati saklar panel; CheckHedgeCL() juga.
//         Bila input aslinya nonaktif, saklar tampil redup & tidak
//         berfungsi.
//      3. ResetAfterClear() ikut mereset g_cycleStart, g_lastDoubleFillLog
//         dan menghapus garis TP.
//      4. OnInit() memulihkan siklus berjalan bila EA di-attach saat
//         sudah ada posisi. OnDeinit() membersihkan seluruh objek UI.
//      5. Input dikelompokkan dengan input group (SETTINGS, ENTRY,
//         LAYER, EXIT, DAILY LIMIT, UI). Tidak ada parameter lama yang
//         dihapus atau berubah arti.
//
// v2.90 - JARAK ENTRY, WORST TRACKER, TATA LETAK PANEL DIRAPIKAN:
//
//  A. PARAMETER JARAK ENTRY (Buy Stop <-> Sell Stop)
//      1. Input baru: InpEntryGapPoints (default 0, satuan poin).
//      2. EffEntryGapPoints() = MAX(minimum broker (STOPS_LEVEL /
//         FREEZE_LEVEL), InpEntryGapPoints). Nilai default 0 membuat
//         hasilnya SELALU sama dengan minimum broker apa adanya —
//         perilaku entry v2.80 ke bawah tidak berubah sama sekali.
//      3. Diisi > 0 untuk melebarkan jarak Buy Stop/Sell Stop dari
//         harga saat ini melebihi minimum broker (mis. menghindari
//         breakout palsu pada spread/noise kecil).
//      4. Dipakai PlacePendingPair() menggantikan perhitungan minDistPt
//         inline yang lama (logika sama, dipindah ke fungsi mandiri).
//      5. Panel menampilkan jarak yang SEDANG berlaku saat ini (poin
//         & harga) pada baris baru "Jarak Entry" di section
//         ENTRY / GUARD.
//
//  B. WORST TRACKER (HISTORY TERBURUK) — diadopsi dari modul HEDGING
//      1. State baru g_worstPos[3]/g_worstLot[3]/g_worstPl[3]
//         ([0]=BUY [1]=SELL [2]=TOTAL): jejak rekor posisi terbanyak,
//         lot terbesar, dan floating paling minus yang PERNAH terjadi
//         sejak EA dipasang ke chart.
//      2. WorstTrack() dipanggil di baris PALING AWAL EngineStep(),
//         tanpa syarat apa pun (sama seperti LIVE, tidak menunggu
//         posisi>0) — meniru pola asli modul HEDGING.
//      3. TIDAK PERNAH direset oleh TP, CL, Daily Limit, atau basket
//         clear manapun (ResetAfterClear() tidak menyentuhnya). Murni
//         pencatatan; tidak dibaca oleh logika entry/exit mana pun.
//         Hanya nol lagi bila EA dilepas & dipasang ulang ke chart.
//      4. Panel: section baru "HISTORY TERBURUK" ditambahkan tepat di
//         bawah LIVE, memakai grid kolom BUY/SELL/TOTAL yang sama.
//         Baris LIVE kini diwarnai gradasi (PosColor/LotColor/
//         PLColorGrad) mengikuti seberapa dekat nilai sekarang dengan
//         rekor WORST-nya; baris WORST sendiri memakai warna keluarga
//         magenta/pink/oranye supaya sekilas berbeda dari LIVE.
//
//  C. TATA LETAK PANEL DIRAPIKAN
//      1. Grid LABEL (kiri) | NILAI (kanan) kini konsisten di SELURUH
//         section, bukan hanya tabel LIVE: lebar kolom label (labelw)
//         dihitung dari semua label section, dan setiap baris memakai
//         posisi x tetap yang sama untuk label (kiri) dan untuk nilai
//         (kanan) — termasuk section yang sebelumnya paling padat.
//      2. Section WAKTU dirombak dari 2 baris campuran (tanggal & jam
//         digabung satu baris) menjadi 3 baris bersih: Tanggal / Jam /
//         Runtime, masing-masing satu label + satu nilai.
//      3. Jarak lega ditambah di semua sisi: padding kartu, jarak
//         antar kolom BUY/SELL/TOTAL, tinggi baris, jarak sebelum &
//         sesudah setiap garis pemisah section, serta margin sebelum
//         tombol CLOSE ALL dan di tepi bawah kartu — panel tidak lagi
//         terkesan mepet.
//      4. Tinggi kartu (pnl_bg) kini dihitung dari akumulasi posisi Y
//         SETELAH seluruh baris selesai digambar (bukan rumus jumlah
//         baris yang ditebak di awal), sehingga selalu pas — tidak
//         pernah terpotong maupun menyisakan ruang kosong berlebih di
//         bawah, walau baris bertambah di kemudian hari.
//      5. Tinggi header bar (hh) kini satu variabel yang dipakai baik
//         mode terbuka maupun mode dilipat, supaya kedua mode terasa
//         konsisten.
//      6. Murni penataan visual — tidak ada perubahan pada logika
//         entry, exit, layer, hedge, atau daily limit.
//
// v3.00 - RE-ENTRY MARKET + TREN, TRIGGER PER LAYER, SL BASKET & RECOVERY:
//
//  A. RE-ENTRY LAYER #2 DST = MARKET INSTAN (bukan pending pair)
//      1. Layer #1 tetap Buy Stop + Sell Stop; sisi yang tidak tersentuh
//         dihapus (OCO manual) seperti sebelumnya.
//      2. Layer #2 dst dibuka sebagai SATU market order (komentar "#N")
//         lewat OpenMarketLayer(); lot = LotForLayer(N). Filter spread,
//         Daily Lock, dan penjaga anti-duplikat komentar tetap berlaku.
//      3. Satu layer per kejadian: trigger berikutnya ditahan sampai
//         market order sebelumnya terbaca sbg posisi (maks 5 detik).
//
//  B. TRIGGER = FLOATING LAYER TERAKHIR, AMBANG TETAP, DUA SISI
//      1. Yang diukur hanya floating (profit + swap) layer tertinggi,
//         bukan total basket, dan ambang TIDAK dikali nomor layer.
//      2. InpLayerTriggerUSD: layer ditambah saat |floating| >= nilai,
//         baik RUGI maupun UNTUNG; tanda +/- diabaikan; 0 = nonaktif.
//         Default berubah menjadi 1.0. PERHATIAN: arti nilai lama
//         (negatif/positif) berubah — cek preset (.set) lama.
//
//  C. ARAH RE-ENTRY MENGIKUTI TREN
//      1. Input baru: InpTrendEnable, InpTrendTF, InpTrendMAPeriod,
//         InpTrendBufferPoints (grup TREND RE-ENTRY).
//      2. GetTrendDir() membaca candle TERTUTUP: close > EMA & EMA naik =
//         BUY; close < EMA & EMA turun = SELL; selain itu / data belum
//         cukup = searah sisi layer terakhir (fallback).
//      3. Basket kini bisa dua sisi; bila total lot Buy = Sell, Hedge CL
//         dan SL basket menjadi jalan keluar.
//
//  D. HEDGE CL BERBASIS TOTAL LOT
//      1. Syarat seimbang: total lot Buy = total lot Sell (kedua sisi
//         punya posisi), dibandingkan dalam satuan SYMBOL_VOLUME_STEP
//         broker (bilangan bulat), bukan lagi jumlah posisi.
//      2. Timer, durasi, reset timer, dan eksekusi CL tidak berubah.
//
//  E. SL BASKET + RECOVERY LOT
//      1. Input baru (grup STOP LOSS & RECOVERY): InpSLEnable,
//         InpSLBasketUSD, InpRecoverMaxLevel, InpRecoverMaxLot.
//      2. Total floating basket <= -InpSLBasketUSD -> tutup semua lewat
//         eksekutor (label history "SL BASKET"). SL dijaga EA, bukan
//         SL broker. TP basket TETAP (InpTPBasketUSD).
//      3. Rugi siklus dicatat sbg hutang & level recovery +1 per SL;
//         lot dasar = InpLot + InpLotUpstairStep x level. Hasil siklus
//         berikutnya mengurangi/menambah hutang; hutang <= 0 -> level 0.
//      4. Hutang & level disimpan di GlobalVariable terminal
//         (BRKT_<magic>_<symbol>_DEBT / _LEVEL); backtest mulai bersih.
//         Pencatatan lewat RecoveryRegister() di TPHistoryPush().
//
//  F. PANEL
//      1. Baris baru: Tren, SL Basket, Hutang; baris Trigger kini
//         menampilkan floating layer terakhir vs ambang +/-.
//      2. Kolom tabel LIVE & HISTORY TERBURUK dijaga tetap rata kanan
//         saat panel melebar.
//
//  G. PENANDA VERSI
//      1. #property version, EA_VERSION (judul panel), baris [INIT] di
//         log, header file, dan nama file memuat nomor versi.
//
//  Tidak berubah: Unified Real TP, eksekutor async, TP-SWEEP, Daily Max
//  Profit, layer #1, dan jalur exit lainnya. Catatan versi lama di atas
//  yang menyebut re-entry pending pair atau trigger total basket
//  dianggap digantikan oleh entri v3.00 ini.
//
// v3.10 - LOT RE-ENTRY MENGIKUTI KONDISI PEMICU:
//
//  1. Re-entry layer #2 dst yang dipicu UNTUNG (floating layer terakhir
//     >= +InpLayerTriggerUSD) memakai LOT DASAR: InpLot + tangga recovery
//     (bila InpSLEnable), TANPA tangga per layer (UPSTAIR).
//  2. Re-entry yang dipicu RUGI (<= -InpLayerTriggerUSD) memakai lot
//     UPSTAIR seperti sebelumnya (berdasarkan nomor layer).
//  3. InpLotUpstairOn = OFF -> kedua kondisi memakai lot dasar yang sama.
//     InpRecoverMaxLot tetap membatasi keduanya. Layer #1 tidak berubah.
//  4. LotForLayer() mendapat parameter opsional baseOnly (default false,
//     sehingga semua pemanggil lama berperilaku sama); OpenMarketLayer()
//     mendapat parameter opsional baseLot.
//  5. Panel: baris "Lot next" menampilkan lot sesuai tanda floating layer
//     terakhir (untung -> "dasar", rugi -> "upstair"/"fix"). Log
//     [LAYER-TRIGGER] dan [MARKET-OK] mencatat jenis lot yang dipakai.
//  6. Tidak berubah: trigger, arah tren, Hedge CL, SL basket & recovery,
//     Unified Real TP, eksekutor, dan jalur exit.
//
// v3.11 - DEFAULT SL BASKET + RECOVERY = OFF:
//
//  1. InpSLEnable default diubah dari true menjadi false. Dengan default
//     ini SL basket, hutang, dan level recovery tidak aktif; lot kembali
//     murni mengikuti InpLot / UPSTAIR. Panel menampilkan "off" pada
//     baris SL Basket dan Hutang.
//  2. Fitur SL & recovery tidak dihapus: set InpSLEnable = true untuk
//     mengaktifkannya kembali. Tidak ada perubahan logika lain.
//
// v3.20 - AMBANG TRIGGER SISI RUGI MENGIKUTI LOT LAYER TERAKHIR:
//
//  1. InpLayerTriggerUSD kini = ambang pada lot awal (InpLot). Untuk
//     pemicu RUGI, ambang = InpLayerTriggerUSD x (total lot layer terakhir
//     / InpLot), minimal x1. Contoh nilai 1, InpLot 0.01: layer 0.01 ->
//     -$1, layer 0.02 -> -$2, layer 0.03 -> -$3. Jarak HARGA antar layer
//     jadi tetap walau lot naik (nilai $ per poin ikut naik sebanding).
//  2. Pemicu UNTUNG tetap datar: floating layer terakhir >= +nilai.
//  3. Dampak: mencegah cascade (layer baru yang sudah rugi karena spread
//     langsung memicu layer berikutnya pada lot besar).
//  4. Fungsi baru LayerLotRatio(). Panel baris Trigger menampilkan
//     "#N floating / -ambangRugi | +ambangUntung"; log [LAYER-TRIGGER]
//     mencatat ambang rugi hasil penskalaan beserta rasionya.
//  5. Tidak berubah: arah tren, aturan lot untung/rugi, Hedge CL, SL &
//     recovery, Unified Real TP, eksekutor, dan layer #1. Belum ada
//     batas jumlah layer / batas lot / jarak minimum antar layer.
//
// v3.30 - FITUR SL BASKET & RECOVERY DIHAPUS; BATAS POSISI DITAMBAHKAN:
//
//  1. DIHAPUS BERSIH: SL basket, hutang, level recovery, lot recovery,
//     penyimpanan GlobalVariable (BRKT_*_DEBT / _LEVEL), label history
//     "SL BASKET", baris panel SL Basket & Hutang, dan input
//     InpSLEnable / InpSLBasketUSD / InpRecoverMaxLevel /
//     InpRecoverMaxLot. LotForLayer() kembali memakai InpLot + tangga
//     UPSTAIR saja (parameter baseOnly dipertahankan).
//  2. BARU: InpMaxPositions (default 150, 0 = tanpa batas). Jumlah
//     posisi terbuka >= batas -> re-entry layer baru DITAHAN.
//  3. BARU: InpMaxPosTP (default true). Saat batas tercapai, SELURUH
//     basket ditutup begitu total floating > 0 (label history
//     "TP MAXPOS"), tanpa menunggu InpTPBasketUSD. false = hanya
//     menahan re-entry.
//  4. Panel: baris "Maks Posisi" (jumlah / batas, status TP; oranye
//     >= 80%, merah saat penuh). Log: [MAXPOS], [MAXPOS-TP].
//  5. Tidak berubah: trigger, ambang rugi mengikuti lot, arah tren,
//     aturan lot untung/rugi, Hedge CL, Unified Real TP, eksekutor,
//     Daily Max Profit, dan layer #1. Catatan v3.00 - v3.20 di atas yang
//     menyebut SL & recovery dianggap digantikan entri ini.
//
// v4.00 - INIT MARKET + FIBONACCI GOLDEN RATIO M5, ARAH RE-ENTRY = ARAH INIT:
//
//  1. INIT (layer #1) bukan lagi sepasang Buy Stop/Sell Stop. Setiap
//     kali jumlah posisi = 0 (awal, setelah TP, CL, atau close manual) dan
//     tidak sedang pause/Daily Lock, EA membuka SATU market order
//     ber-komentar "#1" lewat OpenMarketLayer() (filter spread & anti
//     duplikat tetap berlaku).
//  2. ARAH init dihitung SEGAR tiap init dari Fibonacci golden ratio
//     (default M5, 50 candle tertutup): swing naik -> harga >= level 0.618
//     BUY, di bawahnya SELL; swing turun -> harga <= level SELL, di
//     atasnya BUY. Fibonacci hanya menentukan ARAH; entry langsung
//     market, tidak menunggu harga menyentuh level. Cadangan bila tidak
//     jelas: arah init terakhir, lalu arah candle tertutup terakhir.
//     Input baru: InpFiboTF, InpFiboLookback, InpFiboRatio,
//     InpFiboMinRangePoints.
//  3. ARAH RE-ENTRY layer #2 dst = arah init siklus berjalan (g_initSide,
//     dipulihkan dari posisi layer terendah bila EA baru di-attach).
//     Trigger, ambang rugi mengikuti lot, dan aturan lot untung/rugi
//     tidak berubah.
//  4. DIHAPUS: fitur tren EMA (InpTrendEnable/TF/MAPeriod/BufferPoints,
//     GetTrendDir), seluruh logika pending order (PlacePendingPair,
//     CheckOrphanPending, CleanupPendingOfActiveLayers, latch
//     g_pendingLayerNo, CheckLayerDoubleFill), input InpEntryGapPoints,
//     serta baris panel Jarak Entry, Pending, dan Tren. Sisa pending
//     lama di broker dihapus saat start dan saat init (DeleteLegacy-
//     Pendings).
//  5. Panel: baris baru "Arah Init" (BUY/SELL) di bagian LAYER. Log baru
//     [INIT-ENTRY] memuat arah dan dasarnya; [INIT] memuat parameter Fibo.
//  6. Tidak berubah: Unified Real TP, eksekutor, TP-SWEEP, Hedge CL,
//     batas posisi & TP MAXPOS, Daily Max Profit, dan ambang trigger.
//
// v4.10 - INIT DARI DAILY CHANGE %, RECOVERY SAJA, FIBONACCI DIHAPUS:
//
//  1. INIT (layer #1) kini memakai DAILY CHANGE (%) sebagai arah, BUKAN
//     Fibonacci lagi. Sumber angka = (harga sekarang - close D1 kemarin)
//     / close D1 kemarin x 100, dihitung sendiri dari candle D1 (bukan
//     properti simbol broker) supaya benar juga di Strategy Tester.
//     Angka bisa beda tipis dari Market Watch bila batas hari broker
//     berbeda dari batas candle D1.
//  2. Aturan arah (KETAT, "lebih dari"): daily change > +ambang -> BUY
//     (biru / plus); < -ambang -> SELL (merah / minus); di antara
//     -ambang..+ambang -> TIDAK ada init (EA menunggu). Input baru:
//     InpInitDailyPct (default 2.0). Fallback lama (arah init terakhir /
//     candle terakhir) DIHAPUS — di zona netral EA benar-benar menunggu.
//  3. Arah dihitung SEGAR tiap init (termasuk setelah TP), lalu dikunci
//     selama siklus berjalan; re-entry mengikuti arah init itu meski
//     tanda daily change berbalik di tengah siklus.
//  4. DIHAPUS BERSIH: Fibonacci — input InpFiboTF, InpFiboLookback,
//     InpFiboRatio, InpFiboMinRangePoints dan fungsi FiboDirection().
//  5. InpLayerTriggerUSD kini = PEMICU RECOVERY saja. Re-entry HANYA saat
//     floating layer terakhir MINUS (<= -ambang x lot layer terakhir /
//     InpLot). Sisi UNTUNG (>= +nilai) TIDAK lagi memicu re-entry.
//     Karena itu lot re-entry selalu mode upstair/fix (aturan "lot dasar
//     saat untung" tak terpakai). Log diubah [LAYER-TRIGGER] ->
//     [LAYER-RECOVERY]; baris panel Trigger & Lot next disesuaikan.
//  6. Panel baris "Arah Init" menampilkan persen: "BUY (+x.xx%)" biru,
//     "SELL (-x.xx%)" merah, "tunggu (+x.xx%)" redup.
//  7. Tidak berubah: Unified Real TP, eksekutor async, TP-SWEEP, Hedge CL,
//     batas posisi & TP MAXPOS, Daily Max Profit, dan lot upstair.
//======================================================================"
