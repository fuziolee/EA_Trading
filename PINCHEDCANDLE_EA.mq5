//+------------------------------------------------------------------+
//|                                        EA_PrevHighLow_Touch.mq5  |
//|  Hijau lalu merah  = kelompok BUY  (level = High gabungan)       |
//|  Merah lalu hijau  = kelompok SELL (level = Low gabungan)        |
//|  Kelompok BUY aktif sampai ada kelompok BUY terbaru              |
//|  Kelompok SELL aktif sampai ada kelompok SELL terbaru            |
//|  Satu kelompok satu entry, exit hanya lewat SL/TP                |
//|  SL berbasis ATR, TP = SL x RR, TF logika tidak ikut TF chart    |
//+------------------------------------------------------------------+
#property copyright "EA Prev High/Low Touch"
#property version   "1.09"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_PANEL_CORNER
{
   PC_LEFT_UPPER  = CORNER_LEFT_UPPER,   // Kiri atas
   PC_RIGHT_UPPER = CORNER_RIGHT_UPPER,  // Kanan atas
   PC_LEFT_LOWER  = CORNER_LEFT_LOWER,   // Kiri bawah
   PC_RIGHT_LOWER = CORNER_RIGHT_LOWER   // Kanan bawah
};

enum ENUM_LOT_MODE
{
   LOT_RISK   = 0,   // Risiko % dari saldo acuan
   LOT_MANUAL = 1    // Lot manual
};

enum ENUM_LOGIC_TF
{
   LTF_M1   = 0,    // M1
   LTF_M2   = 1,    // M2
   LTF_M3   = 2,    // M3
   LTF_M4   = 3,    // M4
   LTF_M5   = 4,    // M5
   LTF_M6   = 5,    // M6
   LTF_M10  = 6,    // M10
   LTF_M12  = 7,    // M12
   LTF_M15  = 8,    // M15
   LTF_M20  = 9,    // M20
   LTF_M30  = 10,   // M30
   LTF_H1   = 11,   // H1
   LTF_H2   = 12,   // H2
   LTF_H3   = 13,   // H3
   LTF_H4   = 14,   // H4
   LTF_H6   = 15,   // H6
   LTF_H8   = 16,   // H8
   LTF_H12  = 17,   // H12
   LTF_D1   = 18,   // D1
   LTF_W1   = 19,   // W1
   LTF_MN1  = 20    // MN1
};

enum ENUM_GROUP_STATE
{
   ST_WAIT    = 0,   // aktif, menunggu sentuhan
   ST_ENTERED = 1,   // sudah entry
   ST_SKIPPED = 2    // level terlewat / entry dibatalkan
};

//--- input
input group "=== Logika EA ==="
input ENUM_LOGIC_TF InpTF   = LTF_H1;     // Timeframe logika (tidak ikut TF chart)
input bool   InpAllowMulti  = false;      // Boleh open posisi walau masih ada posisi

input group "=== ATR, SL & TP ==="
input int    InpATRPeriod   = 14;         // Periode ATR
input double InpSLMult      = 1.5;        // Pengali SL (SL = ATR x pengali)
input int    InpSLMinPoints = 200;        // SL minimum (points)
input int    InpSLMaxPoints = 1000;       // SL maksimum (points)
input double InpRR          = 1.0;        // Risk:Reward (TP = SL x RR)

input group "=== Lot & Risiko ==="
input ENUM_LOT_MODE InpLotMode = LOT_RISK; // Mode lot
input double InpRiskPercent = 1.0;        // Risiko per trade (% dari saldo acuan)
input double InpRefBalance  = 1000.0;     // Saldo acuan (0 = pakai balance akun)
input double InpLot         = 0.01;       // Lot manual (mode manual)

input group "=== Order ==="
input ulong  InpMagic       = 20261023;   // Magic number
input string InpComment     = "PrevHL";   // Komentar order

input group "=== Filter Eksekusi ==="
input int    InpMaxSpread   = 50;         // Spread maksimum (points)
input int    InpSlippage    = 30;         // Slippage / deviation (points)

