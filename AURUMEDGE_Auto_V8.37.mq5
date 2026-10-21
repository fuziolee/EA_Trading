//+------------------------------------------------------------------+
//|            AURUM EDGE SCANNER V8.3                          |
//|                                                                  |
//| Historical Time-Edge Scanner for MT5 Strategy Tester            |
//|                                                                  |
//| V8.2 DESIGN                                                       |
//| 1. Tester Start/End Date controlled by MT5 Strategy Tester.      |
//| 2. NO StartDate / EndDate inputs.                               |
//| 3. NO CSV export.                                                |
//| 4. Results printed to Journal only.                              |
//| 5. Scanner runs chronologically during OnTick().                 |
//| 6. No future-data access from OnInit().                          |
//| 7. NO TIMEOUT.                                                   |
//| 8. Trade ends ONLY at TP or SL.                                 |
//| 9. BUY and SELL analyzed independently.                          |
//| 10. Entry candle is included.                                   |
//| 11. BUY entry = ASK, SELL entry = BID.                          |
//| 12. BUY exit = BID, SELL exit = ASK.                            |
//| 13. Same-bar TP/SL -> historical tick resolution.              |
//| 14. Unresolved trades at tester end are NOT losses.             |
//| 15. WR / Expectancy / PF / DD / Streak / Wilson CI95.            |
//+------------------------------------------------------------------+

#property strict
#property version   "8.37"
#property description "AURUM EDGE Scanner V8.37 - Research Build FIX7 - V8.2.1 Execution Core Preserved"

#include <Trade\Trade.mqh>

enum ENUM_EA_MODE
{
   MODE_SCANNER    = 0,   // perilaku V8.37 (scan Tester, tanpa warm-up)
   MODE_LIVE_PANEL = 1    // warm-up + seleksi harian + panel + eksekusi
};

enum ENUM_EXEC_MODE
{
   EXEC_DRYRUN = 0,       // dry-run (tanpa order)
   EXEC_LIVE   = 1        // kirim order sungguhan
};

//====================================================================
// INPUTS (berkelompok)
//====================================================================

input group "=== 1. MODE EA ==="
input ENUM_EA_MODE   EA_Mode  = MODE_SCANNER;   // Scanner (Tester) atau Live Panel
input ENUM_EXEC_MODE ExecMode = EXEC_DRYRUN;    // Dry-run atau Live (hanya efektif di Live Panel)

input group "=== 2. TIMEFRAME ==="
input ENUM_TIMEFRAMES Timeframe_Test = PERIOD_M1;

input group "=== 3. SL / TP (FIXED) ==="
input int TP_Points = 700;                      // TP (poin)
input int SL_Points = 500;                      // SL (poin)

input group "=== 10. EKSEKUSI: LOT ==="
input double ExecFixedLot = 0.01;               // lot manual

input group "=== 4. KUALIFIKASI SLOT ==="
input int    MinSamples     = 30;
input double Min_WR         = 45.0;
input double MaxSlotDD_R    = 5.0;
input double Min_PF         = 1.30;
input double Min_Expectancy = 0.0;
input bool   RR_AdjustWRThresholds = true;      // Min_WR relatif terhadap breakeven WR
input bool   ShowOnlyQualified     = true;

input group "=== 5. DISCOVERY & FORWARD ==="
input int DiscoveryDays      = 150;
input int ForwardDays        = 0;
input int MaxNeighborMinutes = 5;

input group "=== 6. BIAYA & SIMULASI ==="
input int    SimulatedSpreadPoints = 25;        // fallback bila ASK historis tidak ada
input int    EntrySlippagePoints   = 0;
input double CommissionUSDPerLot   = 1.0;
input double CostStress1 = 1.00;
input double CostStress2 = 1.25;
input double CostStress3 = 1.50;
input double SimulationRiskUSD = 5.0;
input bool   UseTickResolution = true;

input group "=== 7. MONTE CARLO & LAPORAN ==="
input int  MonteCarloRuns = 1000;
input int  MonteCarloSeed = 8301;
input bool ShowV83ResearchReport = true;
input bool ShowQualifiedSummary  = true;
input bool ShowNotEligibleCount  = true;
input bool ShowResearchTable     = false;

input group "=== 8. WAKTU, JENDELA & PANEL ==="
input int  ServerToWIB_Hours = 0;               // 0 = jam slot = jam server
input int  ExecStartMinute   = 60;              // 01:00
input int  ExecEndMinute     = 1439;            // 23:59 (force-close di sini)
input int  SessionAsiaStartHour   = 1;
input int  SessionEuropeStartHour = 10;
input int  SessionUSStartHour     = 16;
input bool ShowPanel = true;

input group "=== 9. EKSEKUSI: ENTRY ==="
input int  ExecMaxSpreadPoints  = 50;           // skip entry bila spread lebih dari ini (0 = off)
input int  ExecMaxEntryDelaySec = 10;           // telat lebih dari ini = skip
input int  ExecDeviationPoints  = 30;           // slippage maksimum order (poin)
input long ExecMagic            = 20260801;     // magic number EA

input group "=== 11. EKSEKUSI: PENGAMAN RISIKO ==="
input double ExecMaxDailyLossR   = 0;           // stop entry hari ini bila rugi (R), 0 = off
input int    ExecMaxConsecLosses = 0;           // stop entry hari ini setelah N kalah beruntun, 0 = off

//====================================================================
// CONSTANTS
//====================================================================

// Maximum number of days retained for chronological
// streak / DD history per minute.
//
// 1000 days is more than enough for normal research windows.
#define MAX_HISTORY_DAYS 1000

// Jumlah minggu pada kolom WEEKLY di tabel riset.
#define WEEKLY_WEEKS 12

//====================================================================
// RESULT
//====================================================================

enum ENUM_RESULT
{
   RESULT_PENDING = -1,
   RESULT_LOSS    = 0,
   RESULT_WIN     = 1
};

//====================================================================
// OPEN TRADE
//====================================================================

struct OpenTrade
{
   bool     isBuy;

   int      slot;
   int      entrySequence;

   datetime entryTime;
   long     entryTimeMsc;

   double   entryPrice;
   double   tpPrice;
   double   slPrice;
};

//====================================================================
// GLOBAL OPEN TRADES
//====================================================================

OpenTrade OpenTrades[];

int OpenTradeCount = 0;

//====================================================================
// SLOT HISTORY
//
// Each WIB minute gets one BUY and one SELL entry per day.
// Result is stored in chronological ENTRY order.
//
// -1 = unresolved
//  0 = loss
//  1 = win
//====================================================================

int BuyHistory[1440][MAX_HISTORY_DAYS];
int SellHistory[1440][MAX_HISTORY_DAYS];

int BuyEntryCount[1440];
int SellEntryCount[1440];

int BuyWins[1440];
int BuyLosses[1440];

int SellWins[1440];
int SellLosses[1440];

int BuyEntryDateKey[1440][MAX_HISTORY_DAYS];
int SellEntryDateKey[1440][MAX_HISTORY_DAYS];

// Real spread observed at entry time (ask-bid, in points), per slot.
// Passive bookkeeping only - does NOT affect entry price, TP/SL, or
// trade resolution. Used only by V8.3 Cost Sensitivity to use the
// ACTUAL spread this symbol/time-of-day had, instead of guessing.
double RealSpreadSumPoints[1440];
long   RealSpreadCount[1440];

// Cached cluster IDs; built once per final report.
int V83BuyClusterID[1440];
int V83SellClusterID[1440];

// V8.37 FIX7 - cluster analytics cache.
int V83BuyClusterMembers[1441];
int V83SellClusterMembers[1441];

int V83BuyClusterFirst[1441];
int V83BuyClusterLast[1441];
int V83SellClusterFirst[1441];
int V83SellClusterLast[1441];

double V83BuyClusterAGRValue[1441];
double V83SellClusterAGRValue[1441];

int V83BuyClusterActiveDays[1441];
int V83BuyClusterFullDays[1441];

int V83SellClusterActiveDays[1441];
int V83SellClusterFullDays[1441];

bool V83ClustersReady = false;
bool V83ClusterAnalyticsReady = false;

// Cached population WR stats (across all HIST-QUALIFIED sides);
// used by the Outlier/Anomaly diagnostic. Built once per final report.
double V83PopMeanWR = 0.0;
double V83PopStdWR  = 0.0;
int    V83PopCount  = 0;
bool   V83PopReady  = false;

//====================================================================
// DAY LOCK
//====================================================================

bool TradedBuyThisMinute[1440];
bool TradedSellThisMinute[1440];

int CurrentWIBDateKey = -1;

//====================================================================
// TEST INFORMATION
//====================================================================

datetime FirstSeenTime = 0;
datetime LastSeenTime  = 0;

datetime LastBarTime = 0;
datetime LastProcessedClosedBar = 0;

long TotalEntries = 0;
long TotalResolved = 0;
long TotalUnresolved = 0;

long SameBarM1Resolved = 0;
long SameBarTickResolved = 0;
long SameBarFallbackLoss = 0;

long HistoryOverflowBuy = 0;
long HistoryOverflowSell = 0;

long QualifiedOutputCount = 0;

//====================================================================
// V8.4 LIVE MODE STATE
//====================================================================

// Lama trade (detik, entry -> selesai); -1 = belum selesai.
int BuyDelaySec[1440][MAX_HISTORY_DAYS];
int SellDelaySec[1440][MAX_HISTORY_DAYS];

bool     g_WarmupDone = false;
bool     g_WarmupOK = false;
long     g_WarmupBars = 0;
datetime g_WarmupFirstBar = 0;
int      g_WarmupSpanDays = 0;

struct SelRow
{
   int    slot;
   bool   isBuy;
   int    n;
   int    w;
   int    l;
   int    maxL;
   double wr;
   double ciLow;
   double pf;
   double ex;
   double dd;
   int    clFirst;
   int    clLast;
   int    clMembers;
   double cutPct;
};

SelRow g_Sel[];
int    g_SelCount = 0;
int    g_SelectionDayKey = -1;

int g_FunnelQual = 0;
int g_FunnelClusters = 0;

datetime g_LastPanelTime = 0;

//====================================================================
// V8.4 DRY-RUN EXECUTION STATE (2b-1, tanpa order)
//====================================================================

struct DryPos
{
   bool     active;
   bool     isBuy;
   int      slot;
   datetime entryTime;
   double   entryPrice;
   double   sl;
   double   tp;
   double   slPts;
   double   tpPts;
   double   predWR;
   double   predExp;
   double   predCILow;
};

DryPos g_Dry;

int    g_DryDayKey = -1;
int    g_DryDayTrades = 0;
int    g_DryDayWins = 0;
int    g_DryDayLosses = 0;
int    g_DryDayForced = 0;
double g_DryDayR = 0.0;
int    g_DryConsec = 0;
bool   g_DryStopped = false;
string g_DryStopReason = "";

int    g_DryTotTrades = 0;
int    g_DryTotWins = 0;
int    g_DryTotLosses = 0;
int    g_DryTotForced = 0;
double g_DryTotR = 0.0;
double g_DryTotPredR = 0.0;
double g_DryPeakR = 0.0;
double g_DryMaxDDR = 0.0;

datetime g_DryLastBar = 0;

void DryRunReset()
{
   g_Dry.active = false;
   g_Dry.isBuy = true;
   g_Dry.slot = -1;
   g_Dry.entryTime = 0;
   g_Dry.entryPrice = 0.0;
   g_Dry.sl = 0.0;
   g_Dry.tp = 0.0;
   g_Dry.slPts = 0.0;
   g_Dry.tpPts = 0.0;
   g_Dry.predWR = 0.0;
   g_Dry.predExp = 0.0;
   g_Dry.predCILow = 0.0;

   g_DryDayKey = -1;
   g_DryDayTrades = 0;
   g_DryDayWins = 0;
   g_DryDayLosses = 0;
   g_DryDayForced = 0;
   g_DryDayR = 0.0;
   g_DryConsec = 0;
   g_DryStopped = false;
   g_DryStopReason = "";

   g_DryTotTrades = 0;
   g_DryTotWins = 0;
   g_DryTotLosses = 0;
   g_DryTotForced = 0;
   g_DryTotR = 0.0;
   g_DryTotPredR = 0.0;
   g_DryPeakR = 0.0;
   g_DryMaxDDR = 0.0;

   g_DryLastBar = 0;
}

//====================================================================
// TIME
//====================================================================

datetime ToWIB(datetime serverTime)
{
   return serverTime +
          ServerToWIB_Hours * 3600;
}

//--------------------------------------------------------------------

int GetWIBIndex(datetime serverTime)
{
   datetime wib =
      ToWIB(serverTime);

   MqlDateTime dt;
   TimeToStruct(wib, dt);

   return dt.hour * 60 +
          dt.min;
}

//--------------------------------------------------------------------

int GetWIBDateKey(datetime serverTime)
{
   datetime wib =
      ToWIB(serverTime);

   MqlDateTime dt;
   TimeToStruct(wib, dt);

   return dt.year * 10000 +
          dt.mon * 100 +
          dt.day;
}

//====================================================================
// SL/TP MODE + RR-AWARE HELPERS
//
// Fungsi jarak SL/TP ini dipakai oleh simulasi scan dan (nanti)
// eksekutor, supaya statistik selalu sesuai trade yang dieksekusi.
//====================================================================

double g_RR = 1.0;

// SL/TP fixed. Signature dipertahankan supaya pemanggil
// (AddTrade, DryRunTick, LiveExecTick) tidak perlu diubah.
bool GetSLTPPoints(double &slPts,double &tpPts,datetime atTime = 0)
{
   slPts = (double)SL_Points;
   tpPts = (double)TP_Points;
   return true;
}

double BreakevenWR()
{
   return 100.0 / (1.0 + g_RR);
}

double EffMinWR()
{
   return RR_AdjustWRThresholds ? BreakevenWR() + (Min_WR - 50.0)
                                : Min_WR;
}

double EffFwdWR()
{
   return RR_AdjustWRThresholds ? BreakevenWR() + 10.0 : 60.0;
}

double V83AvgSLPoints(int slot)
{
   return (double)SL_Points;
}

//====================================================================
// RESET HISTORY
//====================================================================

void ResetHistory()
{
   ArrayInitialize(
      BuyHistory,
      -1
   );

   ArrayInitialize(
      SellHistory,
      -1
   );

   ArrayInitialize(
      BuyEntryCount,
      0
   );

   ArrayInitialize(
      SellEntryCount,
      0
   );

   ArrayInitialize(
      BuyWins,
      0
   );

   ArrayInitialize(
      BuyLosses,
      0
   );

   ArrayInitialize(
      SellWins,
      0
   );

   ArrayInitialize(
      SellLosses,
      0
   );

   ArrayInitialize(
      BuyEntryDateKey,
      0
   );

   ArrayInitialize(
      SellEntryDateKey,
      0
   );

   ArrayInitialize(
      RealSpreadSumPoints,
      0.0
   );

   ArrayInitialize(
      RealSpreadCount,
      0
   );

   ArrayInitialize(
      TradedBuyThisMinute,
      false
   );

   ArrayInitialize(
      TradedSellThisMinute,
      false
   );

   OpenTradeCount = 0;

   ArrayFree(OpenTrades);

   CurrentWIBDateKey = -1;

   FirstSeenTime = 0;
   LastSeenTime = 0;

   LastBarTime = 0;
   LastProcessedClosedBar = 0;

   TotalEntries = 0;
   TotalResolved = 0;
   TotalUnresolved = 0;

   SameBarM1Resolved = 0;
   SameBarTickResolved = 0;
   SameBarFallbackLoss = 0;

   HistoryOverflowBuy = 0;
   HistoryOverflowSell = 0;

   QualifiedOutputCount = 0;

   // V8.37 FIX7 - reset every analytics cache for each run.
   ArrayInitialize(V83BuyClusterID,0);
   ArrayInitialize(V83SellClusterID,0);
   ArrayInitialize(V83BuyClusterMembers,0);
   ArrayInitialize(V83SellClusterMembers,0);
   ArrayInitialize(V83BuyClusterFirst,-1);
   ArrayInitialize(V83BuyClusterLast,-1);
   ArrayInitialize(V83SellClusterFirst,-1);
   ArrayInitialize(V83SellClusterLast,-1);
   ArrayInitialize(V83BuyClusterAGRValue,0.0);
   ArrayInitialize(V83SellClusterAGRValue,0.0);
   ArrayInitialize(V83BuyClusterActiveDays,0);
   ArrayInitialize(V83BuyClusterFullDays,0);
   ArrayInitialize(V83SellClusterActiveDays,0);
   ArrayInitialize(V83SellClusterFullDays,0);

   V83ClustersReady=false;
   V83ClusterAnalyticsReady=false;
   V83PopMeanWR=0.0;
   V83PopStdWR=0.0;
   V83PopCount=0;
   V83PopReady=false;

   ArrayInitialize(BuyDelaySec,-1);
   ArrayInitialize(SellDelaySec,-1);

   g_WarmupDone = false;
   g_WarmupOK = false;
   g_WarmupBars = 0;
   g_WarmupFirstBar = 0;
   g_WarmupSpanDays = 0;

   g_SelectionDayKey = -1;
   g_SelCount = 0;
   ArrayResize(g_Sel,0);
   g_LastPanelTime = 0;

   DryRunReset();
}