input group "=== Panel Chart ==="
input bool   InpShowPanel   = true;               // Tampilkan panel
input ENUM_PANEL_CORNER InpCorner = PC_LEFT_UPPER; // Posisi panel
input int    InpPanelX      = 10;         // Jarak X
input int    InpPanelY      = 20;         // Jarak Y

//--- kelompok (satu slot untuk BUY, satu slot untuk SELL)
struct SGroup
{
   datetime         id;      // bar tempat kelompok terbentuk (0 = belum ada kelompok)
   double           level;   // BUY = High gabungan, SELL = Low gabungan
   ENUM_GROUP_STATE state;
   bool             armed;   // harga sudah terlihat di sisi "belum kena" level
   int              why;     // alasan hangus (lihat SkipText)
};

//--- global
CTrade           trade;
ENUM_TIMEFRAMES  g_tf        = PERIOD_H1;
int              g_atrHandle = INVALID_HANDLE;
datetime         g_lastBar   = 0;

SGroup           g_buy, g_sell;

int              g_dir       = 0;       // pola candle terbaru: +1 hijau>merah, -1 merah>hijau, 0 tidak ada
bool             g_dataOk    = false;
double           g_zoneHigh  = 0, g_zoneLow = 0;
bool             g_bull2     = false;   // candle lebih lama (shift 2) hijau?
bool             g_bull1     = false;   // candle terbaru (shift 1) hijau?

bool             g_stopsOk   = false;
double           g_slPts     = 0, g_tpPts = 0, g_atrPts = 0;

#define PFX  "PHL_"
#define ROWS 19

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES ResolveTF(ENUM_LOGIC_TF c)
{
   switch(c)
   {
      case LTF_M1:  return PERIOD_M1;
      case LTF_M2:  return PERIOD_M2;
      case LTF_M3:  return PERIOD_M3;
      case LTF_M4:  return PERIOD_M4;
      case LTF_M5:  return PERIOD_M5;
      case LTF_M6:  return PERIOD_M6;
      case LTF_M10: return PERIOD_M10;
      case LTF_M12: return PERIOD_M12;
      case LTF_M15: return PERIOD_M15;
      case LTF_M20: return PERIOD_M20;
      case LTF_M30: return PERIOD_M30;
      case LTF_H1:  return PERIOD_H1;
      case LTF_H2:  return PERIOD_H2;
      case LTF_H3:  return PERIOD_H3;
      case LTF_H4:  return PERIOD_H4;
      case LTF_H6:  return PERIOD_H6;
      case LTF_H8:  return PERIOD_H8;
      case LTF_H12: return PERIOD_H12;
      case LTF_D1:  return PERIOD_D1;
      case LTF_W1:  return PERIOD_W1;
      case LTF_MN1: return PERIOD_MN1;
   }
   return PERIOD_H1;
}

//+------------------------------------------------------------------+
void ResetGroup(SGroup &g)
{
   g.id    = 0;
   g.level = 0;
   g.state = ST_WAIT;
   g.armed = false;
   g.why   = 0;
}