//====================================================================
// RECORD RESULT
//====================================================================

void RecordResult(
   bool isBuy,
   int slot,
   int sequence,
   ENUM_RESULT result
)
{
   if(result == RESULT_PENDING)
      return;

   if(isBuy)
   {
      if(sequence < MAX_HISTORY_DAYS)
      {
         BuyHistory[slot][sequence] =
            (int)result;
      }
      else
      {
         HistoryOverflowBuy++;
      }

      if(result == RESULT_WIN)
         BuyWins[slot]++;
      else
         BuyLosses[slot]++;
   }
   else
   {
      if(sequence < MAX_HISTORY_DAYS)
      {
         SellHistory[slot][sequence] =
            (int)result;
      }
      else
      {
         HistoryOverflowSell++;
      }

      if(result == RESULT_WIN)
         SellWins[slot]++;
      else
         SellLosses[slot]++;
   }

   TotalResolved++;
}

void RecordDelay(
   bool isBuy,
   int slot,
   int sequence,
   int delaySec
)
{
   if(sequence < 0 || sequence >= MAX_HISTORY_DAYS)
      return;

   if(isBuy)
      BuyDelaySec[slot][sequence] = delaySec;
   else
      SellDelaySec[slot][sequence] = delaySec;
}

//====================================================================
// ADD HYPOTHETICAL TRADE
//====================================================================

void AddTrade(
   bool isBuy,
   int slot,
   datetime entryTime,
   long entryTimeMsc,
   double entryPrice
)
{
   if(slot < 0 ||
      slot >= 1440)
   {
      return;
   }

   double slPts;
   double tpPts;

   // ATR belum siap: slot ini dilewati (tidak ada entry).
   if(!GetSLTPPoints(slPts,tpPts,entryTime))
      return;

   double tp;
   double sl;

   if(isBuy)
   {
      tp = entryPrice + tpPts * _Point;
      sl = entryPrice - slPts * _Point;
   }
   else
   {
      tp = entryPrice - tpPts * _Point;
      sl = entryPrice + slPts * _Point;
   }

   int sequence;

   if(isBuy)
   {
      sequence =
         BuyEntryCount[slot];

      BuyEntryCount[slot]++;
   }
   else
   {
      sequence =
         SellEntryCount[slot];

      SellEntryCount[slot]++;
   }

   int entryDateKey = GetWIBDateKey(entryTime);

   if(sequence < MAX_HISTORY_DAYS)
   {
      if(isBuy)
         BuyEntryDateKey[slot][sequence] = entryDateKey;
      else
         SellEntryDateKey[slot][sequence] = entryDateKey;
   }

   int newSize =
      OpenTradeCount + 1;

   if(ArrayResize(
         OpenTrades,
         newSize,
         512
      ) != newSize)
   {
      Print(
         "ERROR: Cannot resize OpenTrades."
      );

      return;
   }

   int index =
      OpenTradeCount;

   OpenTrades[index].isBuy =
      isBuy;

   OpenTrades[index].slot =
      slot;

   OpenTrades[index].entrySequence =
      sequence;

   OpenTrades[index].entryTime =
      entryTime;

   OpenTrades[index].entryTimeMsc =
      entryTimeMsc;

   OpenTrades[index].entryPrice =
      entryPrice;

   OpenTrades[index].tpPrice =
      tp;

   OpenTrades[index].slPrice =
      sl;

   OpenTradeCount++;

   TotalEntries++;
}

//====================================================================
// FALLBACK ENTRY PRICE
//
// BUY  = Bid + spread + slippage
// SELL = Bid - slippage
//
// Normally we use actual tick ASK/BID.
// This is only fallback.
//====================================================================

double GetFallbackEntryPrice(
   double bid,
   bool isBuy
)
{
   double spread =
      SimulatedSpreadPoints *
      _Point;

   double slip =
      EntrySlippagePoints *
      _Point;

   if(isBuy)
   {
      return bid +
             spread +
             slip;
   }

   return bid -
          slip;
}

//====================================================================
// CREATE BUY + SELL FOR CURRENT BAR
//====================================================================

void CreateEntriesForCurrentBar(
   datetime barTime
)
{
   MqlTick tick;

   ResetLastError();

   if(!SymbolInfoTick(
         _Symbol,
         tick
      ))
   {
      Print(
         "WARNING: SymbolInfoTick failed. Error=",
         GetLastError()
      );

      return;
   }

   double bid =
      tick.bid;

   double ask =
      tick.ask;

   if(bid <= 0.0)
      return;

   double fallbackSpread =
      SimulatedSpreadPoints *
      _Point;

   double slip =
      EntrySlippagePoints *
      _Point;

   double buyEntry;
   double sellEntry;

   //===============================================================
   // BUY
   //===============================================================

   if(ask > 0.0)
   {
      buyEntry =
         ask +
         slip;
   }
   else
   {
      buyEntry =
         GetFallbackEntryPrice(
            bid,
            true
         );
   }

   //===============================================================
   // SELL
   //===============================================================

   sellEntry =
      bid -
      slip;

   int slot =
      GetWIBIndex(barTime);

   int dateKey =
      GetWIBDateKey(barTime);

   //===============================================================
   // V8.3 - PASSIVE SPREAD BOOKKEEPING
   //
   // Records the REAL observed spread (ask-bid) for this slot when
   // actual tick ASK is available. Read-only bookkeeping, same
   // category as BuyEntryDateKey/SellEntryDateKey: does NOT affect
   // buyEntry/sellEntry price, TP/SL, or trade resolution above.
   // Used only by V8.3 Cost Sensitivity (V83EffectiveSpreadPoints).
   //===============================================================

   if(ask > 0.0)
   {
      RealSpreadSumPoints[slot] +=
         (ask - bid) / _Point;

      RealSpreadCount[slot]++;
   }

   //===============================================================
   // NEW WIB DAY
   //===============================================================

   if(dateKey != CurrentWIBDateKey)
   {
      ArrayInitialize(
         TradedBuyThisMinute,
         false
      );

      ArrayInitialize(
         TradedSellThisMinute,
         false
      );

      CurrentWIBDateKey =
         dateKey;
   }

   //===============================================================
   // BUY
   //===============================================================

   if(!TradedBuyThisMinute[slot])
   {
      TradedBuyThisMinute[slot] = true;

      AddTrade(
         true,
         slot,
         barTime,
         tick.time_msc,
         buyEntry
      );
   }

   //===============================================================
   // SELL
   //===============================================================

   if(!TradedSellThisMinute[slot])
   {
      TradedSellThisMinute[slot] = true;

      AddTrade(
         false,
         slot,
         barTime,
         tick.time_msc,
         sellEntry
      );
   }
}

//====================================================================
// SAME-BAR TICK RESOLUTION
//
// BUY:
//   TP -> BID >= TP
//   SL -> BID <= SL
//
// SELL:
//   TP -> ASK <= TP
//   SL -> ASK >= SL
//====================================================================

ENUM_RESULT ResolveSameBarByTicks(
   int tradeIndex,
   datetime barTime,
   int windowSeconds = 0
)
{
   if(!UseTickResolution)
      return RESULT_PENDING;

   int secondsPerBar =
      (windowSeconds > 0) ? windowSeconds
                          : PeriodSeconds(Timeframe_Test);

   if(secondsPerBar <= 0)
      return RESULT_PENDING;

   datetime nextBarTime =
      barTime +
      secondsPerBar;

   ulong fromMsc =
      (ulong)barTime *
      1000;

   // If the trade entered inside this same bar,
   // start from the actual entry tick.
   if(OpenTrades[tradeIndex].entryTimeMsc >
      (long)fromMsc)
   {
      fromMsc =
         (ulong)OpenTrades[tradeIndex].entryTimeMsc;
   }

   ulong toMsc =
      (ulong)nextBarTime *
      1000 -
      1;

   MqlTick ticks[];

   ResetLastError();

   int copied =
      CopyTicksRange(
         _Symbol,
         ticks,
         COPY_TICKS_INFO,
         fromMsc,
         toMsc
      );

   if(copied <= 0)
   {
      return RESULT_PENDING;
   }

   double tp =
      OpenTrades[tradeIndex].tpPrice;

   double sl =
      OpenTrades[tradeIndex].slPrice;

   bool isBuy =
      OpenTrades[tradeIndex].isBuy;

   for(int i = 0;
       i < copied;
       i++)
   {
      double bid =
         ticks[i].bid;

      double ask =
         ticks[i].ask;

      if(isBuy)
      {
         if(bid > 0.0)
         {
            if(bid >= tp)
               return RESULT_WIN;

            if(bid <= sl)
               return RESULT_LOSS;
         }
      }
      else
      {
         if(ask > 0.0)
         {
            if(ask <= tp)
               return RESULT_WIN;

            if(ask >= sl)
               return RESULT_LOSS;
         }
      }
   }

   return RESULT_PENDING;
}

//====================================================================
// SAME-BAR RESOLUTION VIA M1 SUB-BARS (bertingkat)
//
// Dipakai saat Timeframe_Test > M1 dan satu bar menyentuh TP dan SL.
// Urutan ditentukan dari bar M1 di dalam bar itu. Tick hanya dipakai
// jika TP dan SL tersentuh dalam SATU bar M1 yang sama.
// Fallback konservatif = LOSS.
//
// Return RESULT_PENDING hanya jika Timeframe_Test = M1 atau data M1
// tidak ada; pemanggil lalu memakai resolusi tick seluruh bar.
//====================================================================

ENUM_RESULT ResolveSameBarByM1(
   int tradeIndex,
   datetime barTime
)
{
   int tfSeconds = PeriodSeconds(Timeframe_Test);

   if(tfSeconds <= 60)
      return RESULT_PENDING;

   datetime from = barTime;

   if(OpenTrades[tradeIndex].entryTime > from)
      from = OpenTrades[tradeIndex].entryTime;

   datetime to = barTime + tfSeconds - 1;

   MqlRates m1[];

   ResetLastError();

   int copied = CopyRates(_Symbol, PERIOD_M1, from, to, m1);

   if(copied <= 0)
      return RESULT_PENDING;

   double tp = OpenTrades[tradeIndex].tpPrice;
   double sl = OpenTrades[tradeIndex].slPrice;
   bool isBuy = OpenTrades[tradeIndex].isBuy;

   double spread = SimulatedSpreadPoints * _Point;

   for(int i = 0; i < copied; i++)
   {
      bool hitTP;
      bool hitSL;

      if(isBuy)
      {
         hitTP = m1[i].high >= tp;
         hitSL = m1[i].low <= sl;
      }
      else
      {
         hitTP = (m1[i].low + spread) <= tp;
         hitSL = (m1[i].high + spread) >= sl;
      }

      if(!hitTP && !hitSL)
         continue;

      if(hitTP && !hitSL)
      {
         SameBarM1Resolved++;
         return RESULT_WIN;
      }

      if(hitSL && !hitTP)
      {
         SameBarM1Resolved++;
         return RESULT_LOSS;
      }

      // TP dan SL tersentuh di bar M1 yang sama -> coba tick.
      ENUM_RESULT tickResult =
         ResolveSameBarByTicks(
            tradeIndex,
            m1[i].time,
            60
         );

      if(tickResult != RESULT_PENDING)
      {
         SameBarTickResolved++;
         return tickResult;
      }

      SameBarFallbackLoss++;
      return RESULT_LOSS;
   }

   // Tidak ada sentuhan terdeteksi di M1 (data tidak konsisten).
   return RESULT_PENDING;
}


//====================================================================
// RESOLVE ONE TRADE AGAINST CLOSED BAR
//
// barHigh / barLow are historical BID OHLC.
//
// BUY exit:
//   BID high >= TP
//   BID low  <= SL
//
// SELL exit:
//   ASK = BID + fallback spread
//====================================================================

ENUM_RESULT ResolveTradeAgainstBar(
   int tradeIndex,
   datetime barTime,
   double barHigh,
   double barLow
)
{
   double tp =
      OpenTrades[tradeIndex].tpPrice;

   double sl =
      OpenTrades[tradeIndex].slPrice;

   bool isBuy =
      OpenTrades[tradeIndex].isBuy;

   double spread =
      SimulatedSpreadPoints *
      _Point;

   bool hitTP = false;
   bool hitSL = false;

   if(isBuy)
   {
      // BUY closes on BID.
      hitTP =
         barHigh >= tp;

      hitSL =
         barLow <= sl;
   }
   else
   {
      // SELL closes on ASK.
      //
      // Historical OHLC is based on Bid,
      // therefore approximate Ask = Bid + fallback spread.
      hitTP =
         (barLow + spread) <= tp;

      hitSL =
         (barHigh + spread) >= sl;
   }

   //===============================================================
   // Nothing hit
   //===============================================================

   if(!hitTP &&
      !hitSL)
   {
      return RESULT_PENDING;
   }

   //===============================================================
   // ONLY TP
   //===============================================================

   if(hitTP &&
      !hitSL)
   {
      return RESULT_WIN;
   }

   //===============================================================
   // ONLY SL
   //===============================================================

   if(hitSL &&
      !hitTP)
   {
      return RESULT_LOSS;
   }

   //===============================================================
   // BOTH TP + SL
   //===============================================================

   if(hitTP &&
      hitSL)
   {
      ENUM_RESULT m1Result =
         ResolveSameBarByM1(tradeIndex,barTime);

      if(m1Result != RESULT_PENDING)
         return m1Result;

      ENUM_RESULT tickResult =
         ResolveSameBarByTicks(
            tradeIndex,
            barTime
         );

      if(tickResult != RESULT_PENDING)
      {
         SameBarTickResolved++;

         return tickResult;
      }

      // Conservative fallback:
      // ambiguous candle = LOSS.
      SameBarFallbackLoss++;

      return RESULT_LOSS;
   }

   return RESULT_PENDING;
}

//====================================================================
// RESOLVE ALL OPEN TRADES AGAINST ONE CLOSED BAR
//====================================================================

void ResolveOpenTrades(
   datetime barTime,
   double barHigh,
   double barLow
)
{
   int i = 0;

   while(i < OpenTradeCount)
   {
      ENUM_RESULT result =
         ResolveTradeAgainstBar(
            i,
            barTime,
            barHigh,
            barLow
         );

      if(result == RESULT_PENDING)
      {
         i++;
         continue;
      }

      bool isBuy =
         OpenTrades[i].isBuy;

      int slot =
         OpenTrades[i].slot;

      int sequence =
         OpenTrades[i].entrySequence;

      RecordResult(
         isBuy,
         slot,
         sequence,
         result
      );

      RecordDelay(
         isBuy,
         slot,
         sequence,
         (int)(barTime + PeriodSeconds(Timeframe_Test) -
               OpenTrades[i].entryTime)
      );

      //============================================================
      // Remove trade by replacing with last element.
      //============================================================

      int lastIndex =
         OpenTradeCount - 1;

      if(i != lastIndex)
      {
         OpenTrades[i] =
            OpenTrades[lastIndex];
      }

      OpenTradeCount--;

      ArrayResize(
         OpenTrades,
         OpenTradeCount
      );

      // Do NOT increment i.
      // A new trade has been moved into index i.
   }
}

//====================================================================
// PROCESS PREVIOUS CLOSED BAR
//====================================================================

bool ProcessPreviousClosedBar()
{
   MqlRates bar[];

   ResetLastError();

   int copied =
      CopyRates(
         _Symbol,
         Timeframe_Test,
         1,
         1,
         bar
      );

   if(copied != 1)
   {
      Print(
         "WARNING: CopyRates previous bar failed. Error=",
         GetLastError()
      );

      return false;
   }

   datetime barTime =
      bar[0].time;

   // Prevent duplicate processing.
   if(barTime == LastProcessedClosedBar)
      return true;

   ResolveOpenTrades(
      barTime,
      bar[0].high,
      bar[0].low
   );

   LastProcessedClosedBar =
      barTime;

   return true;
}

//====================================================================
// NEW BAR DETECTION
//====================================================================

void ProcessNewBar(
   datetime currentBarTime
)
{
   //===============================================================
   // First bar
   //===============================================================

   if(LastBarTime == 0)
   {
      LastBarTime =
         currentBarTime;

      CreateEntriesForCurrentBar(
         currentBarTime
      );

      return;
   }

   //===============================================================
   // Same bar
   //===============================================================

   if(currentBarTime == LastBarTime)
      return;

   //===============================================================
   // New bar:
   // previous bar is now closed.
   //===============================================================

   ProcessPreviousClosedBar();

   LastBarTime =
      currentBarTime;

   //===============================================================
   // New hypothetical entries
   //===============================================================

   CreateEntriesForCurrentBar(
      currentBarTime
   );
}

//====================================================================
// WILSON CI
//====================================================================

double CI_Lower(
   int wins,
   int n
)
{
   if(n <= 0)
      return 0.0;

   double z =
      1.95996398454005;

   double p =
      (double)wins /
      n;

   double denom =
      1.0 +
      (z*z) / n;

   double center =
      p +
      (z*z) /
      (2.0*n);

   double margin =
      z *
      MathSqrt(
         (p*(1.0-p)/n) +
         ((z*z)/(4.0*n*n))
      );

   return
      ((center - margin) /
       denom) *
      100.0;
}

//--------------------------------------------------------------------

double CI_Upper(
   int wins,
   int n
)
{
   if(n <= 0)
      return 0.0;

   double z =
      1.95996398454005;

   double p =
      (double)wins /
      n;

   double denom =
      1.0 +
      (z*z) / n;

   double center =
      p +
      (z*z) /
      (2.0*n);

   double margin =
      z *
      MathSqrt(
         (p*(1.0-p)/n) +
         ((z*z)/(4.0*n*n))
      );

   return
      ((center + margin) /
       denom) *
      100.0;
}

//====================================================================
// CALCULATE SLOT METRICS FROM ENTRY ORDER
//====================================================================

double SlotExpectancy(
   int wins,
   int losses
)
{
   int n =
      wins + losses;

   if(n <= 0)
      return 0.0;

   double wr =
      (double)wins /
      n;

   return
      wr -
      (1.0-wr);
}

//--------------------------------------------------------------------

double SlotPF(
   int wins,
   int losses
)
{
   if(losses <= 0)
   {
      if(wins > 0)
         return 999.0;

      return 0.0;
   }

   return
      (double)wins /
      losses;
}

//====================================================================
// MAX DD + MAX LOSS STREAK
//
// Calculated in ENTRY chronological order,
// not in resolution order.
//====================================================================

void CalculateSlotRisk(
   bool isBuy,
   int slot,
   double &maxDD,
   int &maxLossStreak,
   int &maxWinStreak
)
{
   maxDD = 0.0;

   maxLossStreak = 0;
   maxWinStreak = 0;

   double equity = 0.0;
   double peak = 0.0;

   int lossStreak = 0;
   int winStreak = 0;

   int totalEntries;

   if(isBuy)
      totalEntries = BuyEntryCount[slot];
   else
      totalEntries = SellEntryCount[slot];

   int maxLoop =
      MathMin(
         totalEntries,
         MAX_HISTORY_DAYS
      );

   for(int i = 0;
       i < maxLoop;
       i++)
   {
      int result;

      if(isBuy)
         result = BuyHistory[slot][i];
      else
         result = SellHistory[slot][i];

      // unresolved at tester end
      if(result < 0)
         continue;

      if(result == RESULT_WIN)
      {
         equity += 1.0;

         winStreak++;
         lossStreak = 0;

         if(winStreak > maxWinStreak)
            maxWinStreak =
               winStreak;
      }
      else
      {
         equity -= 1.0;

         lossStreak++;
         winStreak = 0;

         if(lossStreak > maxLossStreak)
            maxLossStreak =
               lossStreak;
      }

      if(equity > peak)
         peak = equity;

      double dd =
         peak -
         equity;

      if(dd > maxDD)
         maxDD = dd;
   }
}

//====================================================================
// V8.3 ANALYTICS
//====================================================================

datetime V83DateFromKey(int key)
{
   if(key <= 0) return 0;
   int y = key / 10000;
   int m = (key / 100) % 100;
   int d = key % 100;
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = y; dt.mon = m; dt.day = d;
   return StructToTime(dt);
}

int V83DateKey(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t,dt);
   return dt.year*10000 + dt.mon*100 + dt.day;
}

int V83DayDiff(int a,int b)
{
   datetime ta=V83DateFromKey(a), tb=V83DateFromKey(b);
   if(ta==0 || tb==0) return 0;
   return (int)((ta-tb)/86400);
}

bool V83IsInDiscovery(int dateKey, int lastKey)
{
   if(dateKey<=0 || lastKey<=0) return false;
   datetime last=V83DateFromKey(lastKey);
   datetime first=last-(DiscoveryDays+ForwardDays-1)*86400;
   datetime discEnd=last-ForwardDays*86400;
   datetime d=V83DateFromKey(dateKey);
   return d>=first && d<=discEnd;
}

bool V83IsInForward(int dateKey, int lastKey)
{
   if(dateKey<=0 || lastKey<=0) return false;
   datetime last=V83DateFromKey(lastKey);
   datetime first=last-(ForwardDays-1)*86400;
   datetime d=V83DateFromKey(dateKey);
   return d>=first && d<=last;
}

void V83GetWindowKeys(int &firstKey,int &discoveryEndKey,int &lastKey)
{
   lastKey = V83DateKey(LastSeenTime);
   if(lastKey<=0) { firstKey=0; discoveryEndKey=0; return; }
   datetime last=V83DateFromKey(lastKey);
   datetime first=last-(DiscoveryDays+ForwardDays-1)*86400;
   datetime de=last-ForwardDays*86400;
   firstKey=V83DateKey(first);
   discoveryEndKey=V83DateKey(de);
}

void V83Stats(bool isBuy,int slot,bool discovery,
              int &n,int &w,int &l,double &wr,double &exp,double &pf,double &dd,int &maxL)
{
   n=0; w=0; l=0; wr=0; exp=0; pf=0; dd=0; maxL=0;
   int total=isBuy?BuyEntryCount[slot]:SellEntryCount[slot];
   int maxLoop=MathMin(total,MAX_HISTORY_DAYS);
   int lastKey,discEndKey,firstKey;
   V83GetWindowKeys(firstKey,discEndKey,lastKey);

   double eq=0,peak=0;
   int ls=0;
   for(int i=0;i<maxLoop;i++)
   {
      int dk=isBuy?BuyEntryDateKey[slot][i]:SellEntryDateKey[slot][i];
      if(discovery ? !V83IsInDiscovery(dk,lastKey) : !V83IsInForward(dk,lastKey)) continue;
      int r=isBuy?BuyHistory[slot][i]:SellHistory[slot][i];
      if(r<0) continue;
      n++;
      if(r==RESULT_WIN) { w++; eq+=g_RR; ls=0; }
      else { l++; eq-=1.0; ls++; if(ls>maxL) maxL=ls; }
      if(eq>peak) peak=eq;
      if(peak-eq>dd) dd=peak-eq;
   }
   if(n>0)
   {
      wr=100.0*w/n;
      exp=((double)w*g_RR-(double)l)/n;
      pf=(l>0)?((double)w*g_RR)/(double)l:(w>0?999.0:0.0);
   }
}

bool V83HistoricalQualified(bool isBuy,int slot)
{
   int n,w,l,maxL; double wr,exp,pf,dd;
   V83Stats(isBuy,slot,true,n,w,l,wr,exp,pf,dd,maxL);
   return n>=MinSamples && wr>=EffMinWR() && pf>=Min_PF &&
          exp>=Min_Expectancy && dd<=MaxSlotDD_R;
}

bool V83Eligible(bool isBuy,int slot)
{
   int n,w,l,maxL; double wr,exp,pf,dd;
   V83Stats(isBuy,slot,true,n,w,l,wr,exp,pf,dd,maxL);
   double lower=CI_Lower(w,n);
   return n>=MinSamples && lower>0.0;
}

// V83NeighborWR kept for reference/possible future use - no longer
// used by V83Robustness (see below), which now evaluates each
// offset individually instead of pooling a radius together.
double V83NeighborWR(bool isBuy,int slot,int radius,int &n,int &w)
{
   n=0; w=0;
   for(int d=-radius;d<=radius;d++)
   {
      int q=slot+d;
      if(q<0 || q>=1440) continue;
      int nn,ww,ll,ml; double wr,ex,pf,dd;
      V83Stats(isBuy,q,true,nn,ww,ll,wr,ex,pf,dd,ml);
      n+=nn; w+=ww;
   }
   return n>0?100.0*w/n:0.0;
}

//====================================================================
// NEIGHBOR ROBUSTNESS - PER-OFFSET (spec #5/#6)
//
// Tests EACH offset -MaxNeighborMinutes..-1 and +1..+MaxNeighborMinutes
// individually (not pooled), so a pattern like "edge only exists on
// this exact minute" (isolated) is visible and distinct from
// "edge holds across the whole +/-5 minute area" (strong).
//
// Per offset: 'P' = qualifies (N>=MinSamples & WR>=Min_WR),
//             'F' = has enough data but fails WR,
//             '-' = not enough data (N<MinSamples) or out of range.
//====================================================================

string V83Robustness(bool isBuy,int slot)
{
   int total=2*MaxNeighborMinutes;
   int passed=0;
   string left="",right="";

   for(int d=-MaxNeighborMinutes;d<=MaxNeighborMinutes;d++)
   {
      if(d==0) continue;

      int q=slot+d;
      string tag;

      if(q<0 || q>=1440)
      {
         tag="-";
      }
      else
      {
         int n,w,l,ml; double wr,ex,pf,dd;
         V83Stats(isBuy,q,true,n,w,l,wr,ex,pf,dd,ml);

         if(n<MinSamples)
            tag="-";
         else if(wr>=EffMinWR())
         {
            tag="P";
            passed++;
         }
         else
            tag="F";
      }

      if(d<0) left+=tag; else right+=tag;
   }

   string status;
   if(passed==total)
      status="STRONG";
   else if(passed>=(int)MathCeil(0.6*total))
      status="SUPPORTED";
   else
      status="ISOLATED";

   // left = offsets -MaxNeighborMinutes..-1 (far to near)
   // right = offsets +1..+MaxNeighborMinutes (near to far)
   return StringFormat("ROB %s|%s=%s",left,right,status);
}

//====================================================================
// EFFECTIVE SPREAD FOR COST SENSITIVITY
//
// Uses the REAL average spread observed at this slot's entries when
// available (RealSpreadCount[slot] > 0). Falls back to the manual
// SimulatedSpreadPoints assumption only for slots where no real
// tick ASK was ever captured (should be rare - same fallback logic
// already used for entry simulation).
//====================================================================

double V83EffectiveSpreadPoints(int slot)
{
   if(RealSpreadCount[slot] > 0)
      return RealSpreadSumPoints[slot] / (double)RealSpreadCount[slot];

   return (double)SimulatedSpreadPoints;
}

// Nilai per poin per 1 lot dalam mata uang akun (dari nilai tick simbol).
double V83ValuePerPointPerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   return tickValue * _Point / tickSize;
}

// Komisi dalam R untuk satu trade di slot ini, tanpa bergantung pada lot:
// komisi per lot / (rata-rata SL dalam poin x nilai per poin per lot).
double V83CommissionR(int slot)
{
   double perPoint = V83ValuePerPointPerLot();
   double slPts = V83AvgSLPoints(slot);

   if(perPoint <= 0.0 || slPts <= 0.0)
      return 0.0;

   return CommissionUSDPerLot / (slPts * perPoint);
}

double V83CostNetUSD(bool isBuy,int slot,double stress)
{
   int n,w,l,ml; double wr,ex,pf,dd;
   V83Stats(isBuy,slot,true,n,w,l,wr,ex,pf,dd,ml);

   // Historical W/L already reflects the baseline execution spread.
   // Cost Sensitivity therefore charges only incremental spread above
   // that historical baseline.
   double effSpread=V83EffectiveSpreadPoints(slot);
   double slRefPoints=V83AvgSLPoints(slot);
    double baselineSpreadR=(slRefPoints>0.0)?effSpread/slRefPoints:0.0;
   double stressedSpreadR=baselineSpreadR*stress;
   double incrementalSpreadR=MathMax(0.0,
                                     stressedSpreadR-baselineSpreadR);

   // Commission is not embedded in historical W/L.
   // Dihitung dalam R dari jarak SL dan nilai tick simbol (tanpa lot).
   double commissionR=V83CommissionR(slot);

   double totalAdditionalCostR=
      incrementalSpreadR+
      commissionR*stress;

   return (((double)w*g_RR-(double)l)-n*totalAdditionalCostR)*SimulationRiskUSD;
}

string V83CostStatus(bool isBuy,int slot)
{
   double a=V83CostNetUSD(isBuy,slot,CostStress1);
   double b=V83CostNetUSD(isBuy,slot,CostStress2);
   double c=V83CostNetUSD(isBuy,slot,CostStress3);
   double effSpread=V83EffectiveSpreadPoints(slot);
   string spreadSrc=(RealSpreadCount[slot]>0)?"real":"fallback";
   string head=StringFormat("spread=%.1fpt(%s)",effSpread,spreadSrc);
   if(c>0) return StringFormat("COST=PASS %s %.2f/%.2f/%.2f$",head,a,b,c);
   if(b>0) return StringFormat("COST=SENSITIVE %s %.2f/%.2f/%.2f$",head,a,b,c);
   return StringFormat("COST=FAIL %s %.2f/%.2f/%.2f$",head,a,b,c);
}

string V83ForwardStatus(bool isBuy,int slot)
{
   if(ForwardDays <= 0) return "FWD=OFF";

   int n,w,l,ml; double wr,ex,pf,dd;
   V83Stats(isBuy,slot,false,n,w,l,wr,ex,pf,dd,ml);
   if(n<5) return StringFormat("FWD=INSUFFICIENT N=%d",n);
   return StringFormat("FWD=%s N=%d WR=%.1f%%",wr>=EffFwdWR()?"PASS":"FAIL",n,wr);
}

string V83WeeklyPattern(bool isBuy,int slot,int weeks)
{
   string out="";
   int lastKey,discEndKey,firstKey; V83GetWindowKeys(firstKey,discEndKey,lastKey);
   datetime last=V83DateFromKey(lastKey);
   for(int wk=weeks-1;wk>=0;wk--)
   {
      datetime ws=last-(wk*7+6)*86400;
      datetime we=last-wk*7*86400;
      int ww=0,ll=0;
      int total=isBuy?BuyEntryCount[slot]:SellEntryCount[slot];
      int maxLoop=MathMin(total,MAX_HISTORY_DAYS);
      for(int i=0;i<maxLoop;i++)
      {
         int dk=isBuy?BuyEntryDateKey[slot][i]:SellEntryDateKey[slot][i];
         datetime d=V83DateFromKey(dk);
         if(d<ws || d>we) continue;
         int r=isBuy?BuyHistory[slot][i]:SellHistory[slot][i];
         if(r==RESULT_WIN) ww++; else if(r==RESULT_LOSS) ll++;
      }
      string c="-";
      if(ww+ll>0) c=((double)ww*g_RR>=(double)ll?"W":"L");
      out+=c;
   }
   return out;
}

//====================================================================
// TEMPORAL DIAGNOSTIC (spec #26)
//
// Splits the discovery window in half (by date) and compares WR of
// the first half vs the second half. Diagnostic only - does not
// change Eligibility/Historical Qualification.
//====================================================================