void NewGroup(SGroup &g, datetime id, double level)
{
   g.id    = id;
   g.level = level;
   g.state = ST_WAIT;
   g.armed = false;
   g.why   = 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_tf = ResolveTF(InpTF);

   g_atrHandle = iATR(_Symbol, g_tf, MathMax(1, InpATRPeriod));
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Gagal membuat handle ATR");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetGroup(g_buy);
   ResetGroup(g_sell);

   //--- pulihkan state (ganti TF chart / EA di-restart tidak boleh mengubah kelompok)
   datetime barTime = iTime(_Symbol, g_tf, 0);
   if(barTime > 0)
   {
      g_lastBar = barTime;
      ReadCandles();
      CalcStops();
      RestoreState(barTime);
   }

   if(InpShowPanel) CreatePanel();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   ObjectsDeleteAll(0, PFX);

   //--- state tersimpan dibersihkan hanya jika EA benar-benar dilepas dari chart
   if(reason == REASON_REMOVE)
   {
      string tags[2]    = {"B", "S"};
      string suffix[5]  = {"id", "lv", "st", "arm", "why"};
      for(int t = 0; t < 2; t++)
         for(int s = 0; s < 5; s++)
            GlobalVariableDel(GVKey(tags[t], suffix[s]));
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, g_tf, 0);
   if(barTime == 0) return;   // data TF belum siap

   //--- bar baru
   if(barTime != g_lastBar)
   {
      g_lastBar = barTime;
      ReadCandles();
      CalcStops();

      //--- kelompok lama yang masih aktif harus "bersiap" lagi dari harga pembukaan bar ini
      //--- (kalau bar dibuka sudah melewati level / gap, kelompok itu terlewat)
      if(g_buy.id  > 0 && g_buy.state  == ST_WAIT) g_buy.armed  = false;
      if(g_sell.id > 0 && g_sell.state == ST_WAIT) g_sell.armed = false;

      //--- kelompok baru menggantikan kelompok lama dengan arah yang sama
      if(g_dir > 0)      NewGroup(g_buy,  barTime, g_zoneHigh);
      else if(g_dir < 0) NewGroup(g_sell, barTime, g_zoneLow);

      SaveGroup(g_buy,  "B");
      SaveGroup(g_sell, "S");
   }

   //--- ATR belum siap saat bar dibuka? coba lagi
   if(!g_stopsOk) CalcStops();

   if(g_stopsOk)
   {
      CheckGroup(g_buy,  true);
      CheckGroup(g_sell, false);
   }

   if(InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| STATE TERSIMPAN (Global Variable terminal)                       |
//| Kunci per symbol + magic + TF logika, jadi aman saat TF chart    |
//| diganti atau EA di-restart                                       |
//+------------------------------------------------------------------+
string GVKey(string tag, string suffix)
{
   return PFX + _Symbol + "_" + IntegerToString((long)InpMagic) + "_" +
          IntegerToString((int)g_tf) + "_" + tag + suffix;
}

void SaveGroup(SGroup &g, string tag)
{
   GlobalVariableSet(GVKey(tag, "id"),  (double)g.id);
   GlobalVariableSet(GVKey(tag, "lv"),  g.level);
   GlobalVariableSet(GVKey(tag, "st"),  (double)((int)g.state));
   GlobalVariableSet(GVKey(tag, "arm"), g.armed ? 1.0 : 0.0);
   GlobalVariableSet(GVKey(tag, "why"), (double)g.why);
}

bool LoadGroup(SGroup &g, string tag)
{
   ResetGroup(g);
   if(!GlobalVariableCheck(GVKey(tag, "id"))) return false;

   datetime id = (datetime)(long)GlobalVariableGet(GVKey(tag, "id"));
   double   lv = GlobalVariableGet(GVKey(tag, "lv"));
   int      st = (int)GlobalVariableGet(GVKey(tag, "st"));
   if(id <= 0 || lv <= 0 || st < 0 || st > 2) return false;

   g.id    = id;
   g.level = lv;
   g.state = (ENUM_GROUP_STATE)st;
   g.armed = (GlobalVariableGet(GVKey(tag, "arm")) > 0.5);
   g.why   = (int)GlobalVariableGet(GVKey(tag, "why"));
   return true;
}

//+------------------------------------------------------------------+
//| Tandai kelompok sudah entry jika ada posisi / deal EA searah     |
//| yang dibuka sejak kelompok itu terbentuk (pengaman tambahan)     |
//+------------------------------------------------------------------+
void SyncTraded(SGroup &g, bool isBuy)
{
   if(g.id <= 0 || g.state != ST_WAIT) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((datetime)PositionGetInteger(POSITION_TIME) < g.id) continue;

      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(posBuy == isBuy) { g.state = ST_ENTERED; return; }
   }

   if(HistorySelect(g.id, TimeCurrent() + 60))
   {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
         if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

         ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
         if((isBuy && dt == DEAL_TYPE_BUY) || (!isBuy && dt == DEAL_TYPE_SELL))
         {
            g.state = ST_ENTERED;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Pulihkan kelompok setelah EA di-restart                          |
//+------------------------------------------------------------------+
void RestoreState(datetime barTime)
{
   LoadGroup(g_buy,  "B");
   LoadGroup(g_sell, "S");

   //--- kelompok di bar berjalan yang belum tercatat (EA baru dipasang di tengah bar)
   if(g_dir > 0 && g_buy.id  != barTime) NewGroup(g_buy,  barTime, g_zoneHigh);
   if(g_dir < 0 && g_sell.id != barTime) NewGroup(g_sell, barTime, g_zoneLow);

   SyncTraded(g_buy,  true);
   SyncTraded(g_sell, false);

   //--- level yang sudah dilewati harga saat EA mati / restart dianggap terlewat
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_buy.id  > 0 && g_buy.state  == ST_WAIT && ask >= g_buy.level)  g_buy.armed  = false;
   if(g_sell.id > 0 && g_sell.state == ST_WAIT && bid <= g_sell.level) g_sell.armed = false;

   SaveGroup(g_buy,  "B");
   SaveGroup(g_sell, "S");
}

//+------------------------------------------------------------------+
//| Baca 2 candle terakhir yang sudah close (shift 1 dan 2)          |
//+------------------------------------------------------------------+
void ReadCandles()
{
   g_dataOk = false;
   g_dir    = 0;
   if(Bars(_Symbol, g_tf) < 5) return;

   double o1 = iOpen (_Symbol, g_tf, 1), c1 = iClose(_Symbol, g_tf, 1);
   double h1 = iHigh (_Symbol, g_tf, 1), l1 = iLow  (_Symbol, g_tf, 1);
   double o2 = iOpen (_Symbol, g_tf, 2), c2 = iClose(_Symbol, g_tf, 2);
   double h2 = iHigh (_Symbol, g_tf, 2), l2 = iLow  (_Symbol, g_tf, 2);
   if(h1 <= 0 || l1 <= 0 || h2 <= 0 || l2 <= 0) return;

   bool bull1 = (c1 > o1), bear1 = (c1 < o1);
   bool bull2 = (c2 > o2), bear2 = (c2 < o2);

   g_bull1 = bull1;
   g_bull2 = bull2;

   //--- zona = High tertinggi & Low terendah gabungan kedua candle
   g_zoneHigh = MathMax(h1, h2);
   g_zoneLow  = MathMin(l1, l2);

   //--- hijau -> merah = kelompok BUY | merah -> hijau = kelompok SELL | selain itu tidak ada kelompok baru
   if(bull2 && bear1)      g_dir =  1;
   else if(bear2 && bull1) g_dir = -1;

   g_dataOk = true;
}

//+------------------------------------------------------------------+
//| Hitung SL/TP (points) dari ATR candle terakhir yang sudah close  |
//+------------------------------------------------------------------+
bool CalcStops()
{
   g_stopsOk = false;

   double buf[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1) return false;
   if(buf[0] <= 0 || _Point <= 0) return false;

   g_atrPts = buf[0] / _Point;

   double sl = g_atrPts * InpSLMult;
   if(InpSLMinPoints > 0) sl = MathMax(sl, InpSLMinPoints);
   if(InpSLMaxPoints > 0) sl = MathMin(sl, InpSLMaxPoints);

   //--- hormati jarak minimum broker
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1;
   sl = MathMax(sl, lvl);

   double tp = MathMax(sl * InpRR, lvl);

   g_slPts   = MathCeil(sl);
   g_tpPts   = MathCeil(tp);
   g_stopsOk = true;
   return true;
}

//+------------------------------------------------------------------+
//| Hitung posisi aktif milik EA di symbol ini                       |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| Cek satu kelompok tiap tick                                      |
//| BUY entry saat Ask menyentuh High, SELL saat Bid menyentuh Low   |
//| Level yang sudah terlewat / disentuh = kelompok terpakai         |
//+------------------------------------------------------------------+
void CheckGroup(SGroup &g, bool isBuy)
{
   if(g.id <= 0 || g.state != ST_WAIT) return;

   string tag = isBuy ? "B" : "S";
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   hit = isBuy ? (ask >= g.level) : (bid <= g.level);

   //--- harga masih di sisi "belum kena" -> siap menunggu
   if(!hit)
   {
      if(!g.armed)
      {
         g.armed = true;
         SaveGroup(g, tag);
      }
      return;
   }

   //--- level tersentuh / terlewati: kelompok ini terpakai apa pun hasilnya
   if(!g.armed)                               { Skip(g, tag, 1); return; }   // level terlewat (gap)
   if(!IsSpreadOk())                          { Skip(g, tag, 2); return; }   // spread tinggi
   if(!InpAllowMulti && CountPositions() > 0) { Skip(g, tag, 3); return; }   // masih ada posisi

   double lot = CalcLot(g_slPts);
   if(lot <= 0)                               { Skip(g, tag, 4); return; }   // lot < minimum

   if(OpenTrade(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lot))
   {
      g.state = ST_ENTERED;
      SaveGroup(g, tag);
   }
   else
      Skip(g, tag, 5);                                                       // order gagal
}

void Skip(SGroup &g, string tag, int code)
{
   g.state = ST_SKIPPED;
   g.why   = code;
   SaveGroup(g, tag);
}

string SkipText(int code)
{
   switch(code)
   {
      case 1: return "level terlewat";
      case 2: return "spread tinggi";
      case 3: return "ada posisi";
      case 4: return "lot < minimum";
      case 5: return "order gagal";
   }
   return "-";
}

//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double lot)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = 0, tp = 0;
   bool   ok  = false;

   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(ask - g_slPts * _Point, _Digits);
      tp = NormalizeDouble(ask + g_tpPts * _Point, _Digits);
      ok = trade.Buy(lot, _Symbol, 0, sl, tp, InpComment);
   }
   else
   {
      sl = NormalizeDouble(bid + g_slPts * _Point, _Digits);
      tp = NormalizeDouble(bid - g_tpPts * _Point, _Digits);
      ok = trade.Sell(lot, _Symbol, 0, sl, tp, InpComment);
   }

   if(!ok)
      PrintFormat("Order %s gagal: %d - %s", EnumToString(type),
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return ok;
}

//+------------------------------------------------------------------+
bool IsSpreadOk()
{
   return ((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread);
}

//+------------------------------------------------------------------+
//| LOT                                                              |
//+------------------------------------------------------------------+
double FloorLot(double lot)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step + 1e-8) * step;
   if(lot < minL) return 0;          // di bawah minimum -> tidak dipaksa naik
   lot = MathMin(maxL, lot);
   return NormalizeDouble(lot, 2);
}

double CalcLot(double slPts)
{
   if(InpLotMode == LOT_MANUAL)
   {
      double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lot  = InpLot;
      if(step > 0) lot = MathFloor(lot / step + 1e-8) * step;
      lot = MathMax(minL, MathMin(maxL, lot));
      return NormalizeDouble(lot, 2);
   }

   if(slPts <= 0) return 0;

   double base = (InpRefBalance > 0) ? InpRefBalance : AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = base * InpRiskPercent / 100.0;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickVal <= 0) return 0;

   double lossPerLot = (slPts * _Point) / tickSize * tickVal;
   if(lossPerLot <= 0) return 0;

   return FloorLot(risk / lossPerLot);
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void CreatePanel()
{
   string bg = PFX + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 320);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 18 * ROWS + 14);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,24,32');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,80,100');
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   for(int i = 0; i < ROWS; i++)
   {
      string n = PFX + "R" + IntegerToString(i);
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, InpPanelX + 10);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, InpPanelY + 7 + i * 18);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetString (0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
   }
}