string V83TemporalTag(bool isBuy,int slot)
{
   int firstKey,discEndKey,lastKey;
   V83GetWindowKeys(firstKey,discEndKey,lastKey);

   datetime first = V83DateFromKey(firstKey);
   datetime discEnd = V83DateFromKey(discEndKey);

   if(first==0 || discEnd==0 || discEnd<=first)
      return "TEMP=INSUFFICIENT";

   datetime mid = first + (discEnd-first)/2;

   int n1=0,w1=0,n2=0,w2=0;
   int total=isBuy?BuyEntryCount[slot]:SellEntryCount[slot];
   int maxLoop=MathMin(total,MAX_HISTORY_DAYS);

   for(int i=0;i<maxLoop;i++)
   {
      int dk=isBuy?BuyEntryDateKey[slot][i]:SellEntryDateKey[slot][i];
      if(!V83IsInDiscovery(dk,lastKey)) continue;
      int r=isBuy?BuyHistory[slot][i]:SellHistory[slot][i];
      if(r<0) continue;
      datetime d=V83DateFromKey(dk);
      if(d<=mid) { n1++; if(r==RESULT_WIN) w1++; }
      else       { n2++; if(r==RESULT_WIN) w2++; }
   }

   // Need a minimum sample in EACH half to say anything meaningful.
   if(n1<5 || n2<5)
      return "TEMP=INSUFFICIENT";

   double wr1=100.0*w1/n1;
   double wr2=100.0*w2/n2;
   double delta=wr2-wr1;

   if(delta<=-15.0) return StringFormat("TEMP=DECAYING (%.0f%%->%.0f%%)",wr1,wr2);
   if(delta>=15.0)  return StringFormat("TEMP=IMPROVING (%.0f%%->%.0f%%)",wr1,wr2);
   return StringFormat("TEMP=STABLE (%.0f%%->%.0f%%)",wr1,wr2);
}

//====================================================================
// OUTLIER / ANOMALY DIAGNOSTIC (spec #25)
//
// Flags a HIST-QUALIFIED slot whose WR is a statistical outlier
// relative to the population of ALL HIST-QUALIFIED slots this run
// (z-score vs population mean/std). Diagnostic only - does not
// change Eligibility/Historical Qualification.
//====================================================================

void V83BuildPopulationStats()
{
   if(V83PopReady) return;

   double sum=0.0, sumSq=0.0;
   int cnt=0;

   for(int slot=0;slot<1440;slot++)
   {
      for(int side=0;side<2;side++)
      {
         bool buy=(side==0);
         if(!V83HistoricalQualified(buy,slot)) continue;

         int n,w,l,maxL; double wr,ex,pf,dd;
         V83Stats(buy,slot,true,n,w,l,wr,ex,pf,dd,maxL);

         sum+=wr;
         sumSq+=wr*wr;
         cnt++;
      }
   }

   V83PopCount=cnt;

   if(cnt>=2)
   {
      V83PopMeanWR=sum/cnt;
      double variance=(sumSq/cnt)-(V83PopMeanWR*V83PopMeanWR);
      if(variance<0.0) variance=0.0;
      V83PopStdWR=MathSqrt(variance);
   }
   else
   {
      V83PopMeanWR=0.0;
      V83PopStdWR=0.0;
   }

   V83PopReady=true;
}

string V83OutlierTag(double wr)
{
   V83BuildPopulationStats();

   // Not enough qualified slots this run to judge what is "unusual".
   if(V83PopCount<5 || V83PopStdWR<=0.0)
      return "-";

   double z=(wr-V83PopMeanWR)/V83PopStdWR;

   if(MathAbs(z)>=3.0)
      return StringFormat("OUTLIER (z=%+.1f)",z);

   return "-";
}

//====================================================================
// MONTE CARLO STATUS (spec #23)
//====================================================================

string V83MonteCarloStatus(int n)
{
   if(n<2 || MonteCarloRuns<100)
      return "MC=INSUFFICIENT";

   // Monte Carlo is diagnostic only.
   return "MC=READY";
}

//====================================================================
// $5 FIXED-RISK SIMULATION (spec #21)
//
// Separate from Cost Sensitivity: assumes every trade risks/wins a
// flat SimulationRiskUSD, independent of spread/commission.
//====================================================================

string V83Sim5Text(int n,double exp,int maxL,double dd)
{
   if(n<=0) return "-";

   double expUSD = exp*SimulationRiskUSD;
   double maxLUSD = maxL*SimulationRiskUSD;
   double ddUSD = dd*SimulationRiskUSD;

   return StringFormat(
      "SIM%d Exp%+.2f$ MaxL%.0f$ DD%.0f$",
      (int)SimulationRiskUSD,
      expUSD,
      maxLUSD,
      ddUSD
   );
}

// Gap cluster = 2 bar timeframe (2 menit di M1, 10 menit di M5, dst).
int V83ClusterGapSlots()
{
   int tfMinutes = PeriodSeconds(Timeframe_Test) / 60;

   if(tfMinutes < 1)
      tfMinutes = 1;

   return 2 * tfMinutes;
}


void V83BuildClusterCache()
{
   if(V83ClustersReady && V83ClusterAnalyticsReady)
      return;

   //===============================================================
   // 1) Build cluster membership.
   //===============================================================

   ArrayInitialize(V83BuyClusterID,0);
   ArrayInitialize(V83SellClusterID,0);

   for(int side=0;side<2;side++)
   {
      int cluster=0;
      int prev=-10000;

      for(int slot=0;slot<1440;slot++)
      {
         bool q=V83HistoricalQualified(side==0,slot);

         if(!q)
         {
            if(side==0) V83BuyClusterID[slot]=0;
            else        V83SellClusterID[slot]=0;
            continue;
         }

         if(cluster==0 || slot-prev>V83ClusterGapSlots())
            cluster++;

         if(side==0) V83BuyClusterID[slot]=cluster;
         else        V83SellClusterID[slot]=cluster;

         prev=slot;
      }
   }

   V83ClustersReady=true;

   //===============================================================
   // 2) Build metadata + AGR once.
   //
   // active = at least one member resolved on that Discovery day.
   // full   = every member resolved AND all outcomes are identical.
   //===============================================================

   ArrayInitialize(V83BuyClusterMembers,0);
   ArrayInitialize(V83SellClusterMembers,0);
   ArrayInitialize(V83BuyClusterFirst,-1);
   ArrayInitialize(V83BuyClusterLast,-1);
   ArrayInitialize(V83SellClusterFirst,-1);
   ArrayInitialize(V83SellClusterLast,-1);
   ArrayInitialize(V83BuyClusterAGRValue,0.0);
   ArrayInitialize(V83SellClusterAGRValue,0.0);
   ArrayInitialize(V83BuyClusterActiveDays,0);
   ArrayInitialize(V83BuyClusterFullDays,0);
   ArrayInitialize(V83SellClusterActiveDays,0);
   ArrayInitialize(V83SellClusterFullDays,0);

   int firstKey,discEndKey,lastKey;
   V83GetWindowKeys(firstKey,discEndKey,lastKey);

   for(int side=0;side<2;side++)
   {
      bool isBuy=(side==0);
      int maxClusters=0;

      for(int slot=0;slot<1440;slot++)
      {
         int cid=isBuy?V83BuyClusterID[slot]:V83SellClusterID[slot];

         if(cid>maxClusters)
            maxClusters=cid;

         if(cid<=0)
            continue;

         if(isBuy)
         {
            V83BuyClusterMembers[cid]++;

            if(V83BuyClusterFirst[cid]<0)
               V83BuyClusterFirst[cid]=slot;

            V83BuyClusterLast[cid]=slot;
         }
         else
         {
            V83SellClusterMembers[cid]++;

            if(V83SellClusterFirst[cid]<0)
               V83SellClusterFirst[cid]=slot;

            V83SellClusterLast[cid]=slot;
         }
      }

      for(int cid=1;cid<=maxClusters;cid++)
      {
         int memberCount=isBuy?
            V83BuyClusterMembers[cid]:
            V83SellClusterMembers[cid];

         if(memberCount<=0)
            continue;

         int dayResolved[];
         int dayOutcome[];

         ArrayResize(dayResolved,DiscoveryDays);
         ArrayResize(dayOutcome,DiscoveryDays);
         ArrayInitialize(dayResolved,0);
         ArrayInitialize(dayOutcome,-2); // no resolved member yet

         for(int slot=0;slot<1440;slot++)
         {
            int scid=isBuy?
               V83BuyClusterID[slot]:
               V83SellClusterID[slot];

            if(scid!=cid)
               continue;

            int total=isBuy?
               BuyEntryCount[slot]:
               SellEntryCount[slot];

            int maxLoop=MathMin(total,MAX_HISTORY_DAYS);

            for(int i=0;i<maxLoop;i++)
            {
               int dk=isBuy?
                  BuyEntryDateKey[slot][i]:
                  SellEntryDateKey[slot][i];

               if(!V83IsInDiscovery(dk,lastKey))
                  continue;

               int dayIndex=V83DayDiff(dk,firstKey);

               if(dayIndex<0 || dayIndex>=DiscoveryDays)
                  continue;

               int r=isBuy?
                  BuyHistory[slot][i]:
                  SellHistory[slot][i];

               if(r<0)
                  continue;

               dayResolved[dayIndex]++;

               if(dayOutcome[dayIndex]==-2)
                  dayOutcome[dayIndex]=r;
               else if(dayOutcome[dayIndex]!=r)
                  dayOutcome[dayIndex]=-1; // mixed W/L
            }
         }

         int active=0;
         int full=0;

         for(int d=0;d<DiscoveryDays;d++)
         {
            if(dayResolved[d]<=0)
               continue;

            active++;

            if(dayResolved[d]==memberCount &&
               dayOutcome[d]>=0)
               full++;
         }

         double agr=(active>0)?
            100.0*full/active:
            0.0;

         if(isBuy)
         {
            V83BuyClusterActiveDays[cid]=active;
            V83BuyClusterFullDays[cid]=full;
            V83BuyClusterAGRValue[cid]=agr;
         }
         else
         {
            V83SellClusterActiveDays[cid]=active;
            V83SellClusterFullDays[cid]=full;
            V83SellClusterAGRValue[cid]=agr;
         }
      }
   }

   V83ClusterAnalyticsReady=true;
}

int V83ClusterID(bool isBuy,int slot)
{
   V83BuildClusterCache();
   return isBuy ? V83BuyClusterID[slot] : V83SellClusterID[slot];
}

int V83ClusterMemberCount(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return 0;

   return isBuy?
      V83BuyClusterMembers[cid]:
      V83SellClusterMembers[cid];
}

int V83ClusterFirstSlot(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return -1;

   return isBuy?
      V83BuyClusterFirst[cid]:
      V83SellClusterFirst[cid];
}

int V83ClusterLastSlot(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return -1;

   return isBuy?
      V83BuyClusterLast[cid]:
      V83SellClusterLast[cid];
}

int V83ClusterActiveDays(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return 0;

   return isBuy?
      V83BuyClusterActiveDays[cid]:
      V83SellClusterActiveDays[cid];
}

int V83ClusterFullDays(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return 0;

   return isBuy?
      V83BuyClusterFullDays[cid]:
      V83SellClusterFullDays[cid];
}

string V83RedundancyLevel(double agr,int memberCount)
{
   if(memberCount<=1) return "LOW";
   if(agr>=80.0) return "HIGH";
   if(agr>=50.0) return "MEDIUM";
   return "LOW";
}

double V83ClusterAGR(bool isBuy,int slot)
{
   V83BuildClusterCache();

   int cid=isBuy?
      V83BuyClusterID[slot]:
      V83SellClusterID[slot];

   if(cid<=0)
      return 0.0;

   // Single-member cluster with no active resolved day is 0%.
   return isBuy?
      V83BuyClusterAGRValue[cid]:
      V83SellClusterAGRValue[cid];
}

//====================================================================
// TAHAP 7 FORMATTING HELPERS
//====================================================================

// Circled numbers ①..⑳ (U+2460..U+2473). Beyond 20, falls back to "(n)".
string V83CircledNumber(int n)
{
   if(n>=1 && n<=20)
      return ShortToString((ushort)(0x2460 + (n-1)));
   return StringFormat("(%d)",n);
}

// Formats like the spec examples: "+.438" / "-.123" (no leading 0),
// but "+1.438" stays as-is when |v|>=1.
string V83FmtExpNoLeadZero(double v)
{
   string s=StringFormat("%+.3f",v);
   if(StringLen(s)>=2 && StringGetCharacter(s,1)=='0')
      s=StringSubstr(s,0,1)+StringSubstr(s,2);
   return s;
}

// FIX7: historical Discovery SEQ builder removed from report path.

void V83MonteCarlo(bool isBuy,int slot,double &p95DD)
{
   p95DD=0.0;

   double arr[];
   int n=0;

   int total=isBuy?
      BuyEntryCount[slot]:
      SellEntryCount[slot];

   int maxLoop=MathMin(total,MAX_HISTORY_DAYS);

   int lastKey,discEndKey,firstKey;
   V83GetWindowKeys(firstKey,discEndKey,lastKey);

   ArrayResize(arr,maxLoop);

   // Monte Carlo uses resolved Discovery W/L only.
   for(int i=0;i<maxLoop;i++)
   {
      int dk=isBuy?
         BuyEntryDateKey[slot][i]:
         SellEntryDateKey[slot][i];

      if(!V83IsInDiscovery(dk,lastKey))
         continue;

      int r=isBuy?
         BuyHistory[slot][i]:
         SellHistory[slot][i];

      if(r>=0)
         arr[n++]=(r==RESULT_WIN?g_RR:-1.0);
   }

   if(n<2 || MonteCarloRuns<100)
      return;

   double dds[];
   ArrayResize(dds,MonteCarloRuns);

   MathSrand(MonteCarloSeed+slot+(isBuy?10000:20000));

   for(int run=0;run<MonteCarloRuns;run++)
   {
      // Proper Fisher-Yates shuffle.
      for(int i=n-1;i>0;i--)
      {
         int j=MathRand()%(i+1);
         double t=arr[i];
         arr[i]=arr[j];
         arr[j]=t;
      }

      double eq=0.0;
      double peak=0.0;
      double mdd=0.0;

      for(int i=0;i<n;i++)
      {
         eq+=arr[i];

         if(eq>peak)
            peak=eq;

         if(peak-eq>mdd)
            mdd=peak-eq;
      }

      dds[run]=mdd;
   }

   ArraySort(dds);

   int idx95=(int)MathFloor(0.95*(MonteCarloRuns-1));
   p95DD=dds[idx95];
}

void V83PrintMultipleTesting()
{
   int tests=2880;
   int histQ=0;
   for(int s0=0;s0<1440;s0++)
   {
      if(V83HistoricalQualified(true,s0)) histQ++;
      if(V83HistoricalQualified(false,s0)) histQ++;
   }
   double alpha=0.05/tests;
   Print(StringFormat("MULTIPLE-TESTING | tests=%d | hist-qualified=%d | Bonferroni alpha=%.8f | diagnostic-only",
                      tests,histQ,alpha));
}

//====================================================================
// DATA-INTEGRITY DIAGNOSTIC (spec #27)
//
// Reports completeness/consistency of the underlying tick/bar data
// this run relied on. Diagnostic only - flags issues, does not
// reject or alter any slot's qualification.
//====================================================================

void V83PrintDataIntegrity()
{
   long unresolvedAtEnd = OpenTradeCount;

   Print(StringFormat(
      "DATA-INTEGRITY | entries=%d resolved=%d unresolved-at-end=%d | "
      "same-bar-m1-resolved=%d same-bar-tick-resolved=%d same-bar-fallback-loss=%d | "
      "history-overflow(buy=%d sell=%d) | diagnostic-only",
      (int)TotalEntries,
      (int)TotalResolved,
      (int)unresolvedAtEnd,
      (int)SameBarM1Resolved,
      (int)SameBarTickResolved,
      (int)SameBarFallbackLoss,
      (int)HistoryOverflowBuy,
      (int)HistoryOverflowSell
   ));

   if(SameBarFallbackLoss>0)
      Print("DATA-INTEGRITY WARNING: some same-bar TP/SL hits could not be resolved by tick data "
            "and were counted as loss (see same-bar-fallback-loss above).");

   if(HistoryOverflowBuy>0 || HistoryOverflowSell>0)
      Print("DATA-INTEGRITY WARNING: MAX_HISTORY_DAYS exceeded for at least one slot; "
            "oldest entries beyond the cap were not recorded.");
}

//====================================================================
// TIER 1 - QUALIFIED SUMMARY (spec section 11, FINAL LOCKED format)
//
// Only HIST-QUALIFIED slots. This is the report meant for normal,
// day-to-day scan runs.
//====================================================================

void V83PrintQualifiedSummary()
{
   if(!ShowQualifiedSummary) return;

   Print("");
   Print("====================================================================================================================");
   Print("                           QUALIFIED SLOTS (HIST-QUALIFIED)");
   Print("====================================================================================================================");

   int shown=0;

   for(int slot=0;slot<1440;slot++)
   {
      for(int side=0;side<2;side++)
      {
         bool buy=(side==0);
         if(!V83HistoricalQualified(buy,slot)) continue;

         int n,w,l,maxL; double wr,ex,pf,dd;
         V83Stats(buy,slot,true,n,w,l,wr,ex,pf,dd,maxL);
         double cil=CI_Lower(w,n), ciu=CI_Upper(w,n);

         shown++;
         Print(StringFormat("%s %02d:%02d %s",
                            V83CircledNumber(shown),slot/60,slot%60,buy?"BUY":"SELL"));

         Print(StringFormat("N%d W%d L%d WR%.2f Exp%s PF%.2f DD%.0fR MaxL%d CI%.0f-%.0f",
                            n,w,l,wr,V83FmtExpNoLeadZero(ex),pf,dd,maxL,cil,ciu));
         // FIX7: Discovery SEQ is intentionally not printed.
         string robLine=V83Robustness(buy,slot);

         if(ForwardDays > 0)
            robLine+=" | "+V83ForwardStatus(buy,slot);

         Print(robLine);

         Print(V83CostStatus(buy,slot));

         int cid=V83ClusterID(buy,slot);
         double agr=V83ClusterAGR(buy,slot);
         int members=V83ClusterMemberCount(buy,slot);
         string red=V83RedundancyLevel(agr,members);

         if(cid>0)
         {
            int spanFirst=V83ClusterFirstSlot(buy,slot);
            int spanLast=V83ClusterLastSlot(buy,slot);

            Print(StringFormat("CL C%d %02d:%02d-%02d:%02d (%d) | AGR%.1f%% | RED=%s",
                               cid,spanFirst/60,spanFirst%60,spanLast/60,spanLast%60,
                               members,agr,red));
         }
         else
         {
            Print("CL - | AGR- | RED=LOW");
         }

         double mcdd; V83MonteCarlo(buy,slot,mcdd);
         Print(V83MonteCarloStatus(n)+" MC95DD="+(n>=2?DoubleToString(mcdd,1):"-")+" | "+V83Sim5Text(n,ex,maxL,dd));

         // Optional warning lines - only printed when there's something
         // to flag. A normal/stable slot prints none of these.
         string outlierText=V83OutlierTag(wr);
         if(outlierText!="-")
            Print("WARN "+outlierText);

         string temporalText=V83TemporalTag(buy,slot);
         if(StringFind(temporalText,"DECAYING")>=0 || StringFind(temporalText,"IMPROVING")>=0)
            Print("WARN "+temporalText);

         Print("--------------------------------------------------------------------------------------------------------------------");
      }
   }

   if(shown==0)
      Print("(no HIST-QUALIFIED slot this run)");

   Print("====================================================================================================================");
}

//====================================================================
// TIER 3 - NOT ELIGIBLE (count only, no per-slot list)
//====================================================================

void V83PrintNotEligibleCount()
{
   if(!ShowNotEligibleCount) return;

   int count=0;

   for(int slot=0;slot<1440;slot++)
   {
      for(int side=0;side<2;side++)
      {
         bool buy=(side==0);
         int total=buy?BuyEntryCount[slot]:SellEntryCount[slot];
         if(total<MinSamples) count++;
      }
   }

   Print("");
   Print(StringFormat("NOT ELIGIBLE - %d slot-sisi (N < MinSamples=%d)",count,MinSamples));
}

void V83PrintResearchReport()
{
   if(!ShowV83ResearchReport) return;
   int firstKey,discEndKey,lastKey; V83GetWindowKeys(firstKey,discEndKey,lastKey);
   V83ClustersReady=false;
   V83BuildClusterCache();
   V83PopReady=false;
   V83BuildPopulationStats();

   Print("");
   Print("====================================================================================================================");
   Print("                           AURUM EDGE SCANNER V8.37 RESEARCH BUILD FIX7");
   Print("====================================================================================================================");
   Print("CORE: V8.2.1 trade/execution lifecycle preserved; V8.3 adds analysis/validation only.");
   Print("WINDOW: rolling ",DiscoveryDays,"D discovery + ",ForwardDays,"D fresh forward evidence.");
   Print("NO TIMEOUT: TRUE | EXIT: TP/SL ONLY | BUY/SELL INDEPENDENT | JOURNAL ONLY");
   Print("DATES: ",firstKey," -> discovery end ",discEndKey," -> forward end ",lastKey);
   Print("SLTP: FIXED SL=",SL_Points," TP=",TP_Points," RR=",DoubleToString(g_RR,4),
         " BE-WR=",DoubleToString(BreakevenWR(),2),"%");
   Print("QUALIFICATION: N>=",MinSamples," WR>=",DoubleToString(EffMinWR(),2),
         "% PF>=",DoubleToString(Min_PF,2)," Exp>=",DoubleToString(Min_Expectancy,3),
         " DD<=",DoubleToString(MaxSlotDD_R,2),"R");
   Print("NEIGHBOR: +/-1..+/-",MaxNeighborMinutes,"m | CLUSTER: <=2m diagnostic-only | MC runs=",MonteCarloRuns);
   Print("COST: spread=",SimulatedSpreadPoints," pts commission=",DoubleToString(CommissionUSDPerLot,2),
         " USD/lot | $5 risk=",DoubleToString(SimulationRiskUSD,2));
   Print("FILTER: ",ShowOnlyQualified ? "HIST-QUALIFIED ONLY" : "ALL SIDES");
   Print("--------------------------------------------------------------------------------------------------------------------");
   Print("TIME SIDE | STATUS | HIST N WR PF EXP DD MaxL CI | ROB | FWD | COST | CLUSTER/AGR/RED | MC | OUTLIER | TEMPORAL | SIM5 | WEEKLY(12)");
   Print("--------------------------------------------------------------------------------------------------------------------");

   for(int slot=0;slot<1440;slot++)
   {
      for(int side=0;side<2;side++)
      {
         bool buy=(side==0);
         int n,w,l,maxL; double wr,ex,pf,dd;
         V83Stats(buy,slot,true,n,w,l,wr,ex,pf,dd,maxL);
         bool histQ=V83HistoricalQualified(buy,slot);
         if(ShowOnlyQualified && !histQ) continue;
         if(n<=0 && !histQ) continue;

         double cil=CI_Lower(w,n), ciu=CI_Upper(w,n);
         string status;
         if(n<MinSamples) status="NOT ELIGIBLE";
         else if(histQ) status="HIST-QUALIFIED";
         else status="ELIGIBLE - NOT HIST-QUALIFIED";

         double mcdd; V83MonteCarlo(buy,slot,mcdd);
         int cid=V83ClusterID(buy,slot);
         double agr=V83ClusterAGR(buy,slot);
         int members=V83ClusterMemberCount(buy,slot);
         string red=V83RedundancyLevel(agr,members);
         string ts=StringFormat("%02d:%02d %s",slot/60,slot%60,buy?"BUY":"SELL");
         string clusterText=(cid>0 ? StringFormat("C%d/%.1f%%/%s",cid,agr,red) : "-");
          bool mcOk=(MonteCarloRuns>=100 && n>=2);
          string mcText=(mcOk ? StringFormat("MC=READY MC95DD=%.1f",mcdd) : "MC=INSUFFICIENT");
         string outlierText=(histQ ? V83OutlierTag(wr) : "-");
         string temporalText=(histQ ? V83TemporalTag(buy,slot) : "-");
         string sim5Text=V83Sim5Text(n,ex,maxL,dd);
         Print(StringFormat("%s | %s | N=%d WR=%.1f PF=%.2f Exp=%+.3f DD=%.1f MaxL=%d CI=[%.1f-%.1f] | %s | %s | %s | %s | %s | %s | %s | %s | W=%s",
                            ts,status,n,wr,pf,ex,dd,maxL,cil,ciu,
                            V83Robustness(buy,slot),V83ForwardStatus(buy,slot),
                            V83CostStatus(buy,slot),clusterText,mcText,
                            outlierText,temporalText,sim5Text,
                            V83WeeklyPattern(buy,slot,WEEKLY_WEEKS)));

      }
   }
   Print("====================================================================================================================");
}

//====================================================================
// FINAL REPORT
//====================================================================

void PrintFinalReport()
{
   // FIX7: build cluster analytics once before any report tier.
   V83BuildClusterCache();

   // Tier 1: compact HIST-QUALIFIED summary - default view for normal scans.
   V83PrintQualifiedSummary();

   // Tier 3: not-eligible count only (cheap, on by default for context).
   V83PrintNotEligibleCount();

   // Old wide research table - off by default, for deep debugging.
   if(ShowResearchTable)
      V83PrintResearchReport();

   // Footer - always printed once, regardless of which tiers above ran.
   Print("");
   V83PrintDataIntegrity();
   V83PrintMultipleTesting();
}

//====================================================================
// V8.4 LIVE MODE - WARM-UP, SELECTION, PANEL (tanpa order)
//====================================================================

//--------------------------------------------------------------------
// Entry hipotetis dari bar historis (dipakai saat warm-up).
// BUY = open + spread bar, SELL = open. Aturan satu entry per slot
// per hari sama dengan CreateEntriesForCurrentBar().
//--------------------------------------------------------------------

void CreateEntriesFromBar(const MqlRates &bar)
{
   if(bar.open <= 0.0)
      return;

   double spreadPts = (bar.spread > 0) ? (double)bar.spread
                                       : (double)SimulatedSpreadPoints;

   double slip = EntrySlippagePoints * _Point;

   double buyEntry  = bar.open + spreadPts * _Point + slip;
   double sellEntry = bar.open - slip;

   int slot    = GetWIBIndex(bar.time);
   int dateKey = GetWIBDateKey(bar.time);

   if(bar.spread > 0)
   {
      RealSpreadSumPoints[slot] += (double)bar.spread;
      RealSpreadCount[slot]++;
   }

   if(dateKey != CurrentWIBDateKey)
   {
      ArrayInitialize(TradedBuyThisMinute,false);
      ArrayInitialize(TradedSellThisMinute,false);
      CurrentWIBDateKey = dateKey;
   }

   if(!TradedBuyThisMinute[slot])
   {
      TradedBuyThisMinute[slot] = true;
      AddTrade(true,slot,bar.time,(long)bar.time * 1000,buyEntry);
   }

   if(!TradedSellThisMinute[slot])
   {
      TradedSellThisMinute[slot] = true;
      AddTrade(false,slot,bar.time,(long)bar.time * 1000,sellEntry);
   }
}

//--------------------------------------------------------------------
// Warm-up: putar ulang riwayat (DiscoveryDays + ForwardDays hari)
// dengan mesin yang sama dengan streaming. Return true jika riwayat
// cukup menutup jendela.
//--------------------------------------------------------------------

bool RunWarmup()
{
   datetime now = TimeCurrent();

   datetime from = now - (datetime)((long)(DiscoveryDays + ForwardDays + 1)
                                    * 86400);

MqlRates bars[];
   int copied = -1;

   for(int attempt = 0; attempt < 5; attempt++)
   {
      ResetLastError();
      copied = CopyRates(_Symbol,Timeframe_Test,from,now,bars);

      if(copied > 0)
         break;

      Sleep(1000);
   }

   if(copied <= 0)
   {
      Print("WARM-UP ERROR: CopyRates gagal. Error=",GetLastError());
      return false;
   }

   // Buang bar yang sedang berjalan.
   datetime curBar = iTime(_Symbol,Timeframe_Test,0);
   int total = copied;

   if(total > 0 && bars[total-1].time >= curBar)
      total--;

   if(total < 2)
   {
      Print("WARM-UP ERROR: bar historis terlalu sedikit.");
      return false;
   }

   Print("WARM-UP START: ",total," bar ",EnumToString(Timeframe_Test),
         " dari ",TimeToString(bars[0].time),
         " sampai ",TimeToString(bars[total-1].time));

   uint t0 = GetTickCount();

   for(int k = 0; k < total; k++)
   {
      if(k > 0)
         ResolveOpenTrades(bars[k-1].time,bars[k-1].high,bars[k-1].low);

      CreateEntriesFromBar(bars[k]);

      if(ShowPanel && (k % 20000) == 0)
         Comment(StringFormat("AURUM EDGE warm-up %d / %d bar",k,total));
   }

   // Serahkan ke alur streaming: bar tertutup terakhir akan
   // diselesaikan oleh ProcessPreviousClosedBar() pada bar berikutnya.
   LastBarTime = bars[total-1].time;
   LastProcessedClosedBar = bars[total-2].time;

   g_WarmupBars = total;
   g_WarmupFirstBar = bars[0].time;
   g_WarmupSpanDays = (int)((bars[total-1].time - bars[0].time) / 86400);

   Print("WARM-UP DONE: ",(GetTickCount() - t0) / 1000.0," detik | entries=",
         (long)TotalEntries," resolved=",(long)TotalResolved,
         " open=",OpenTradeCount);

   // Toleransi 3 hari untuk akhir pekan di awal rentang.
   return (g_WarmupSpanDays >= DiscoveryDays + ForwardDays - 3);
}

//--------------------------------------------------------------------
// Seleksi
//--------------------------------------------------------------------

bool InExecWindow(int slot)
{
   // slot = menit sejak 00:00 pada jam slot (jam broker jika
   // ServerToWIB_Hours = 0).
   return (slot >= ExecStartMinute && slot < ExecEndMinute);
}

// Info saja: porsi trade (selesai) yang baru selesai setelah batas
// akhir jendela eksekusi.
double V83CutPct(bool isBuy,int slot)
{
   int total = isBuy ? BuyEntryCount[slot] : SellEntryCount[slot];
   int maxLoop = MathMin(total,MAX_HISTORY_DAYS);

   int firstKey,discEndKey,lastKey;
   V83GetWindowKeys(firstKey,discEndKey,lastKey);

   int cnt = 0;
   int cut = 0;

   for(int i = 0; i < maxLoop; i++)
   {
      int dk = isBuy ? BuyEntryDateKey[slot][i] : SellEntryDateKey[slot][i];

      if(!V83IsInDiscovery(dk,lastKey))
         continue;

      int r = isBuy ? BuyHistory[slot][i] : SellHistory[slot][i];

      if(r < 0)
         continue;

      int d = isBuy ? BuyDelaySec[slot][i] : SellDelaySec[slot][i];

      if(d < 0)
         continue;

      cnt++;

      if(slot * 60 + d > ExecEndMinute * 60)
         cut++;
   }

   return (cnt > 0) ? 100.0 * cut / cnt : 0.0;
}

// stage: 0 = tidak lolos, 1 = lolos (kualifikasi V8.37 + di dalam jendela)
bool SelEligible(bool buy,int slot,double &lo,double &ex,int &n,int &stage)
{
   stage = 0;
   lo = 0.0;
   ex = 0.0;
   n = 0;

   if(!InExecWindow(slot))
      return false;

   if(!V83HistoricalQualified(buy,slot))
      return false;

   int w,l,maxL;
   double wr,pf,dd;

   V83Stats(buy,slot,true,n,w,l,wr,ex,pf,dd,maxL);

   // Batas bawah CI hanya untuk memilih wakil terbaik di area,
   // bukan filter.
   lo = CI_Lower(w,n);

   stage = 1;
   return true;
}

void AddSelRow(bool buy,int slot,int clFirst,int clLast,int clMembers)
{
   int n,w,l,maxL;
   double wr,ex,pf,dd;

   V83Stats(buy,slot,true,n,w,l,wr,ex,pf,dd,maxL);

   SelRow r;

   r.slot = slot;
   r.isBuy = buy;
   r.n = n;
   r.w = w;
   r.l = l;
   r.maxL = maxL;
   r.wr = wr;
   r.ciLow = CI_Lower(w,n);
   r.pf = pf;
   r.ex = ex;
   r.dd = dd;
   r.clFirst = clFirst;
   r.clLast = clLast;
   r.clMembers = clMembers;
   r.cutPct = V83CutPct(buy,slot);

   int sz = ArraySize(g_Sel);
   ArrayResize(g_Sel,sz + 1);
   g_Sel[sz] = r;
}