void SetRow(int i, string text, color clr = clrWhite)
{
   string n = PFX + "R" + IntegerToString(i);
   ObjectSetString (0, n, OBJPROP_TEXT, text);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
}

string TFName(ENUM_TIMEFRAMES tf)
{
   return StringSubstr(EnumToString(tf), 7);   // buang awalan "PERIOD_"
}

void GroupRow(int row, string label, SGroup &g)
{
   if(g.id <= 0)
   {
      SetRow(row, label + " : - (belum ada kelompok)", clrSilver);
      return;
   }

   string lv = DoubleToString(g.level, _Digits);
   if(g.state == ST_WAIT)
      SetRow(row, label + " : " + lv + " | AKTIF", clrLime);
   else if(g.state == ST_ENTERED)
      SetRow(row, label + " : " + lv + " | SELESAI (entry)", clrGold);
   else
      SetRow(row, label + " : " + lv + " | HANGUS: " + SkipText(g.why), clrOrange);
}

void UpdatePanel()
{
   int    buys = 0, sells = 0;
   double pl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++; else sells++;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   int  spread   = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool spreadOk = IsSpreadOk();

   //--- header
   SetRow(0, "PREV HIGH/LOW TOUCH EA  v1.09", clrGold);
   SetRow(1, "Symbol : " + _Symbol);
   SetRow(2, "TF EA  : " + TFName(g_tf) + "  (chart: " + TFName((ENUM_TIMEFRAMES)_Period) + ")", clrAqua);

   //--- setting yang dipakai
   SetRow(3, "---------- SETTING ----------", clrSilver);
   SetRow(4, StringFormat("ATR    : P%d | x%.2f | RR %.2f", InpATRPeriod, InpSLMult, InpRR), clrAqua);
   SetRow(5, StringFormat("SL rng : %d - %d pts", InpSLMinPoints, InpSLMaxPoints), clrAqua);

   string lotSet;
   if(InpLotMode == LOT_RISK)
      lotSet = StringFormat("Risiko %.1f%% | Acuan %s", InpRiskPercent,
                            InpRefBalance > 0 ? DoubleToString(InpRefBalance, 2) : "balance akun");
   else
      lotSet = StringFormat("Manual %.2f", InpLot);
   SetRow(6, "Lot set: " + lotSet, clrAqua);
   SetRow(7, StringFormat("Filter : Spread<=%d | Slip %d", InpMaxSpread, InpSlippage), clrAqua);
   SetRow(8, StringFormat("Mode   : Multi %s | Magic %I64u", InpAllowMulti ? "ON" : "OFF", InpMagic), clrAqua);

   //--- kondisi live
   SetRow(9, "----------- LIVE ------------", clrSilver);
   SetRow(10, StringFormat("Spread : %d / %d", spread, InpMaxSpread), spreadOk ? clrLime : clrTomato);

      if(g_dataOk)
   {
      string a = g_bull2 ? "HIJAU" : "MERAH";
      string b = g_bull1 ? "HIJAU" : "MERAH";
      string d = (g_dir > 0) ? " -> grup BUY baru"
               : ((g_dir < 0) ? " -> grup SELL baru" : " -> tanpa grup baru");
      SetRow(11, "Pola   : " + a + " > " + b + d, (g_dir != 0) ? clrLime : clrSilver);
   }
   else
      SetRow(11, "Pola   : -", clrSilver);

   GroupRow(12, "BUY   ", g_buy);
   GroupRow(13, "SELL  ", g_sell);

   if(g_stopsOk)
   {
      SetRow(14, StringFormat("SL/TP  : %.0f / %.0f pts (ATR %.0f)", g_slPts, g_tpPts, g_atrPts), clrAqua);
      double lot = CalcLot(g_slPts);
      if(lot > 0)
         SetRow(15, StringFormat("Lot    : %.2f", lot));
      else
         SetRow(15, "Lot    : < minimum (skip)", clrTomato);
   }
   else
   {
      SetRow(14, "SL/TP  : menunggu ATR", clrSilver);
      SetRow(15, "Lot    : -", clrSilver);
   }

   SetRow(16, StringFormat("Posisi : BUY %d | SELL %d", buys, sells));
   SetRow(17, StringFormat("Float  : %.2f %s", pl, AccountInfoString(ACCOUNT_CURRENCY)),
          pl >= 0 ? clrLime : clrTomato);

   string st = "AKTIF - menunggu sentuhan";
   color  sc = clrLime;
   bool   anyActive = (g_buy.id > 0 && g_buy.state == ST_WAIT) || (g_sell.id > 0 && g_sell.state == ST_WAIT);
   if(!g_dataOk || !g_stopsOk) { st = "DIAM - data belum siap";            sc = clrOrange; }
   else if(!anyActive)         { st = "DIAM - menunggu kelompok baru";     sc = clrOrange; }
   SetRow(18, "Status : " + st, sc);
}
//+------------------------------------------------------------------+