void PrintSelectionJournal()
{
   Print("============================================================");
   Print(StringFormat(
      "SELECTION day=%d | TF=%s | FIXED SL%d/TP%d RR=%.2f BE-WR=%.2f%% | disc=%dD fwd=%dD | exec %02d:%02d-%02d:%02d",
      g_SelectionDayKey,EnumToString(Timeframe_Test),
      SL_Points,TP_Points,g_RR,BreakevenWR(),
      DiscoveryDays,ForwardDays,
      ExecStartMinute/60,ExecStartMinute%60,
      ExecEndMinute/60,ExecEndMinute%60));

   Print(StringFormat(
      "FUNNEL in-window qualified=%d | areas=%d | selected=%d",
      g_FunnelQual,g_FunnelClusters,g_SelCount));

   for(int i = 0; i < g_SelCount; i++)
   {
      SelRow r = g_Sel[i];

      Print(StringFormat(
         "SEL %02d:%02d %s | N%d W%d L%d WR%.1f CI-low%.1f (BE%.1f) PF%.2f Exp%s DD%.0fR MaxL%d | %s | AREA %02d:%02d-%02d:%02d (%d) | CUT%.1f%%",
         r.slot/60,r.slot%60,r.isBuy ? "BUY" : "SELL",
         r.n,r.w,r.l,r.wr,r.ciLow,BreakevenWR(),r.pf,
         V83FmtExpNoLeadZero(r.ex),r.dd,r.maxL,
         V83CostStatus(r.isBuy,r.slot),
         r.clFirst/60,r.clFirst%60,r.clLast/60,r.clLast%60,
         r.clMembers,r.cutPct));
   }

   if(g_SelCount == 0)
      Print("SEL none -> NO TRADE hari ini");

   Print("============================================================");
}

void BuildSelection()
{
   ArrayResize(g_Sel,0);
   g_SelCount = 0;

   g_FunnelQual = 0;
   g_FunnelClusters = 0;

   int gap = V83ClusterGapSlots();

   for(int side = 0; side < 2; side++)
   {
      bool buy = (side == 0);

      int    clMembers = 0;
      int    clFirst = -1;
      int    clLast = -1;
      int    best = -1;
      double bestLo = 0.0;
      double bestEx = 0.0;
      int    bestN = 0;

      for(int slot = 0; slot < 1440; slot++)
      {
         double lo;
         double ex;
         int n;
         int stage;

         bool ok = SelEligible(buy,slot,lo,ex,n,stage);

         if(stage >= 1) g_FunnelQual++;

         if(!ok)
            continue;

         if(clMembers > 0 && slot - clLast > gap)
         {
            AddSelRow(buy,best,clFirst,clLast,clMembers);
            g_FunnelClusters++;
            clMembers = 0;
            best = -1;
         }

         if(clMembers == 0)
            clFirst = slot;

         clLast = slot;
         clMembers++;

         // Wakil terbaik: batas bawah CI, lalu Exp, lalu N.
         bool better = false;

         if(best < 0)
            better = true;
         else if(lo > bestLo + 1e-9)
            better = true;
         else if(MathAbs(lo - bestLo) <= 1e-9 && ex > bestEx + 1e-9)
            better = true;
         else if(MathAbs(lo - bestLo) <= 1e-9 &&
                 MathAbs(ex - bestEx) <= 1e-9 && n > bestN)
            better = true;

         if(better)
         {
            best = slot;
            bestLo = lo;
            bestEx = ex;
            bestN = n;
         }
      }

      if(clMembers > 0)
      {
         AddSelRow(buy,best,clFirst,clLast,clMembers);
         g_FunnelClusters++;
      }
   }

   // Urutkan menurut slot.
   int cnt = ArraySize(g_Sel);

   for(int i = 1; i < cnt; i++)
   {
      SelRow key = g_Sel[i];
      int j = i - 1;

      while(j >= 0 && g_Sel[j].slot > key.slot)
      {
         g_Sel[j+1] = g_Sel[j];
         j--;
      }

      g_Sel[j+1] = key;
   }

   g_SelCount = cnt;

   PrintSelectionJournal();
}

//--------------------------------------------------------------------
// DRY-RUN EXECUTION (2b-1): mesin keputusan eksekusi tanpa order.
// Hasil dalam R kotor (tanpa komisi), satuan yang sama dengan scan.
// Keputusan dan hasil dicatat di Journal; panel menampilkan ringkasan.
//--------------------------------------------------------------------

void DryRunNewDay(int key)
{
   g_DryDayKey = key;
   g_DryDayTrades = 0;
   g_DryDayWins = 0;
   g_DryDayLosses = 0;
   g_DryDayForced = 0;
   g_DryDayR = 0.0;
   g_DryConsec = 0;
   g_DryStopped = false;
   g_DryStopReason = "";
}

void DryClose(double exitPrice,string reason)
{
   if(!g_Dry.active)
      return;

   double slDist = g_Dry.slPts * _Point;
   double r = 0.0;

   if(reason == "TP")
      r = g_Dry.tpPts / g_Dry.slPts;
   else if(reason == "SL")
      r = -1.0;
   else if(slDist > 0.0)
      r = (g_Dry.isBuy ? (exitPrice - g_Dry.entryPrice)
                       : (g_Dry.entryPrice - exitPrice)) / slDist;

   bool win = (r > 0.0);

   g_DryDayTrades++;
   g_DryTotTrades++;

   if(win)
   {
      g_DryDayWins++;
      g_DryTotWins++;
      g_DryConsec = 0;
   }
   else
   {
      g_DryDayLosses++;
      g_DryTotLosses++;
      g_DryConsec++;
   }

   if(reason == "FORCED")
   {
      g_DryDayForced++;
      g_DryTotForced++;
   }

   g_DryDayR += r;
   g_DryTotR += r;
   g_DryTotPredR += g_Dry.predExp;

   if(g_DryTotR > g_DryPeakR)
      g_DryPeakR = g_DryTotR;

   if(g_DryPeakR - g_DryTotR > g_DryMaxDDR)
      g_DryMaxDDR = g_DryPeakR - g_DryTotR;

   Print(StringFormat(
      "DRY CLOSE %s %02d:%02d | %s R=%+.2f (komisi~%.3fR) | hari: %d trade R=%+.2f kalah-beruntun=%d | total R=%+.2f vs prediksi scan %+.2f",
      g_Dry.isBuy ? "BUY" : "SELL",g_Dry.slot/60,g_Dry.slot%60,
      reason,r,V83CommissionR(g_Dry.slot),
      g_DryDayTrades,g_DryDayR,g_DryConsec,
      g_DryTotR,g_DryTotPredR));

   if(!g_DryStopped && ExecMaxDailyLossR > 0.0 &&
      g_DryDayR <= -ExecMaxDailyLossR)
   {
      g_DryStopped = true;
      g_DryStopReason = "BATAS RUGI HARIAN";
      Print("DRY STOP hari ini: batas rugi harian tercapai (",
            DoubleToString(g_DryDayR,2),"R)");
   }

   if(!g_DryStopped && ExecMaxConsecLosses > 0 &&
      g_DryConsec >= ExecMaxConsecLosses)
   {
      g_DryStopped = true;
      g_DryStopReason = "RENTETAN KALAH";
      Print("DRY STOP hari ini: ",g_DryConsec," trade kalah beruntun");
   }

   g_Dry.active = false;
}

void DryRunTick(datetime now)
{
   int key = GetWIBDateKey(now);

   if(key != g_DryDayKey)
      DryRunNewDay(key);

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   MqlDateTime dt;
   TimeToStruct(ToWIB(now),dt);

   int nowMin = dt.hour * 60 + dt.min;

   //--- kelola posisi dry-run
   if(g_Dry.active)
   {
      if(nowMin >= ExecEndMinute)
      {
         DryClose(g_Dry.isBuy ? tick.bid : tick.ask,"FORCED");
      }
      else if(g_Dry.isBuy)
      {
         if(tick.bid >= g_Dry.tp)
            DryClose(g_Dry.tp,"TP");
         else if(tick.bid <= g_Dry.sl)
            DryClose(g_Dry.sl,"SL");
      }
      else
      {
         if(tick.ask <= g_Dry.tp)
            DryClose(g_Dry.tp,"TP");
         else if(tick.ask >= g_Dry.sl)
            DryClose(g_Dry.sl,"SL");
      }
   }

   //--- bar baru -> kandidat entry
   datetime bar0 = iTime(_Symbol,Timeframe_Test,0);

   if(bar0 <= 0 || bar0 == g_DryLastBar)
      return;

   g_DryLastBar = bar0;

   int barSlot = GetWIBIndex(bar0);

   int pick = -1;
   int cnt = 0;

   for(int i = 0; i < g_SelCount; i++)
   {
      if(g_Sel[i].slot != barSlot)
         continue;

      cnt++;

      if(pick < 0 || g_Sel[i].ciLow > g_Sel[pick].ciLow)
         pick = i;
   }

   if(pick < 0)
      return;

   SelRow r = g_Sel[pick];

   string tag = StringFormat("%02d:%02d %s",
                             r.slot/60,r.slot%60,r.isBuy ? "BUY" : "SELL");

   if(cnt > 1)
      Print("DRY NOTE ",tag,": BUY dan SELL terpilih di slot yang sama, ",
            "dipilih batas bawah CI tertinggi");

   int lateSec = (int)(now - bar0);

   if(lateSec > ExecMaxEntryDelaySec)
   {
      Print("DRY SKIP ",tag," | terlambat ",lateSec," detik");
      return;
   }

   if(!InExecWindow(r.slot))
   {
      Print("DRY SKIP ",tag," | di luar jendela eksekusi");
      return;
   }

   if(g_DryStopped)
   {
      Print("DRY SKIP ",tag," | berhenti hari ini: ",g_DryStopReason);
      return;
   }

   if(g_Dry.active)
   {
      Print("DRY SKIP ",tag," | posisi dry-run masih terbuka");
      return;
   }

   double spreadPts = (tick.ask - tick.bid) / _Point;

   if(ExecMaxSpreadPoints > 0 && spreadPts > (double)ExecMaxSpreadPoints)
   {
      Print("DRY SKIP ",tag," | spread ",DoubleToString(spreadPts,1),
            " > ",ExecMaxSpreadPoints);
      return;
   }

   double slPts;
   double tpPts;

   if(!GetSLTPPoints(slPts,tpPts,bar0))
   {
      Print("DRY SKIP ",tag," | ATR belum siap");
      return;
   }

   double entry = r.isBuy ? tick.ask : tick.bid;

   g_Dry.active = true;
   g_Dry.isBuy = r.isBuy;
   g_Dry.slot = r.slot;
   g_Dry.entryTime = now;
   g_Dry.entryPrice = entry;
   g_Dry.slPts = slPts;
   g_Dry.tpPts = tpPts;
   g_Dry.predWR = r.wr;
   g_Dry.predExp = r.ex;
   g_Dry.predCILow = r.ciLow;

   if(r.isBuy)
   {
      g_Dry.sl = NormalizeDouble(entry - slPts * _Point,_Digits);
      g_Dry.tp = NormalizeDouble(entry + tpPts * _Point,_Digits);
   }
   else
   {
      g_Dry.sl = NormalizeDouble(entry + slPts * _Point,_Digits);
      g_Dry.tp = NormalizeDouble(entry - tpPts * _Point,_Digits);
   }

   Print(StringFormat(
      "DRY OPEN %s | entry %s SL %s TP %s (%.0f/%.0f pts) spread %.1f | prediksi: WR%.1f CI-low%.1f Exp%s",
      tag,
      DoubleToString(entry,_Digits),
      DoubleToString(g_Dry.sl,_Digits),
      DoubleToString(g_Dry.tp,_Digits),
      slPts,tpPts,spreadPts,
      r.wr,r.ciLow,V83FmtExpNoLeadZero(r.ex)));
}

string DryPanelText()
{
   string t = StringFormat(
      "DRY-RUN hari ini: %d trade | W %d L %d F %d | R %+.2f | kalah-beruntun %d | %s\n",
      g_DryDayTrades,g_DryDayWins,g_DryDayLosses,g_DryDayForced,
      g_DryDayR,g_DryConsec,
      g_DryStopped ? ("STOP: " + g_DryStopReason) : "AKTIF");

   t += StringFormat(
      "DRY-RUN total: %d trade | W %d L %d F %d | R %+.2f (prediksi scan %+.2f) | DD %.2fR\n",
      g_DryTotTrades,g_DryTotWins,g_DryTotLosses,g_DryTotForced,
      g_DryTotR,g_DryTotPredR,g_DryMaxDDR);

   if(g_Dry.active)
   {
      MqlTick tick;
      double floatR = 0.0;

      if(SymbolInfoTick(_Symbol,tick) && g_Dry.slPts > 0.0)
      {
         floatR = (g_Dry.isBuy ? (tick.bid - g_Dry.entryPrice)
                               : (g_Dry.entryPrice - tick.ask))
                  / (g_Dry.slPts * _Point);
      }

      t += StringFormat(
         "POSISI dry-run: %s slot %02d:%02d | entry %s SL %s TP %s | R mengambang %+.2f\n",
         g_Dry.isBuy ? "BUY" : "SELL",g_Dry.slot/60,g_Dry.slot%60,
         DoubleToString(g_Dry.entryPrice,_Digits),
         DoubleToString(g_Dry.sl,_Digits),
         DoubleToString(g_Dry.tp,_Digits),
         floatR);
   }
   else
   {
      t += "POSISI dry-run: tidak ada\n";
   }

   return t;
}

//====================================================================
// V8.5 EKSEKUSI LIVE (2b-2)
// Status dibaca dari posisi terbuka + riwayat deal (aman saat restart).
// Komentar order: "AE S=<slot> P=<SL poin>" dipakai untuk menghitung R.
//====================================================================

CTrade g_Trade;

struct LiveTrk
{
   bool   active;
   ulong  posId;
   bool   isBuy;
   int    slot;
   double plannedPx;
   double spreadPts;
   double predExp;
   double predWR;
};

LiveTrk g_Trk;

datetime g_LiveLastBar = 0;
int      g_LiveDayKey = -1;
int      g_LiveDayTrades = 0;
int      g_LiveDayWins = 0;
int      g_LiveDayLosses = 0;
int      g_LiveDayForced = 0;
double   g_LiveDayR = 0.0;
int      g_LiveConsec = 0;
bool     g_LiveStopped = false;
string   g_LiveStopReason = "";

int      g_LiveTotTrades = 0;
int      g_LiveTotWins = 0;
int      g_LiveTotLosses = 0;
double   g_LiveTotR = 0.0;
double   g_LiveTotPredR = 0.0;

//--------------------------------------------------------------------

int LiveParseTag(const string c,const string key)
{
   int p = StringFind(c,key);

   if(p < 0)
      return -1;

   int s = p + StringLen(key);
   int e = StringFind(c," ",s);

   string v = (e < 0) ? StringSubstr(c,s) : StringSubstr(c,s,e - s);

   return (int)StringToInteger(v);
}

bool LiveFindPosition(ulong &ticket,ulong &posId,bool &isBuy,
                      double &openPx,double &vol,string &comment)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(t == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != ExecMagic)
         continue;

      ticket = t;
      posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      vol = PositionGetDouble(POSITION_VOLUME);
      comment = PositionGetString(POSITION_COMMENT);
      return true;
   }

   return false;
}

// Hasil satu posisi dari riwayat: net (profit+komisi+swap+fee), tag order.
bool LivePositionResult(ulong posId,double &net,double &gross,int &slPts,
                        double &vol,int &slot,long &reason,
                        double &openPx,double &closePx)
{
   net = 0.0;
   gross = 0.0;
   slPts = 0;
   vol = 0.0;
   slot = -1;
   reason = -1;
   openPx = 0.0;
   closePx = 0.0;

   if(!HistorySelectByPosition(posId))
      return false;

   bool hasOut = false;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);

      if(d == 0)
         continue;

      double pr = HistoryDealGetDouble(d,DEAL_PROFIT);

      net += pr
           + HistoryDealGetDouble(d,DEAL_COMMISSION)
           + HistoryDealGetDouble(d,DEAL_SWAP)
           + HistoryDealGetDouble(d,DEAL_FEE);

      gross += pr;

      long entry = HistoryDealGetInteger(d,DEAL_ENTRY);

      if(entry == DEAL_ENTRY_IN)
      {
         string c = HistoryDealGetString(d,DEAL_COMMENT);

         slPts = LiveParseTag(c,"P=");
         slot = LiveParseTag(c,"S=");
         vol = HistoryDealGetDouble(d,DEAL_VOLUME);
         openPx = HistoryDealGetDouble(d,DEAL_PRICE);
      }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      {
         hasOut = true;
         reason = HistoryDealGetInteger(d,DEAL_REASON);
         closePx = HistoryDealGetDouble(d,DEAL_PRICE);
      }
   }

   return hasOut;
}

string LiveReasonText(long reason)
{
   if(reason == DEAL_REASON_TP)     return "TP";
   if(reason == DEAL_REASON_SL)     return "SL";
   if(reason == DEAL_REASON_EXPERT) return "FORCED";
   return "LAIN";
}

// Hitung ulang rugi harian (R) dan kalah beruntun dari riwayat deal hari ini.
void LiveRefreshDayRisk()
{
   datetime now = TimeCurrent();
   datetime dayStart = now - (now % 86400);   // 00:00 waktu server

   if(!HistorySelect(dayStart,now + 3600))
      return;

   ulong pids[];
   int cnt = 0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);

      if(d == 0)
         continue;

      if(HistoryDealGetString(d,DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(d,DEAL_MAGIC) != ExecMagic)
         continue;

      if(HistoryDealGetInteger(d,DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      ulong pid = (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);

      bool dup = false;

      for(int k = 0; k < cnt; k++)
         if(pids[k] == pid)
         {
            dup = true;
            break;
         }

      if(dup)
         continue;

      ArrayResize(pids,cnt + 1);
      pids[cnt] = pid;
      cnt++;
   }

   double perPoint = V83ValuePerPointPerLot();

   int trades = 0;
   int wins = 0;
   int losses = 0;
   int forced = 0;
   int consec = 0;
   double dayR = 0.0;

   for(int k = 0; k < cnt; k++)
   {
      double net;
      double gross;
      double vol;
      double op;
      double cl;
      int slPts;
      int slot;
      long reason;

      if(!LivePositionResult(pids[k],net,gross,slPts,vol,slot,reason,op,cl))
         continue;

      double oneR = vol * slPts * perPoint;

      if(oneR <= 0.0)
         continue;

      double r = net / oneR;

      trades++;
      dayR += r;

      if(r > 0.0)
      {
         wins++;
         consec = 0;
      }
      else
      {
         losses++;
         consec++;
      }

      if(reason == DEAL_REASON_EXPERT)
         forced++;
   }

   g_LiveDayTrades = trades;
   g_LiveDayWins = wins;
   g_LiveDayLosses = losses;
   g_LiveDayForced = forced;
   g_LiveDayR = dayR;
   g_LiveConsec = consec;

   bool wasStopped = g_LiveStopped;

   g_LiveStopped = false;
   g_LiveStopReason = "";

   if(ExecMaxDailyLossR > 0.0 && dayR <= -ExecMaxDailyLossR)
   {
      g_LiveStopped = true;
      g_LiveStopReason = "BATAS RUGI HARIAN";
   }
   else if(ExecMaxConsecLosses > 0 && consec >= ExecMaxConsecLosses)
   {
      g_LiveStopped = true;
      g_LiveStopReason = "RENTETAN KALAH";
   }

   if(g_LiveStopped && !wasStopped)
      Print("LIVE STOP hari ini: ",g_LiveStopReason,
            " | R hari ini ",DoubleToString(dayR,2),
            " | kalah beruntun ",consec);
}

// Sudah ada trade di slot ini hari ini? (anti order dobel saat restart)
bool LiveSlotTradedToday(int slot)
{
   datetime now = TimeCurrent();
   datetime dayStart = now - (now % 86400);

   if(!HistorySelect(dayStart,now + 3600))
      return false;

   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);

      if(d == 0)
         continue;

      if(HistoryDealGetString(d,DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(d,DEAL_MAGIC) != ExecMagic)
         continue;

      if(HistoryDealGetInteger(d,DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      if(LiveParseTag(HistoryDealGetString(d,DEAL_COMMENT),"S=") == slot)
         return true;
   }

   return false;
}

bool LiveTradeAllowed(string &why)
{
   why = "";

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      why = "AutoTrading terminal mati";
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      why = "trading EA tidak diizinkan";
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      why = "akun tidak boleh trading/EA";
      return false;
   }

   if(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
   {
      why = "mode trading simbol bukan FULL";
      return false;
   }

   return true;
}

// Lot: FIXED = manual, ATR = saldo acuan x risiko% / (SL x nilai poin).
// Dibulatkan ke bawah sesuai step. Return 0 bila tidak boleh trade.
double LiveCalcLot(double slPts,double &oneRMoney,string &why)
{
   oneRMoney = 0.0;
   why = "";

   double perPoint = V83ValuePerPointPerLot();
   double minL = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(perPoint <= 0.0 || step <= 0.0 || slPts <= 0.0)
   {
      why = "nilai tick / volume step / SL tidak valid";
      return 0.0;
   }

   double lot = ExecFixedLot;

   int vd = (int)MathMax(0.0,MathRound(-MathLog10(step)));

   lot = NormalizeDouble(MathFloor(lot / step + 1e-9) * step,vd);

   if(lot < minL)
   {
      why = StringFormat("lot hitungan %.4f di bawah lot minimum %.2f",lot,minL);
      return 0.0;
   }

   if(lot > maxL)
      lot = maxL;

   oneRMoney = lot * slPts * perPoint;

   return lot;
}

// Kirim order market dengan retry terbatas (hanya untuk requote/harga berubah).
bool LiveSendOrder(bool isBuy,double slPts,double tpPts,double lot,
                   datetime bar0,const string cmt,double &plannedPx)
{
   plannedPx = 0.0;

   for(int a = 0; a < 3; a++)
   {
      MqlTick tk;

      if(!SymbolInfoTick(_Symbol,tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
         return false;

      if(a > 0 && (int)(TimeCurrent() - bar0) > ExecMaxEntryDelaySec)
      {
         Print("LIVE retry dihentikan: melewati batas keterlambatan entry");
         return false;
      }

      double px = isBuy ? tk.ask : tk.bid;
      double sl;
      double tp;

      if(isBuy)
      {
         sl = NormalizeDouble(px - slPts * _Point,_Digits);
         tp = NormalizeDouble(px + tpPts * _Point,_Digits);
      }
      else
      {
         sl = NormalizeDouble(px + slPts * _Point,_Digits);
         tp = NormalizeDouble(px - tpPts * _Point,_Digits);
      }

      plannedPx = px;

      bool ok = isBuy ? g_Trade.Buy(lot,_Symbol,0.0,sl,tp,cmt)
                      : g_Trade.Sell(lot,_Symbol,0.0,sl,tp,cmt);

      uint rc = g_Trade.ResultRetcode();

      if(ok && (rc == TRADE_RETCODE_DONE ||
                rc == TRADE_RETCODE_DONE_PARTIAL ||
                rc == TRADE_RETCODE_PLACED))
         return true;

      Print("LIVE order gagal: retcode=",rc," ",
            g_Trade.ResultRetcodeDescription());

      // Bisa saja terisi walau respons gagal: jangan kirim ulang.
      ulong t;
      ulong pid;
      bool b;
      double op;
      double vol;
      string cm;

      if(LiveFindPosition(t,pid,b,op,vol,cm))
         return true;

      bool retry = (rc == TRADE_RETCODE_REQUOTE ||
                    rc == TRADE_RETCODE_PRICE_CHANGED ||
                    rc == TRADE_RETCODE_PRICE_OFF);

      if(!retry)
         return false;

      Sleep(150);
   }

   return false;
}

// Deteksi posisi tertutup -> catat R aktual vs prediksi scan.
void LiveCheckClosed()
{
   if(!g_Trk.active)
      return;

   ulong t;
   ulong pid;
   bool b;
   double op;
   double vol;
   string cm;

   if(LiveFindPosition(t,pid,b,op,vol,cm))
      return;

   double net;
   double gross;
   double v2;
   double openPx;
   double closePx;
   int slPts;
   int slot;
   long reason;

   // Riwayat bisa terlambat muncul: coba lagi di tick berikutnya.
   if(!LivePositionResult(g_Trk.posId,net,gross,slPts,v2,slot,reason,openPx,closePx))
      return;

   double oneR = v2 * slPts * V83ValuePerPointPerLot();
   double rNet = (oneR > 0.0) ? net / oneR : 0.0;
   double rGross = (oneR > 0.0) ? gross / oneR : 0.0;

   g_LiveTotTrades++;
   g_LiveTotR += rNet;
   g_LiveTotPredR += g_Trk.predExp;

   if(rNet > 0.0)
      g_LiveTotWins++;
   else
      g_LiveTotLosses++;

   LiveRefreshDayRisk();

   Print(StringFormat(
      "LIVE CLOSE %s %02d:%02d | %s | R net %+.2f (kotor %+.2f, biaya %+.2f$) | prediksi Exp %+.3f | slip masuk %.1f pt | spread masuk %.1f | hari: %d trade R %+.2f kalah-beruntun %d | total R %+.2f vs prediksi %+.2f",
      g_Trk.isBuy ? "BUY" : "SELL",g_Trk.slot/60,g_Trk.slot%60,
      LiveReasonText(reason),rNet,rGross,net - gross,
      g_Trk.predExp,
      g_Trk.isBuy ? (openPx - g_Trk.plannedPx) / _Point
                  : (g_Trk.plannedPx - openPx) / _Point,
      g_Trk.spreadPts,
      g_LiveDayTrades,g_LiveDayR,g_LiveConsec,
      g_LiveTotR,g_LiveTotPredR));

   g_Trk.active = false;
}

// Tutup paksa di akhir jendela eksekusi.
void LiveForceCloseIfNeeded(int nowMin)
{
   if(nowMin < ExecEndMinute)
      return;

   ulong t;
   ulong pid;
   bool b;
   double op;
   double vol;
   string cm;

   if(!LiveFindPosition(t,pid,b,op,vol,cm))
      return;

   static ulong lastTryMs = 0;

   ulong nowMs = GetTickCount64();

   if(nowMs - lastTryMs < 2000)
      return;

   lastTryMs = nowMs;

   if(!g_Trade.PositionClose(t))
      Print("LIVE force-close gagal: retcode=",g_Trade.ResultRetcode()," ",
            g_Trade.ResultRetcodeDescription());
   else
      Print("LIVE force-close dikirim (akhir jendela eksekusi)");
}

void LiveInit()
{
   g_Trade.SetExpertMagicNumber((ulong)ExecMagic);
   g_Trade.SetDeviationInPoints((ulong)ExecDeviationPoints);
   g_Trade.SetTypeFillingBySymbol(_Symbol);
   g_Trade.SetAsyncMode(false);

   g_Trk.active = false;

   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL)
      Print("LIVE PERINGATAN: akun REAL. Order sungguhan akan dikirim.");
   else
      Print("LIVE: akun non-real (demo/kontes).");

   ulong t;
   ulong pid;
   bool b;
   double op;
   double vol;
   string cm;

   if(LiveFindPosition(t,pid,b,op,vol,cm))
   {
      g_Trk.active = true;
      g_Trk.posId = pid;
      g_Trk.isBuy = b;
      g_Trk.slot = LiveParseTag(cm,"S=");
      g_Trk.plannedPx = op;
      g_Trk.spreadPts = 0.0;
      g_Trk.predExp = 0.0;
      g_Trk.predWR = 0.0;

      Print("LIVE RECOVER: posisi EA masih terbuka (",
            b ? "BUY" : "SELL",", slot ",g_Trk.slot,
            "). Prediksi tidak tersedia setelah restart.");
   }

   LiveRefreshDayRisk();
}

void LiveExecTick(datetime now)
{
   int key = V83DateKey(now);

   if(key != g_LiveDayKey)
   {
      g_LiveDayKey = key;
      LiveRefreshDayRisk();
   }

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   MqlDateTime dt;
   TimeToStruct(ToWIB(now),dt);

   int nowMin = dt.hour * 60 + dt.min;

   LiveCheckClosed();
   LiveForceCloseIfNeeded(nowMin);

   //--- bar baru -> kandidat entry (satu kali per bar)
   datetime bar0 = iTime(_Symbol,Timeframe_Test,0);

   if(bar0 <= 0 || bar0 == g_LiveLastBar)
      return;

   g_LiveLastBar = bar0;

   int barSlot = GetWIBIndex(bar0);

   int pick = -1;
   int cnt = 0;

   for(int i = 0; i < g_SelCount; i++)
   {
      if(g_Sel[i].slot != barSlot)
         continue;

      cnt++;

      if(pick < 0 || g_Sel[i].ciLow > g_Sel[pick].ciLow)
         pick = i;
   }

   if(pick < 0)
      return;

   SelRow r = g_Sel[pick];

   string tag = StringFormat("%02d:%02d %s",
                             r.slot/60,r.slot%60,r.isBuy ? "BUY" : "SELL");

   if(cnt > 1)
      Print("LIVE NOTE ",tag,": BUY dan SELL terpilih di slot yang sama, ",
            "dipilih batas bawah CI tertinggi");

   int lateSec = (int)(now - bar0);

   if(lateSec > ExecMaxEntryDelaySec)
   {
      Print("LIVE SKIP ",tag," | terlambat ",lateSec," detik");
      return;
   }

   if(!InExecWindow(r.slot))
   {
      Print("LIVE SKIP ",tag," | di luar jendela eksekusi");
      return;
   }

   LiveRefreshDayRisk();

   if(g_LiveStopped)
   {
      Print("LIVE SKIP ",tag," | berhenti hari ini: ",g_LiveStopReason);
      return;
   }

   ulong t;
   ulong pid;
   bool b;
   double op;
   double vol;
   string cm;

   if(LiveFindPosition(t,pid,b,op,vol,cm))
   {
      Print("LIVE SKIP ",tag," | posisi EA masih terbuka");
      return;
   }

   if(LiveSlotTradedToday(r.slot))
   {
      Print("LIVE SKIP ",tag," | slot ini sudah ditradingkan hari ini");
      return;
   }

   string why;

   if(!LiveTradeAllowed(why))
   {
      Print("LIVE SKIP ",tag," | ",why);
      return;
   }

   double spreadPts = (tick.ask - tick.bid) / _Point;

   if(ExecMaxSpreadPoints > 0 && spreadPts > (double)ExecMaxSpreadPoints)
   {
      Print("LIVE SKIP ",tag," | spread ",DoubleToString(spreadPts,1),
            " > ",ExecMaxSpreadPoints);
      return;
   }

   double slPts;
   double tpPts;

   if(!GetSLTPPoints(slPts,tpPts,bar0))
   {
      Print("LIVE SKIP ",tag," | ATR belum siap");
      return;
   }

   long stopsLvl = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long frzLvl = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (double)MathMax(stopsLvl,frzLvl);

   if(slPts - spreadPts < minDist || tpPts - spreadPts < minDist)
   {
      Print("LIVE SKIP ",tag," | jarak SL/TP terlalu dekat dengan batas stop broker (",
            DoubleToString(minDist,0)," pt)");
      return;
   }

   double oneR;
   double lot = LiveCalcLot(slPts,oneR,why);

   if(lot <= 0.0)
   {
      Print("LIVE SKIP ",tag," | ",why);
      return;
   }

   double entryPx = r.isBuy ? tick.ask : tick.bid;
   double margin = 0.0;

   if(!OrderCalcMargin(r.isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol,lot,entryPx,margin) ||
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("LIVE SKIP ",tag," | margin bebas tidak cukup (butuh ",
            DoubleToString(margin,2),")");
      return;
   }

   string cmt = StringFormat("AE S=%d P=%d",r.slot,(int)MathRound(slPts));
   double plannedPx;

   if(!LiveSendOrder(r.isBuy,slPts,tpPts,lot,bar0,cmt,plannedPx))
   {
      Print("LIVE SKIP ",tag," | order tidak terkirim");
      return;
   }

   if(!LiveFindPosition(t,pid,b,op,vol,cm))
   {
      Print("LIVE WARNING ",tag," | order terkirim tetapi posisi belum terbaca");
      return;
   }

   g_Trk.active = true;
   g_Trk.posId = pid;
   g_Trk.isBuy = r.isBuy;
   g_Trk.slot = r.slot;
   g_Trk.plannedPx = plannedPx;
   g_Trk.spreadPts = spreadPts;
   g_Trk.predExp = r.ex;
   g_Trk.predWR = r.wr;

   // Jaga jarak SL/TP tepat dari harga isi aktual.
   double wantSL;
   double wantTP;

   if(r.isBuy)
   {
      wantSL = NormalizeDouble(op - slPts * _Point,_Digits);
      wantTP = NormalizeDouble(op + tpPts * _Point,_Digits);
   }
   else
   {
      wantSL = NormalizeDouble(op + slPts * _Point,_Digits);
      wantTP = NormalizeDouble(op - tpPts * _Point,_Digits);
   }

   if(PositionSelectByTicket(t))
   {
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(MathAbs(curSL - wantSL) > _Point * 0.5 ||
         MathAbs(curTP - wantTP) > _Point * 0.5)
      {
         if(!g_Trade.PositionModify(t,wantSL,wantTP))
            Print("LIVE WARNING: koreksi SL/TP gagal (",
                  g_Trade.ResultRetcodeDescription(),
                  "), SL/TP awal tetap aktif");
      }
   }

   Print(StringFormat(
      "LIVE OPEN %s | lot %.2f | entry %s SL %s TP %s (%.0f/%.0f pts) | 1R=%.2f$ | spread %.1f slip %.1f | prediksi: WR%.1f CI-low%.1f Exp%s",
      tag,vol,
      DoubleToString(op,_Digits),
      DoubleToString(wantSL,_Digits),
      DoubleToString(wantTP,_Digits),
      slPts,tpPts,oneR,spreadPts,
      r.isBuy ? (op - plannedPx) / _Point : (plannedPx - op) / _Point,
      r.wr,r.ciLow,V83FmtExpNoLeadZero(r.ex)));
}

string LivePanelText()
{
   string t = StringFormat(
      "LIVE hari ini: %d trade | W %d L %d F %d | R net %+.2f | kalah-beruntun %d | %s\n",
      g_LiveDayTrades,g_LiveDayWins,g_LiveDayLosses,g_LiveDayForced,
      g_LiveDayR,g_LiveConsec,
      g_LiveStopped ? ("STOP: " + g_LiveStopReason) : "AKTIF");

   t += StringFormat(
      "LIVE sejak EA nyala: %d trade | W %d L %d | R net %+.2f (prediksi scan %+.2f)\n",
      g_LiveTotTrades,g_LiveTotWins,g_LiveTotLosses,
      g_LiveTotR,g_LiveTotPredR);

   ulong ticket;
   ulong pid;
   bool b;
   double op;
   double vol;
   string cm;

   if(LiveFindPosition(ticket,pid,b,op,vol,cm) && PositionSelectByTicket(ticket))
   {
      t += StringFormat(
         "POSISI: %s %.2f lot | entry %s SL %s TP %s | floating %+.2f$\n",
         b ? "BUY" : "SELL",vol,
         DoubleToString(op,_Digits),
         DoubleToString(PositionGetDouble(POSITION_SL),_Digits),
         DoubleToString(PositionGetDouble(POSITION_TP),_Digits),
         PositionGetDouble(POSITION_PROFIT));
   }
   else
   {
      t += "POSISI: tidak ada\n";
   }

   return t;
}

//--------------------------------------------------------------------
// Panel
//--------------------------------------------------------------------

string SessionLabel(int hour)
{
   if(hour >= SessionUSStartHour)     return "AS";
   if(hour >= SessionEuropeStartHour) return "EROPA";
   if(hour >= SessionAsiaStartHour)   return "ASIA";
   return "SEPI";
}

string FmtHMS(int sec)
{
   if(sec < 0)
      sec = 0;

   return StringFormat("%02d:%02d:%02d",sec/3600,(sec%3600)/60,sec%60);
}

string BuildPanelText()
{
   datetime now = TimeTradeServer();

   MqlDateTime dt;
   TimeToStruct(ToWIB(now),dt);

   int nowSec = dt.hour * 3600 + dt.min * 60 + dt.sec;

   string t = StringFormat("AURUM EDGE LIVE | %s %s | FIXED | RR %.2f (BE %.1f%%)\n",
                           _Symbol,EnumToString(Timeframe_Test),
                           g_RR,BreakevenWR());

   if(!g_WarmupOK)
   {
      t += StringFormat("WARM-UP KURANG: %d hari termuat, perlu sekitar %d. EA tidak memilih slot.\n",
                        g_WarmupSpanDays,DiscoveryDays + ForwardDays);
      return t;
   }

   bool inWin = (nowSec / 60 >= ExecStartMinute &&
                 nowSec / 60 < ExecEndMinute);

   t += StringFormat("Window %dD | warm-up %d bar sejak %s | jam %s | sesi %s\n",
                     DiscoveryDays,(int)g_WarmupBars,
                     TimeToString(g_WarmupFirstBar,TIME_DATE),
                     FmtHMS(nowSec),SessionLabel(dt.hour));

   t += StringFormat("Jendela EA %02d:%02d-%02d:%02d : %s\n",
                     ExecStartMinute/60,ExecStartMinute%60,
                     ExecEndMinute/60,ExecEndMinute%60,
                     inWin ? "AKTIF" : "DI LUAR JENDELA");

   t += StringFormat("Seleksi %d | %d slot (qualified %d > area %d)\n",
                     g_SelectionDayKey,g_SelCount,
                     g_FunnelQual,g_FunnelClusters);

   int idx = -1;
   bool tomorrow = false;

   for(int i = 0; i < g_SelCount; i++)
   {
      if((g_Sel[i].slot + 1) * 60 > nowSec)
      {
         idx = i;
         break;
      }
   }

   if(idx < 0 && g_SelCount > 0)
   {
      idx = 0;
      tomorrow = true;
   }

   if(idx < 0)
   {
      t += "NEXT: tidak ada slot terpilih (NO TRADE)\n";
   }
   else
   {
      SelRow r = g_Sel[idx];

      int remain = r.slot * 60 - nowSec;

      if(tomorrow)
         remain += 86400;

      t += StringFormat("NEXT %02d:%02d %s | %s | dalam %s | sesi slot %s\n",
                        r.slot/60,r.slot%60,r.isBuy ? "BUY" : "SELL",
                        tomorrow ? "BESOK (perkiraan)" : "HARI INI",
                        FmtHMS(remain),SessionLabel(r.slot/60));

      t += StringFormat("N %d  W %d  L %d  WR %.1f%% | CI-low %.1f%% (BE %.1f%%)\n",
                        r.n,r.w,r.l,r.wr,r.ciLow,BreakevenWR());

      t += StringFormat("PF %.2f  Exp %s  DD %.0fR  MaxL %d\n",
                        r.pf,V83FmtExpNoLeadZero(r.ex),r.dd,r.maxL);

      t += V83CostStatus(r.isBuy,r.slot) + "\n";

      string sltp = StringFormat("SL %d / TP %d pts",SL_Points,TP_Points);

      t += sltp + "\n";

      t += StringFormat("Area %02d:%02d-%02d:%02d (%d slot) | CUT %.1f%% | %s\n",
                        r.clFirst/60,r.clFirst%60,r.clLast/60,r.clLast%60,
                        r.clMembers,r.cutPct,
                        V83TemporalTag(r.isBuy,r.slot));
   }

   t += (ExecMode == EXEC_LIVE) ? LivePanelText() : DryPanelText();

   t += StringFormat("Same-bar: M1 %d | tick %d | fallback-loss %d\n",
                     (int)SameBarM1Resolved,(int)SameBarTickResolved,
                     (int)SameBarFallbackLoss);

   return t;
}

void LiveTick(datetime now)
{
   if(g_WarmupOK)
   {
      int key = GetWIBDateKey(now);

      if(key != g_SelectionDayKey)
      {
         g_SelectionDayKey = key;
         BuildSelection();
      }
   }

   if(ExecMode == EXEC_LIVE)
      LiveExecTick(now);
   else
      DryRunTick(now);

   if(!ShowPanel)
      return;

   if(now == g_LastPanelTime)
      return;

   g_LastPanelTime = now;

   Comment(BuildPanelText());
}

//====================================================================
// ON INIT
//====================================================================

int OnInit()
{
   //===============================================================
   // Parameter validation only.
   //
   // IMPORTANT:
   // We intentionally DO NOT request the full historical range here.
   // The Strategy Tester controls the test period.
   //===============================================================

   if(TP_Points <= 0)
   {
      Print("ERROR: TP_Points must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SL_Points <= 0)
   {
      Print("ERROR: SL_Points must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_RR = (double)TP_Points / (double)SL_Points;

   if(SimulatedSpreadPoints < 0)
   {
      Print(
         "ERROR: SimulatedSpreadPoints must be >= 0"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(EntrySlippagePoints < 0)
   {
      Print(
         "ERROR: EntrySlippagePoints must be >= 0"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(MinSamples < 1)
   {
      Print(
         "ERROR: MinSamples must be >= 1"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(Min_WR < 0.0 ||
      Min_WR > 100.0)
   {
      Print(
         "ERROR: Min_WR must be 0..100"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxSlotDD_R < 0.0)
   {
      Print(
         "ERROR: MaxSlotDD_R must be >= 0"
      );

      return INIT_PARAMETERS_INCORRECT;
   }

   if(DiscoveryDays < 1 || ForwardDays < 0)
   {
      Print("ERROR: DiscoveryDays must be >= 1 and ForwardDays >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MaxNeighborMinutes < 1 || MaxNeighborMinutes > 5)
   {
      Print("ERROR: MaxNeighborMinutes must be 1..5");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(Min_PF < 0.0 || Min_Expectancy < -1.0)
   {
      Print("ERROR: Invalid V8.3 qualification thresholds");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SimulationRiskUSD <= 0.0)
   {
      Print("ERROR: SimulationRiskUSD must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ExecMaxSpreadPoints < 0 || ExecMaxEntryDelaySec < 0 ||
      ExecMaxDailyLossR < 0.0 || ExecMaxConsecLosses < 0)
   {
      Print("ERROR: Exec limits must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ExecFixedLot <= 0.0 ||
      ExecDeviationPoints < 0 || ExecMagic <= 0)
   {
      Print("ERROR: parameter eksekusi tidak valid (lot/deviasi/magic)");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(MonteCarloRuns < 100)
   {
      Print("ERROR: MonteCarloRuns should be >= 100");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ExecStartMinute < 0 || ExecEndMinute > 1440 ||
      ExecEndMinute <= ExecStartMinute)
   {
      Print("ERROR: Exec window invalid (0 <= start < end <= 1440)");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(SessionAsiaStartHour < 0 || SessionAsiaStartHour > 23 ||
      SessionEuropeStartHour < 0 || SessionEuropeStartHour > 23 ||
      SessionUSStartHour < 0 || SessionUSStartHour > 23)
   {
      Print("ERROR: Session start hours must be 0..23");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(EA_Mode == MODE_LIVE_PANEL && ServerToWIB_Hours != 0)
      Print("WARNING: ServerToWIB_Hours != 0. Jam slot dan jendela ",
            "eksekusi mengikuti jam slot, bukan jam broker.");

   ResetHistory();

   // Force symbol availability.
   if(!SymbolSelect(
         _Symbol,
         true
      ))
   {
      Print(
         "ERROR: SymbolSelect failed. Error=",
         GetLastError()
      );

      return INIT_FAILED;
   }

   Print("============================================================");
   Print("AURUM EDGE SCANNER V8.37 STARTED - RESEARCH BUILD FIX7");
   Print("Symbol          : ", _Symbol);
   Print("Timeframe       : ", EnumToString(Timeframe_Test));
   Print("SL/TP           : FIXED");
   Print("TP              : ", TP_Points);
   Print("SL              : ", SL_Points);
   Print("Effective RR    : ", DoubleToString(g_RR,4),
         " | Breakeven WR: ", DoubleToString(BreakevenWR(),2), "%");
   Print("Fallback spread : ", SimulatedSpreadPoints);
   Print("Entry slippage  : ", EntrySlippagePoints);
   Print("Server -> WIB   : +", ServerToWIB_Hours);
   Print("Min samples     : ", MinSamples);
   Print("Min WR          : ", DoubleToString(Min_WR,2), "%");
   Print("Max slot DD     : ", DoubleToString(MaxSlotDD_R,2), "R");
   Print("Journal filter  : ", ShowOnlyQualified ? "QUALIFIED ONLY" : "ALL SIDES");
   Print("NO TIMEOUT      : TRUE");
   Print("CSV             : DISABLED");
   Print("EA mode         : ", EnumToString(EA_Mode));

   if(EA_Mode == MODE_LIVE_PANEL)
   {
      Print("Exec window     : ",
            StringFormat("%02d:%02d-%02d:%02d",
                         ExecStartMinute/60,ExecStartMinute%60,
                         ExecEndMinute/60,ExecEndMinute%60));
      Print("Selection       : kualifikasi V8.37 (tanpa filter CI/COST), wakil terbaik per area");
   }
   
   if(EA_Mode == MODE_LIVE_PANEL && ExecMode == EXEC_LIVE)
      LiveInit();

   if(EA_Mode == MODE_LIVE_PANEL && !MQLInfoInteger(MQL_TESTER))
      EventSetTimer(1);
   Print("============================================================");

   return INIT_SUCCEEDED;
}

//====================================================================
// ON TICK
//====================================================================

void OnTick()
{
   datetime now =
      TimeCurrent();

   if(FirstSeenTime == 0)
      FirstSeenTime = now;

   LastSeenTime =
      now;

   if(EA_Mode == MODE_LIVE_PANEL && !g_WarmupDone)
   {
      LastSeenTime = now;
      g_WarmupOK = RunWarmup();
      g_WarmupDone = true;
   }

   //===============================================================
   // Current bar
   //===============================================================

   datetime currentBar =
      iTime(
         _Symbol,
         Timeframe_Test,
         0
      );

   if(currentBar <= 0)
      return;

   ProcessNewBar(
      currentBar
   );

   if(EA_Mode == MODE_LIVE_PANEL)
      LiveTick(now);
}

//====================================================================
// ON TESTER
//
// Called after historical tester run.
// This is where the final scanner report is printed.
//====================================================================

double OnTester()
{
   //===============================================================
   // Process the last fully completed bar if possible.
   //
   // We deliberately DO NOT force-close open trades.
   // NO TIMEOUT remains active.
   //===============================================================

   datetime currentBar =
      iTime(
         _Symbol,
         Timeframe_Test,
         0
      );

   int secondsPerBar =
      PeriodSeconds(
         Timeframe_Test
      );

   if(currentBar > 0 &&
      secondsPerBar > 0)
   {
      datetime now =
         TimeCurrent();

      if(now >=
         currentBar +
         secondsPerBar)
      {
         if(currentBar !=
            LastProcessedClosedBar)
         {
            MqlRates bar[];

            int copied =
               CopyRates(
                  _Symbol,
                  Timeframe_Test,
                  0,
                  1,
                  bar
               );

            if(copied == 1)
            {
               ResolveOpenTrades(
                  bar[0].time,
                  bar[0].high,
                  bar[0].low
               );

               LastProcessedClosedBar =
                  bar[0].time;
            }
         }
      }
   }

   PrintFinalReport();

   // Custom optimization criterion:
   // total resolved expectancy in R.
   //
   // This does not affect normal single backtests.
   double totalR = 0.0;

   for(int slot = 0;
       slot < 1440;
       slot++)
   {
      totalR +=
         (double)BuyWins[slot] -
         (double)BuyLosses[slot];

      totalR +=
         (double)SellWins[slot] -
         (double)SellLosses[slot];
   }

   return totalR;
}

void OnTimer()
{
   if(EA_Mode != MODE_LIVE_PANEL)
      return;

   datetime last = TimeCurrent();

   // Terminal belum punya waktu server (belum ada koneksi/tick): coba lagi.
   if(last <= 0)
      return;

   if(!g_WarmupDone)
   {
      if(FirstSeenTime == 0)
         FirstSeenTime = last;

      LastSeenTime = last;
      g_WarmupOK = RunWarmup();
      g_WarmupDone = true;
   }

   // Panel dan pergantian hari tetap jalan walau pasar tutup (tanpa tick).
   LiveTick(TimeTradeServer());
}

//====================================================================
// ON DEINIT
//====================================================================

void OnDeinit(
   const int reason
)
{
   Comment("");
   EventKillTimer();
Print(
      "AURUM EDGE SCANNER V8.37 stopped. Reason=",
      reason
   );
}

//+------------------------------------------------------------------+