//+------------------------------------------------------------------+
//|                  MarketReaderEA_Phase1_SNR_Breakout.mq5           |
//|  Market Reader EA - Phase 1 SNR-Only (standalone)  v4.36          |
//|  LAYER 1 = SH/SL berantai (zigzag N) tanpa indikator ZigZag       |
//|  LAYER 2 = Level aktif -> BREAKOUT (wick, no flip)                |
//|  ENTRY   = saat Bid menyentuh SH/SL terbaru (per tick);           |
//|            struktur diperbarui saat candle close                  |
//|  TradeTimeframe = sumber data + logic. Chart TF = tampilan saja.  |
//|  v4.34 : SL/TP ATR + lot dari risiko % + scan                     |
//|  v4.36 : - hapus SL/TP tetap, statistik trade nyata, jumlah trade,|
//|            scanner SL/TP tetap, garis break (tanda SH/SL saja)    |
//|          + SCANNER ATR gaya Scanner_PinchedCandle: rentang        |
//|            dari/sampai/langkah untuk periode ATR, pengali SL,     |
//|            SL min, SL max, RR + rentang waktu                     |
//|          + peringkat Edge = WR - BE (bukan PF)                    |
//+------------------------------------------------------------------+
#property copyright "Market Reader EA - Phase 1 SNR-Only"
#property version   "4.36"
#property description "Standalone SNR breakout-only EA. SH/SL berantai: candle + N konfirmasi (wick), swing darurat saat level terakhir ditembus. Entry saat wick menyentuh SH/SL terbaru. SL/TP berbasis ATR. Scanner ATR dengan peringkat Edge (WR - BE)."

#include <Trade\Trade.mqh>

#define PFX_MARK "MRM_"
#define SC_NONE  INT_MAX

enum ENUM_SCAN_RANK
{
   RANK_EDGE_MID = 0,   // Edge WR vs breakeven, rata-rata pesimis & optimis
   RANK_EDGE_PES = 1,   // Edge WR vs breakeven, pesimis
   RANK_EDGE_OPT = 2    // Edge WR vs breakeven, optimis
};

//==================================================================
// INPUTS
//==================================================================
input group "=== Market Reader (SNR) ==="
input ENUM_TIMEFRAMES      InpTradeTimeframe  = PERIOD_H1;            // TradeTimeframe (sumber SNR)
input bool                 InpDebugMode       = true;                 // DebugMode (log di Journal)
input int                  InpWarmupBars      = 2000;                 // Warm-up bars (closed bars, TradeTF) - live & scanner
input int                  InpMaxZonesTracked = 500;                  // Batas level aktif di memori (0=unlimited)

input group "=== Swing SH/SL (Layer 1) ==="
input int                  InpConfirmBars     = 3;                    // Jumlah candle konfirmasi (wick tidak melewati SH/SL)

input group "=== Entry ==="
input bool                 InpEntryLatestOnly = true;                 // Entry hanya di SH/SL terbaru per tipe (level lama: BRK tanpa entry)
input bool                 InpEntryOnTouch    = true;                 // Entry saat Bid menyentuh level (false = tunggu candle CLOSE di luar level)
input bool                 InpAllowEntryWithPosition = false;         // Boleh entry walau masih ada posisi (searah/hedging, tanpa batas)

input group "=== Execution ==="
input bool                 InpEnableTrading   = false;                // Enable order execution
input long                 InpMagic           = 88001001;             // Magic Number Market Reader EA
input double               InpLotSize         = 0.01;                 // Lot manual (dipakai jika lot risiko OFF)
input int                  InpSlippagePoints  = 30;                   // Slippage (points)
input int                  InpMaxSpreadPoints = 50;                   // Max spread (points, 0=off)

input group "=== SL/TP ATR ==="
input int                  InpATRPeriod       = 14;                   // Periode ATR (candle TradeTF)
input double               InpATRMultSL       = 2.0;                  // Pengali SL (SL = ATR x pengali)
input double               InpRR              = 1.25;                 // RR (TP = SL x RR)
input int                  InpATRMinSL        = 100;                 // SL minimum (points, 0=off)
input int                  InpATRMaxSL        = 1000;                 // SL maksimum (points, 0=off)

input group "=== Risk lot otomatis ==="
input bool                 InpUseRiskLot      = true;                 // Lot dari risiko % (false = lot manual)
input double               InpRiskPercent     = 1.0;                  // Risiko per trade (% saldo acuan)
input double               InpRiskBalance     = 0.0;                  // Saldo acuan (0 = saldo akun saat EA mulai)

input group "=== Scanner: Aktif & Waktu ==="
input bool                 InpScanOn          = false;                 // Scanner ON/OFF (live/demo, bukan tester)
input datetime             InpScanFrom        = D'2016.01.01 00:00';  // Scan dari tanggal
input datetime             InpScanTo          = D'2026.12.30 23:59';  // Scan sampai tanggal
input bool                 InpScanUseM1       = true;                 // Pakai M1 di dalam candle (akurat). false = candle TF saja
input string               InpScanC           = "11,12,13";           // Daftar candle konfirmasi (pisah koma, maks 4)

input group "=== Scanner: Rentang ATR, Pengali SL & RR ==="
input int                  InpScanATRFrom     = 1;                   // Periode ATR dari
input int                  InpScanATRTo       = 25;                   // Periode ATR sampai
input int                  InpScanATRStep     = 1;                    // Periode ATR langkah
input double               InpScanMultFrom    = 1.0;                  // Pengali SL dari
input double               InpScanMultTo      = 3.0;                  // Pengali SL sampai
input double               InpScanMultStep    = 0.05;                  // Pengali SL langkah
input double               InpScanRRFrom      = 1.0;                  // RR dari
input double               InpScanRRTo        = 2.0;                  // RR sampai
input double               InpScanRRStep      = 0.05;                 // RR langkah

input group "=== Scanner: Rentang SL Minimum & Maximum (points) ==="
input int                  InpScanSLMinFrom   = 50;                 // SL minimum dari
input int                  InpScanSLMinTo     = 50;                 // SL minimum sampai
input int                  InpScanSLMinStep   = 50;                  // SL minimum langkah
input int                  InpScanSLMaxFrom   = 100;                 // SL maksimum dari
input int                  InpScanSLMaxTo     = 1000;                 // SL maksimum sampai
input int                  InpScanSLMaxStep   = 50;                  // SL maksimum langkah

input group "=== Scanner: Peringkat & Tampilan ==="
input ENUM_SCAN_RANK       InpScanRank        = RANK_EDGE_MID;        // Peringkat berdasarkan
input int                  InpScanMinTrades   = 200;                  // Minimal total trade agar kombinasi diperingkat
input int                  InpScanTop         = 10;                    // Jumlah baris teratas di panel
input int                  InpScanJournalTop  = 100;                  // Jumlah baris teratas yang dicetak ke Journal

input group "=== Visual (display only, tidak memengaruhi logic) ==="
input color                InpResistanceColor = clrBlue;              // Warna tanda SH
input color                InpSupportColor    = clrRed;               // Warna tanda SL
input int                  InpDrawMaxMarks    = 200;                  // Jumlah tanda SH/SL terbaru yang digambar

//==================================================================
// TYPES
//==================================================================
enum ENUM_ZONE_TYPE   { ZT_RESISTANCE = 0, ZT_SUPPORT = 1 };   // SH = Resistance, SL = Support
enum ENUM_SNR_SIGNAL  { SIG_NO_TRADE = 0, SIG_BUY = 1, SIG_SELL = 2 };

enum ENUM_SNR_EVENT
{
   EV_SWING_HIGH = 0,
   EV_SWING_LOW,
   EV_RES_BREAK,
   EV_SUP_BREAK,
   EV_RES_TOUCH,      // Bid menyentuh SH (intrabar) -> entry BUY
   EV_SUP_TOUCH       // Bid menyentuh SL (intrabar) -> entry SELL
};

struct SNRBar { datetime time; double open, high, low, close; };

// Satu swing. SH: price = High candle pivot. SL: price = Low candle pivot.
struct SNRSwing
{
   int      id;       // diisi saat swing diaktifkan di Layer 2
   int      type;     // ENUM_ZONE_TYPE
   double   price;    // level (ujung SH/SL)
   datetime ref;      // candle pivot (SH/SL)
   datetime valid;    // waktu swing valid
};

// Level aktif di Layer 2 (belum ditembus). Setelah ditembus -> dihapus (no flip).
struct SNRLevel
{
   SNRSwing s;
   datetime tFrom;     // candle pivot
   bool     entered;   // true = sudah entry saat sentuh (intrabar)
};

// SNREvent.count untuk event break:
//   0 = level lama (tanpa entry)
//   1 = entry saat candle close (mode InpEntryOnTouch=false)
//   2 = sudah entry saat sentuh (intrabar)
//   3 = eligible, tetapi sentuhan tidak terpantau tick -> tanpa entry
struct SNREvent { int id; int kind; datetime time; double price; int refId; int count; int side; };

struct SNRDecisionResult { int signal; int buyVotes; int sellVotes; int ignored; string reason; };

//==================================================================
// HELPERS
//==================================================================
string EventName(const int k)
{
   switch(k)
   {
      case EV_SWING_HIGH: return "SWING_HIGH";
      case EV_SWING_LOW:  return "SWING_LOW";
      case EV_RES_BREAK:  return "RES_BREAKOUT";
      case EV_SUP_BREAK:  return "SUP_BREAKOUT";
      case EV_RES_TOUCH:  return "RES_TOUCH";
      case EV_SUP_TOUCH:  return "SUP_TOUCH";
   }
   return "?";
}

string SignalName(const int s)
{
   if(s==SIG_BUY)  return "BUY";
   if(s==SIG_SELL) return "SELL";
   return "NO TRADE";
}

string BrkTag(const int cnt)
{
   switch(cnt)
   {
      case 1: return " ENTRY(close)";
      case 2: return " ENTRY-SAAT-SENTUH(sudah)";
      case 3: return " NO-ENTRY(sentuh tak terpantau)";
   }
   return " NO-ENTRY(level lama)";
}

string FmtDate(const datetime t)
{
   MqlDateTime d;
   TimeToStruct(t,d);
   return StringFormat("%02d %s %d",d.day,
          StringSubstr("JanFebMarAprMayJunJulAugSepOctNovDec",(d.mon-1)*3,3),d.year);
}

//------------------------------------------------------------------
// ATR: rata-rata sederhana True Range dari candle CLOSED (EA live).
// Scanner memakai kumulatif TR yang rumusnya sama -> hasil identik.
//------------------------------------------------------------------
class CATR
{
private:
   int    m_p;
   double m_tr[];
   int    m_n;
   int    m_pos;
   double m_sum;
   double m_prevClose;
   bool   m_has;
public:
   void Init(const int period) { m_p=MathMax(period,1); Reset(); }
   void Reset()
   {
      ArrayResize(m_tr,m_p);
      ArrayInitialize(m_tr,0.0);
      m_n=0; m_pos=0; m_sum=0.0; m_prevClose=0.0; m_has=false;
   }
   void OnBar(const SNRBar &b)
   {
      double tr=b.high-b.low;
      if(m_has)
         tr=MathMax(tr,MathMax(MathAbs(b.high-m_prevClose),MathAbs(b.low-m_prevClose)));
      m_prevClose=b.close; m_has=true;
      if(m_n==m_p) m_sum-=m_tr[m_pos]; else m_n++;
      m_tr[m_pos]=tr;
      m_sum+=tr;
      m_pos=(m_pos+1)%m_p;
   }
   bool   Ready()  const { return m_n>=m_p; }
   double Points() const { return Ready() ? (m_sum/m_p)/_Point : 0.0; }
};

// SL (points) = ATR(points) x pengali, dibatasi min/max (0 = off).
int AtrSLPoints(const double atrPts,const double mult,const int mn,const int mx)
{
   int sl=(int)MathRound(atrPts*mult);
   if(mn>0) sl=MathMax(sl,mn);
   if(mx>0) sl=MathMin(sl,mx);
   return sl;
}

// TP (points) = SL x RR.
int AtrTPPoints(const int slPts,const double rr)
{
   return (int)MathRound(slPts*rr);
}

// "11,12,13" -> {11,12,13}; nilai <=0 dan duplikat dibuang, maks 12.
int ParsePoints(const string src,int &out[])
{
   string parts[];
   const int n=StringSplit(src,',',parts);
   ArrayResize(out,0);
   int k=0;
   for(int i=0;i<n && k<12;i++)
   {
      string p=parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      const int v=(int)StringToInteger(p);
      if(v<=0) continue;
      bool dup=false;
      for(int j=0;j<k;j++)
         if(out[j]==v) { dup=true; break; }
      if(dup) continue;
      ArrayResize(out,k+1);
      out[k]=v;
      k++;
   }
   return k;
}

//==================================================================
// LAYER 1a: DETEKTOR SWING NORMAL (tanpa ZigZag)
//   SH : N candle berikutnya tidak ada yang High-nya melewati High pivot
//   SL : N candle berikutnya tidak ada yang Low-nya melewati Low pivot
//   Pakai wick (High/Low). Warna candle pivot bebas.
//==================================================================
class CSwingDetector
{
private:
   int      m_n;
   double   m_eps;
   SNRBar   m_buf[];     // m_buf[0] = candle pivot, m_buf[1..n] = konfirmasi
   int      m_cnt;
   SNRSwing m_out[];
   int      m_nOut;

   void Emit(const int type,const double price,const datetime ref,const datetime valid)
   {
      SNRSwing s;
      ZeroMemory(s);
      s.type=type; s.price=price; s.ref=ref; s.valid=valid;
      ArrayResize(m_out,m_nOut+1,4);
      m_out[m_nOut]=s; m_nOut++;
   }

public:
   CSwingDetector() { m_n=3; m_eps=_Point*0.5; m_cnt=0; m_nOut=0; }

   void Init(const int confirmBars,const double eps)
   {
      m_n=MathMax(confirmBars,1);
      m_eps=eps;
      Reset();
   }

   void Reset()
   {
      m_cnt=0; m_nOut=0;
      ArrayResize(m_buf,m_n+1);
      ArrayResize(m_out,0,4);
   }

   void OnBar(const SNRBar &b)
   {
      m_nOut=0;
      if(m_cnt<m_n+1) { m_buf[m_cnt]=b; m_cnt++; }
      else
      {
         for(int i=0;i<m_n;i++) m_buf[i]=m_buf[i+1];
         m_buf[m_n]=b;
      }
      if(m_cnt<m_n+1) return;

      const SNRBar p=m_buf[0];
      bool shOk=true;
      bool slOk=true;
      for(int k=1;k<=m_n;k++)
      {
         if((m_buf[k].high-p.high)>m_eps) shOk=false;   // wick melewati SH
         if((p.low-m_buf[k].low)>m_eps)   slOk=false;   // wick melewati SL
      }
      if(shOk) Emit(ZT_RESISTANCE,p.high,p.time,b.time);
      if(slOk) Emit(ZT_SUPPORT,p.low,p.time,b.time);
   }

   int  OutCount() const { return m_nOut; }
   bool GetOut(const int i,SNRSwing &s) const { if(i<0||i>=m_nOut) return false; s=m_out[i]; return true; }
};

//==================================================================
// LAYER 1b + 2: SNR ENGINE (RANTAI SH/SL + BREAKOUT, NO FLIP)
//
//   RANTAI : swing berikutnya harus tipe lawan DAN pivotnya setelah
//            pivot swing terakhir -> SH,SL,SH,SL ... (zigzag N).
//
//   SWING DARURAT : jika level yang ditembus adalah swing TERAKHIR di
//            rantai, swing lawan dibuat dari ekstrem candle setelah
//            pivot sampai candle penembus (inklusif).
//
//   BREAKOUT : Mode wick  : Resistance ditembus jika High > level -> BUY.
//                           Support ditembus jika Low < level -> SELL.
//              Mode close : ditembus jika CLOSE di luar level.
//              Setelah ditembus level dihapus (no flip).
//
//   ENTRY    : (InpEntryLatestOnly) hanya SH terbaru / SL terbaru.
//              (InpEntryOnTouch) entry di CheckTouch() per tick.
//==================================================================
class CSNREngine
{
private:
   CSwingDetector m_det;
   SNRLevel m_lv[];
   int      m_nlv;
   int      m_nextId;
   SNREvent m_log[];
   int      m_nl;
   int      m_nextEv;
   SNREvent m_bar[];
   int      m_nb;
   datetime m_lastTime;
   double   m_eps;
   bool     m_debug;
   bool     m_quiet;
   int      m_maxZones;
   bool     m_latestOnly;
   bool     m_touchMode;

   SNRBar   m_hist[];         // riwayat candle closed (untuk swing darurat)
   int      m_nh;

   int      m_lastType;       // -1 = belum ada, selain itu ENUM_ZONE_TYPE
   datetime m_lastRefT;       // candle pivot swing terakhir
   int      m_lastId;         // id swing terakhir (0 = belum ada)

   int      m_lastShId;       // id SH terbaru (0 = belum ada)
   int      m_lastSlId;       // id SL terbaru (0 = belum ada)

   bool Gt(const double a,const double b) const { return (a-b)>m_eps; }
   bool Lt(const double a,const double b) const { return (b-a)>m_eps; }

   void AddLog(const int kind,const datetime t,const double price,const int refId,
               const int cnt,const int side,const bool barEvt)
   {
      SNREvent e;
      e.id=m_nextEv++; e.kind=kind; e.time=t; e.price=price; e.refId=refId; e.count=cnt; e.side=side;
      if(m_nl>=2000)
      {
         const int drop=1000;
         for(int i=0;i<m_nl-drop;i++) m_log[i]=m_log[i+drop];
         m_nl-=drop;
         ArrayResize(m_log,m_nl);
      }
      ArrayResize(m_log,m_nl+1,512);
      m_log[m_nl]=e; m_nl++;
      if(barEvt)
      {
         ArrayResize(m_bar,m_nb+1,16);
         m_bar[m_nb]=e; m_nb++;
      }
      if(m_debug && !m_quiet)
      {
         const bool isBrk=(kind==EV_RES_BREAK || kind==EV_SUP_BREAK);
         Print(StringFormat("[SNR] %s %s swing=%d px=%s%s",
               TimeToString(t,TIME_DATE|TIME_MINUTES|TIME_SECONDS),EventName(kind),refId,
               DoubleToString(price,_Digits),
               isBrk ? BrkTag(cnt) : ""));
      }
   }

   void RemoveLevel(const int idx)
   {
      for(int j=idx;j<m_nlv-1;j++) m_lv[j]=m_lv[j+1];
      m_nlv--;
      ArrayResize(m_lv,m_nlv);
   }

   void AddHistory(const SNRBar &b)
   {
      ArrayResize(m_hist,m_nh+1,1024);
      m_hist[m_nh]=b; m_nh++;
      if(m_nh>6000)
      {
         const int keep=5000;
         const int drop=m_nh-keep;
         for(int i=0;i<keep;i++) m_hist[i]=m_hist[i+drop];
         m_nh=keep;
         ArrayResize(m_hist,m_nh);
      }
   }

   // Swing darurat. L = swing terakhir yang baru ditembus oleh candle b.
   bool BuildFallback(const SNRLevel &L,const SNRBar &b,SNRSwing &out)
   {
      const bool isR=(L.s.type==ZT_RESISTANCE);
      const int  oppT=isR ? ZT_SUPPORT : ZT_RESISTANCE;

      double   best=isR ? b.low : b.high;      // mulai dari candle penembus
      datetime bt=b.time;
      for(int k=m_nh-1;k>=0;k--)
      {
         if(m_hist[k].time<=L.s.ref) break;    // pivot L sendiri tidak ikut
         if(m_hist[k].time>=b.time) continue;
         if(isR)
         {
            if(m_hist[k].low<=best)  { best=m_hist[k].low;  bt=m_hist[k].time; }
         }
         else
         {
            if(m_hist[k].high>=best) { best=m_hist[k].high; bt=m_hist[k].time; }
         }
      }

      ZeroMemory(out);
      out.type=oppT; out.price=best; out.ref=bt; out.valid=b.time;
      return true;
   }

   // Dievaluasi pada candle yang BARU close terhadap level aktif,
   // SEBELUM swing baru dari candle yang sama diproses.
   void EvaluateBreakouts(const SNRBar &b)
   {
      SNRSwing pend;
      ZeroMemory(pend);
      bool havePend=false;

      for(int i=m_nlv-1;i>=0;i--)
      {
         const SNRLevel L=m_lv[i];
         const double lvl=L.s.price;
         const bool isR=(L.s.type==ZT_RESISTANCE);

         const bool touch = isR ? Gt(b.high,lvl) : Lt(b.low,lvl);   // wick cukup
         if(!touch) continue;

         // MODE CLOSE: level baru dianggap ditembus jika candle CLOSE di luar level.
         if(!m_touchMode)
         {
            const bool closeOk = isR ? Gt(b.close,lvl) : Lt(b.close,lvl);
            if(!closeOk) continue;
         }

         const bool eligible = (!m_latestOnly) || (L.s.id==(isR ? m_lastShId : m_lastSlId));

         int cnt;
         if(!eligible)         cnt=0;                    // level lama: BRK tanpa entry
         else if(!m_touchMode) cnt=1;                    // entry saat candle close
         else                  cnt=L.entered ? 2 : 3;    // sudah entry saat sentuh / sentuh tak terpantau

         const int kind = isR ? EV_RES_BREAK : EV_SUP_BREAK;
         AddLog(kind,b.time,isR?b.high:b.low,L.s.id,cnt,isR?1:-1,true);

         // swing terakhir di rantai ditembus -> swing lawan darurat
         if(!havePend && L.s.id==m_lastId)
            havePend=BuildFallback(L,b,pend);

         RemoveLevel(i);                     // no flip: level selesai
      }

      if(havePend) ProcessSwing(pend);
   }

   // Swing menjadi level aktif DAN swing terakhir di rantai.
   void ProcessSwing(const SNRSwing &s)
   {
      SNRSwing a=s;
      a.id=m_nextId++;
      const bool isSH=(a.type==ZT_RESISTANCE);

      AddLog(isSH?EV_SWING_HIGH:EV_SWING_LOW,a.ref,a.price,a.id,0,isSH?1:-1,false);

      SNRLevel L;
      L.s=a; L.tFrom=a.ref; L.entered=false;
      ArrayResize(m_lv,m_nlv+1,256);
      m_lv[m_nlv]=L; m_nlv++;

      m_lastType=a.type;
      m_lastRefT=a.ref;
      m_lastId=a.id;
      if(isSH) m_lastShId=a.id; else m_lastSlId=a.id;

      if(m_maxZones>0 && m_nlv>m_maxZones)
      {
         const int drop=m_nlv-m_maxZones;
         for(int i=0;i<m_nlv-drop;i++) m_lv[i]=m_lv[i+drop];
         m_nlv-=drop;
         ArrayResize(m_lv,m_nlv);
      }
   }

public:
   void Init(const bool dbg,const int maxZones,const int confirmBars,
             const bool latestOnly,const bool touchMode)
   {
      m_debug=dbg; m_quiet=false; m_maxZones=maxZones;
      m_latestOnly=latestOnly;
      m_touchMode=touchMode;
      m_eps=_Point*0.5;
      m_det.Init(confirmBars,m_eps);
      Reset();
   }

   void SetQuiet(const bool q) { m_quiet=q; }

   void Reset()
   {
      m_nlv=0; m_nextId=1; m_nl=0; m_nextEv=1; m_nb=0; m_lastTime=0;
      m_nh=0;
      m_lastType=-1; m_lastRefT=0; m_lastId=0;
      m_lastShId=0; m_lastSlId=0;
      m_det.Reset();
      ArrayResize(m_lv,0,256);
      ArrayResize(m_log,0,512);
      ArrayResize(m_bar,0,16);
      ArrayResize(m_hist,0,1024);
   }

   // Satu-satunya pintu data struktur: candle CLOSED, kronologis.
   void OnClosedBar(const SNRBar &b)
   {
      m_nb=0;
      if(m_lastTime!=0 && b.time<=m_lastTime) return;   // guard kronologis
      m_lastTime=b.time;

      EvaluateBreakouts(b);

      m_det.OnBar(b);
      for(int i=0;i<m_det.OutCount();i++)
      {
         SNRSwing s;
         if(!m_det.GetOut(i,s)) continue;
         if(m_lastType>=0)
         {
            if(s.type==m_lastType) continue;      // harus bergantian: tipe lawan
            if(s.ref<=m_lastRefT)  continue;      // pivot harus setelah pivot swing terakhir
         }
         ProcessSwing(s);
      }

      AddHistory(b);
   }

   // Dipanggil tiap tick (mode InpEntryOnTouch). Bid melewati level eligible
   // yang belum "entered" -> level ditandai entered dan sinyal dikembalikan.
   int CheckTouch(const double bid,int &refId,double &lvlOut)
   {
      refId=0; lvlOut=0.0;
      int nBuy=0, nSell=0, idB=0, idS=0;
      double pB=0.0, pS=0.0;

      for(int i=0;i<m_nlv;i++)
      {
         if(m_lv[i].entered) continue;
         const SNRSwing s=m_lv[i].s;
         const bool isR=(s.type==ZT_RESISTANCE);
         if(m_latestOnly && s.id!=(isR ? m_lastShId : m_lastSlId)) continue;

         if(isR)
         {
            if(Gt(bid,s.price))
            {
               m_lv[i].entered=true;
               nBuy++; idB=s.id; pB=s.price;
               AddLog(EV_RES_TOUCH,TimeCurrent(),bid,s.id,0,1,false);
            }
         }
         else
         {
            if(Lt(bid,s.price))
            {
               m_lv[i].entered=true;
               nSell++; idS=s.id; pS=s.price;
               AddLog(EV_SUP_TOUCH,TimeCurrent(),bid,s.id,0,-1,false);
            }
         }
      }

      if(nBuy>0 && nSell>0) return SIG_NO_TRADE;      // konflik di tick yang sama
      if(nBuy>0)  { refId=idB; lvlOut=pB; return SIG_BUY; }
      if(nSell>0) { refId=idS; lvlOut=pS; return SIG_SELL; }
      return SIG_NO_TRADE;
   }

   // Versi SCANNER dari CheckTouch: satu "langkah" harga diwakili oleh
   // High/Low bar (M1 atau candle TF). Aturan sama persis dengan CheckTouch.
   int CheckTouchBar(const double hi,const double lo,int &refId,double &lvlOut)
   {
      refId=0; lvlOut=0.0;
      int nBuy=0, nSell=0, idB=0, idS=0;
      double pB=0.0, pS=0.0;
      const int minId=m_latestOnly ? MathMin(m_lastShId,m_lastSlId) : 0;

      for(int i=m_nlv-1;i>=0;i--)
      {
         if(m_latestOnly && m_lv[i].s.id<minId) break;
         if(m_lv[i].entered) continue;
         const SNRSwing s=m_lv[i].s;
         const bool isR=(s.type==ZT_RESISTANCE);
         if(m_latestOnly && s.id!=(isR ? m_lastShId : m_lastSlId)) continue;

         if(isR)
         {
            if(Gt(hi,s.price))
            {
               m_lv[i].entered=true;
               nBuy++; idB=s.id; pB=s.price;
            }
         }
         else
         {
            if(Lt(lo,s.price))
            {
               m_lv[i].entered=true;
               nSell++; idS=s.id; pS=s.price;
            }
         }
      }

      if(nBuy>0 && nSell>0) return SIG_NO_TRADE;
      if(nBuy>0)  { refId=idB; lvlOut=pB; return SIG_BUY; }
      if(nSell>0) { refId=idS; lvlOut=pS; return SIG_SELL; }
      return SIG_NO_TRADE;
   }

   int  ActiveCount() const { return m_nlv; }
   int  BarEventCount() const { return m_nb; }
   bool GetBarEvent(const int i,SNREvent &e) const { if(i<0||i>=m_nb) return false; e=m_bar[i]; return true; }
   int  LogCount() const { return m_nl; }
   bool GetLog(const int i,SNREvent &e) const { if(i<0||i>=m_nl) return false; e=m_log[i]; return true; }
   int  NextEventId() const { return m_nextEv; }
   int  LastSwingType() const { return m_lastType; }
};

//==================================================================
// MODULE: SNR DECISION  (events candle close -> BUY / SELL / NO TRADE)
//   Hanya break dengan count==1 (entry saat close, InpEntryOnTouch=false)
//   yang dihitung sebagai vote. Konflik di candle yang sama = NO TRADE.
//==================================================================
class CSNRDecision
{
public:
   SNRDecisionResult Decide(CSNREngine &eng)
   {
      SNRDecisionResult d;
      d.signal=SIG_NO_TRADE; d.buyVotes=0; d.sellVotes=0; d.ignored=0; d.reason="no breakout";

      for(int i=0;i<eng.BarEventCount();i++)
      {
         SNREvent e;
         if(!eng.GetBarEvent(i,e)) continue;
         if(e.kind!=EV_RES_BREAK && e.kind!=EV_SUP_BREAK) continue;
         if(e.count!=1) { d.ignored++; continue; }          // tanpa entry di close
         if(e.kind==EV_RES_BREAK) d.buyVotes++;
         else                     d.sellVotes++;
      }

      if(d.buyVotes>0 && d.sellVotes>0) { d.signal=SIG_NO_TRADE; d.reason="CONFLICT BUY vs SELL same candle"; }
      else if(d.buyVotes>0)             { d.signal=SIG_BUY;  d.reason=StringFormat("BUY votes=%d",d.buyVotes); }
      else if(d.sellVotes>0)            { d.signal=SIG_SELL; d.reason=StringFormat("SELL votes=%d",d.sellVotes); }
      else if(d.ignored>0)              { d.signal=SIG_NO_TRADE; d.reason=StringFormat("BRK tanpa entry di close (%d): sudah entry saat sentuh / level lama",d.ignored); }
      return d;
   }
};

//==================================================================
// MODULE: EXECUTION
//   SL = ATR x pengali (dibatasi min/max), TP = SL x RR.
//   Lot : manual, atau dari risiko % saldo acuan (tanpa compounding).
//==================================================================
class CExecutor
{
private:
   CTrade m_t;
   long   m_magic;
   double m_lot;
   int    m_maxSpread;
   double m_riskBase;

   double NormLot(double lot)
   {
      const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      const double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      const double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
      if(step>0) lot=MathFloor(lot/step+1e-8)*step;
      lot=MathMax(mn,MathMin(mx,lot));
      return NormalizeDouble(lot,8);
   }

   // Lot supaya kerugian saat SL kena = saldo acuan x risiko%.
   double RiskLot(const int slPts)
   {
      const double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv<=0.0) tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      if(ts<=0.0 || tv<=0.0 || m_riskBase<=0.0 || slPts<=0) return m_lot;
      const double lossPerLot=slPts*_Point/ts*tv;
      if(lossPerLot<=0.0) return m_lot;
      return (m_riskBase*InpRiskPercent/100.0)/lossPerLot;
   }

public:
   void Init(const long magic,const double lot,const int slip,const int maxSpread)
   {
      m_magic=magic; m_lot=lot; m_maxSpread=maxSpread;
      m_riskBase=(InpRiskBalance>0.0) ? InpRiskBalance : AccountInfoDouble(ACCOUNT_BALANCE);
      m_t.SetExpertMagicNumber((ulong)magic);
      m_t.SetDeviationInPoints((ulong)slip);
      m_t.SetTypeFillingBySymbol(_Symbol);
      Print(StringFormat("[EXEC] saldo acuan risiko = %.2f | risiko %.2f%% | lot dari risiko: %s",
            m_riskBase,InpRiskPercent,InpUseRiskLot?"ya":"tidak"));
   }

   // Posisi aktif milik Market Reader = Magic ini (+ simbol chart).
   bool HasActivePosition()
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         const ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetInteger(POSITION_MAGIC)==m_magic && PositionGetString(POSITION_SYMBOL)==_Symbol)
            return true;
      }
      return false;
   }

   bool Execute(const int signal,const double atrPts)
   {
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol,tk)) { Print("[EXEC] no tick"); return false; }
      const int    dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      const double spread=(tk.ask-tk.bid)/_Point;
      if(m_maxSpread>0 && spread>m_maxSpread)
      {
         Print(StringFormat("[EXEC] SKIP %s: spread %.1f > max %d",SignalName(signal),spread,m_maxSpread));
         return false;
      }

      if(atrPts<=0.0) { Print("[EXEC] SKIP: ATR belum siap"); return false; }
      const int slP=AtrSLPoints(atrPts,InpATRMultSL,InpATRMinSL,InpATRMaxSL);
      const int tpP=AtrTPPoints(slP,InpRR);
      if(slP<=0) { Print("[EXEC] SKIP: SL tidak valid"); return false; }

      double lot=NormLot(m_lot);
      if(InpUseRiskLot) lot=NormLot(RiskLot(slP));

      double sl=0.0, tp=0.0;
      bool ok=false;
      if(signal==SIG_BUY)
      {
         sl=NormalizeDouble(tk.ask-slP*_Point,dg);
         if(tpP>0) tp=NormalizeDouble(tk.ask+tpP*_Point,dg);
         ok=m_t.Buy(lot,_Symbol,0.0,sl,tp,"MR_SNR_P1");
      }
      else if(signal==SIG_SELL)
      {
         sl=NormalizeDouble(tk.bid+slP*_Point,dg);
         if(tpP>0) tp=NormalizeDouble(tk.bid-tpP*_Point,dg);
         ok=m_t.Sell(lot,_Symbol,0.0,sl,tp,"MR_SNR_P1");
      }
      Print(StringFormat("[EXEC] %s lot=%.2f slPts=%d tpPts=%d sl=%s tp=%s ok=%s retcode=%u (%s)",
            SignalName(signal),lot,slP,tpP,DoubleToString(sl,dg),DoubleToString(tp,dg),
            ok?"true":"false",m_t.ResultRetcode(),m_t.ResultRetcodeDescription()));
      return ok;
   }
};

//==================================================================
// GLOBALS
//==================================================================
CSNREngine   g_engine;
CSNRDecision g_decision;
CExecutor    g_exec;
CATR         g_atr;

bool     g_ready        = false;
datetime g_lastBar0     = 0;      // open time bar berjalan (TradeTF) saat terakhir diproses
datetime g_lastProc     = 0;      // open time candle closed terakhir yang diproses engine
int      g_lastEv       = 0;      // id event terakhir yang sudah diperiksa untuk tanda
int      g_markSeq      = 0;      // nomor urut tanda SH/SL di chart
string   g_lastDecision = "-";
string   g_scanText     = "";     // teks scanner untuk panel

// --- scanner ---
struct SBook   // statistik satu kombinasi pada satu skenario (pesimis / optimis)
{
   int    n, win, cw, cl, curW, curL;
   int    n1, w1, n2, w2;      // jumlah trade & menang di paruh lama (1) dan baru (2)
   double cum, peak, dd;
};

struct SEvent  // satu titik entry potensial
{
   int      j0;      // indeks langkah harga tempat entry (touch) / langkah pertama setelah entry (close)
   int      dir;     // +1 BUY, -1 SELL
   double   level;   // harga entry (BUY: ditambah spread saat evaluasi)
   datetime t;       // waktu
   int      cv;      // indeks nilai C (candle konfirmasi)
   int      sp;      // spread saat entry (points)
   bool     touch;   // true = entry saat sentuh (langkah entry ikut dicek), false = entry saat close
};

int         g_scState   = 0;     // 0 off | 1 siapkan | 2 muat M1 | 3 cari titik entry | 4 hitung | 5 selesai | 6 gagal
int         g_perVal[];          // daftar periode ATR
int         g_nPer      = 0;
int         g_pMax      = 0;
int         g_cvVal[];           // daftar nilai C
int         g_nCv       = 0;
int         g_cCv[];             // indeks C tiap kombinasi
int         g_cPer[];            // indeks periode tiap kombinasi
double      g_cMul[];
double      g_cRR[];
int         g_cMin[];
int         g_cMax[];
int         g_nC        = 0;
int         g_cvFrom[];          // rentang kombinasi tiap nilai C (awal, termasuk)
int         g_cvTo[];            // rentang kombinasi tiap nilai C (akhir, tidak termasuk)
int         g_D         = 0;     // SL maksimum yang mungkin (points)
int         g_Tm        = 0;     // TP maksimum yang mungkin (points)
int         g_defSpread = 0;

MqlRates    g_sTF[];             // candle TF (+ warm-up)
int         g_sNTF      = 0;
double      g_sTRcum[];
int         g_iStart    = 0;

datetime    g_sT[];              // langkah harga (M1 atau candle TF)
double      g_sH[], g_sL[];
int         g_sSp[];
int         g_sN        = 0;
bool        g_stepsM1   = false;

datetime    g_effFrom   = 0, g_effTo = 0, g_tMid = 0, g_ldT = 0;
int         g_ldTry     = 0;

CSNREngine *g_eng[];             // satu engine per nilai C
SEvent      g_sEv[];
int         g_sNEv      = 0;
double      g_sEvAtr[];
int         g_gi        = 0;     // candle TF yang sedang diproses
int         g_gp        = 0;     // pointer langkah harga
int         g_ei        = 0;     // titik entry yang sedang dihitung

SBook       g_bkP[], g_bkO[];
int         g_busyP[], g_busyO[];
int         g_tabAdvA[], g_tabAdvB[], g_tabFav[];

void UpdatePanel();

//==================================================================
// UTIL
//==================================================================
void ToBar(const MqlRates &r,SNRBar &b)
{
   b.time=r.time;
   b.open=NormalizeDouble(r.open,_Digits);
   b.high=NormalizeDouble(r.high,_Digits);
   b.low=NormalizeDouble(r.low,_Digits);
   b.close=NormalizeDouble(r.close,_Digits);
}

bool ShouldDraw()
{
   return (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE));
}

string LastSwingText()
{
   const int t=g_engine.LastSwingType();
   if(t==ZT_RESISTANCE) return "SH (menunggu SL)";
   if(t==ZT_SUPPORT)    return "SL (menunggu SH)";
   return "-";
}

//==================================================================
// SCANNER ATR  (gaya Scanner_PinchedCandle)
//   1) muat candle TF (+ warm-up) dan M1 pada rentang waktu
//   2) putar ulang engine SNR per nilai C -> kumpulkan titik entry
//      (entry saat sentuh / saat close, aturan sama dengan EA)
//   3) tiap titik entry dihitung untuk SEMUA kombinasi lewat tabel
//      "langkah pertama harga mencapai jarak d"
//   4) peringkat berdasarkan Edge = WR - BE, BE = 100 / (1 + RR)
//
//   PESIMIS : SL & TP sama-sama mungkin -> SL dulu; langkah entry dicek SL.
//   OPTIMIS : SL & TP sama-sama mungkin -> TP dulu; langkah entry SL diabaikan.
//   Hasil sebenarnya ada di antara keduanya.
//   Harga: BUY masuk di level + spread, keluar di bid; SELL masuk di
//   level (bid), keluar di ask (High/Low + spread).
//==================================================================
double ScNegDD(const double d) { return (d>0.0) ? -d : 0.0; }

double ScPick(const double p,const double o)
{
   if(InpScanRank==RANK_EDGE_PES) return p;
   if(InpScanRank==RANK_EDGE_OPT) return o;
   return 0.5*(p+o);
}

string ScRankName()
{
   if(InpScanRank==RANK_EDGE_PES) return "edge WR pesimis";
   if(InpScanRank==RANK_EDGE_OPT) return "edge WR optimis";
   return "edge WR rata-rata";
}

int ScBuildInts(const int from,const int to,int step,int &out[])
{
   ArrayResize(out,0);
   if(step<1) step=1;
   int k=0;
   for(int v=MathMax(from,1);v<=to && k<2000;v+=step)
   {
      ArrayResize(out,k+1);
      out[k]=v;
      k++;
   }
   return k;
}

int ScBuildDbls(const double from,const double to,const double step,double &out[])
{
   ArrayResize(out,0);
   int k=0;
   for(int i=0;i<2000;i++)
   {
      double v=(step>0.0) ? from+i*step : from;
      if(v>to+1e-9) break;
      if(v>0.0)
      {
         ArrayResize(out,k+1);
         out[k]=NormalizeDouble(v,4);
         k++;
      }
      if(step<=0.0) break;
   }
   return k;
}

string ScLabel(const int c)
{
   return StringFormat("%dC P%d x%.2f RR%.2f SL%d-%d",g_cvVal[g_cCv[c]],g_perVal[g_cPer[c]],
                       g_cMul[c],g_cRR[c],g_cMin[c],g_cMax[c]);
}

// WR breakeven (%) untuk RR tertentu
double ScBE(const double rr) { return 100.0/(1.0+rr); }

// Edge = WR - WR breakeven (poin persen). Di atas 0 = di atas breakeven
double ScEdgeOf(const int n,const int w,const double rr)
{
   if(n<=0) return 0.0;
   return 100.0*w/n-ScBE(rr);
}

double ScEdgeP(const int c) { return ScEdgeOf(g_bkP[c].n,g_bkP[c].win,g_cRR[c]); }
double ScEdgeO(const int c) { return ScEdgeOf(g_bkO[c].n,g_bkO[c].win,g_cRR[c]); }
double ScScore(const int c) { return ScPick(ScEdgeP(c),ScEdgeO(c)); }

string ScHeader()
{
   return StringFormat("Scanner ATR  : C %s | TF %s | Multi %s | Spread<=%d\nRentang      : ATR %d-%d (+%d) | x%.2f-%.2f (+%.2f) | RR %.2f-%.2f (+%.2f)\nSL min %d-%d (+%d) | SL max %d-%d (+%d)\nWaktu        : %s - %s\n",
                       InpScanC,EnumToString(InpTradeTimeframe),InpAllowEntryWithPosition?"ON":"OFF",InpMaxSpreadPoints,
                       InpScanATRFrom,InpScanATRTo,InpScanATRStep,
                       InpScanMultFrom,InpScanMultTo,InpScanMultStep,
                       InpScanRRFrom,InpScanRRTo,InpScanRRStep,
                       InpScanSLMinFrom,InpScanSLMinTo,InpScanSLMinStep,
                       InpScanSLMaxFrom,InpScanSLMaxTo,InpScanSLMaxStep,
                       FmtDate(InpScanFrom),FmtDate(InpScanTo));
}

void ScShow(const string body)
{
   g_scanText=ScHeader()+body;
   UpdatePanel();
}

void ScFreeEngines()
{
   for(int i=0;i<ArraySize(g_eng);i++)
      if(CheckPointer(g_eng[i])==POINTER_DYNAMIC) delete g_eng[i];
   ArrayFree(g_eng);
}

void ScanFree()
{
   ScFreeEngines();
   ArrayFree(g_sTF);   ArrayFree(g_sTRcum);
   ArrayFree(g_sT);    ArrayFree(g_sH);   ArrayFree(g_sL);  ArrayFree(g_sSp);
   ArrayFree(g_sEv);   ArrayFree(g_sEvAtr);
   ArrayFree(g_bkP);   ArrayFree(g_bkO);  ArrayFree(g_busyP); ArrayFree(g_busyO);
   ArrayFree(g_tabAdvA); ArrayFree(g_tabAdvB); ArrayFree(g_tabFav);
}

void ScFail(const string msg)
{
   g_scState=6;
   EventKillTimer();
   Print("[SCAN] ",msg);
   ScanFree();
   ScShow("=== SCAN ATR (R) ===\n"+msg+"\n");
}

//+------------------------------------------------------------------+
//| Susun daftar kombinasi                                           |
//+------------------------------------------------------------------+
bool ScanInit()
{
   g_scState=0;
   g_scanText="";
   if(InpScanFrom>=InpScanTo)
   {
      ScFail("Tanggal 'dari' harus lebih awal dari 'sampai'.");
      return false;
   }

   int cs[];
   g_nCv=ParsePoints(InpScanC,cs);
   if(g_nCv>4) g_nCv=4;
   if(g_nCv<=0)
   {
      ScFail("Daftar candle konfirmasi (InpScanC) tidak valid.");
      return false;
   }
   ArrayResize(g_cvVal,g_nCv);
   for(int i=0;i<g_nCv;i++) g_cvVal[i]=cs[i];

   double mul[], rr[];
   int    smin[], smax[];
   g_nPer=ScBuildInts(InpScanATRFrom,InpScanATRTo,InpScanATRStep,g_perVal);
   const int nm=ScBuildDbls(InpScanMultFrom,InpScanMultTo,InpScanMultStep,mul);
   const int nr=ScBuildDbls(InpScanRRFrom,InpScanRRTo,InpScanRRStep,rr);
   const int n1=ScBuildInts(InpScanSLMinFrom,InpScanSLMinTo,InpScanSLMinStep,smin);
   const int n2=ScBuildInts(InpScanSLMaxFrom,InpScanSLMaxTo,InpScanSLMaxStep,smax);

   if(g_nPer<=0 || nm<=0 || nr<=0 || n1<=0 || n2<=0)
   {
      ScFail("Rentang scanner tidak valid (ada daftar yang kosong).");
      return false;
   }

   const double total=(double)g_nCv*g_nPer*nm*nr*n1*n2;
   if(total>500000.0)
   {
      ScFail(StringFormat("Terlalu banyak kombinasi (%.0f, maks 500000). Perbesar langkah atau perkecil rentang.",total));
      return false;
   }

   ArrayResize(g_cCv,0); ArrayResize(g_cPer,0); ArrayResize(g_cMul,0); ArrayResize(g_cRR,0);
   ArrayResize(g_cMin,0); ArrayResize(g_cMax,0);
   ArrayResize(g_cvFrom,g_nCv); ArrayResize(g_cvTo,g_nCv);
   g_nC=0;
   for(int v=0;v<g_nCv;v++)
   {
      g_cvFrom[v]=g_nC;
      for(int a=0;a<g_nPer;a++)
         for(int b=0;b<nm;b++)
            for(int c=0;c<nr;c++)
               for(int d=0;d<n1;d++)
                  for(int e=0;e<n2;e++)
                  {
                     if(smin[d]>smax[e]) continue;   // SL min tidak boleh melebihi SL max
                     ArrayResize(g_cCv, g_nC+1,4096);
                     ArrayResize(g_cPer,g_nC+1,4096);
                     ArrayResize(g_cMul,g_nC+1,4096);
                     ArrayResize(g_cRR, g_nC+1,4096);
                     ArrayResize(g_cMin,g_nC+1,4096);
                     ArrayResize(g_cMax,g_nC+1,4096);
                     g_cCv[g_nC]=v;
                     g_cPer[g_nC]=a;
                     g_cMul[g_nC]=mul[b];
                     g_cRR[g_nC]=rr[c];
                     g_cMin[g_nC]=smin[d];
                     g_cMax[g_nC]=smax[e];
                     g_nC++;
                  }
      g_cvTo[v]=g_nC;
   }

   if(g_nC<=0)
   {
      ScFail("Tidak ada kombinasi valid (SL minimum selalu lebih besar dari SL maksimum).");
      return false;
   }

   g_pMax=0;
   for(int i=0;i<g_nPer;i++) g_pMax=MathMax(g_pMax,g_perVal[i]);

   int maxSL=0; double maxRR=0.0;
   for(int i=0;i<g_nC;i++)
   {
      maxSL=MathMax(maxSL,g_cMax[i]);
      maxRR=MathMax(maxRR,g_cRR[i]);
   }
   g_D=MathMax(maxSL,1);
   g_Tm=(int)MathCeil(g_D*maxRR)+2;
   g_defSpread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   ArrayResize(g_bkP,g_nC);   ArrayResize(g_bkO,g_nC);
   ArrayResize(g_busyP,g_nC); ArrayResize(g_busyO,g_nC);
   ArrayResize(g_tabAdvA,g_D+2);
   ArrayResize(g_tabAdvB,g_D+2);
   ArrayResize(g_tabFav,g_Tm+2);

   g_ldTry=0;
   g_scState=1;
   PrintFormat("[SCAN] %d kombinasi (%d nilai C, %d periode ATR) | TF %s | %s - %s",
               g_nC,g_nCv,g_nPer,EnumToString(InpTradeTimeframe),FmtDate(InpScanFrom),FmtDate(InpScanTo));
   ScShow("Menyiapkan data...\n");
   return true;
}

//+------------------------------------------------------------------+
void ScanTimer()
{
   switch(g_scState)
   {
      case 1: ScanPrepare();   break;
      case 2: ScanLoadM1();    break;
      case 3: ScanGenerate();  break;
      case 4: ScanEvaluate();  break;
   }
}

//+------------------------------------------------------------------+
//| Langkah 1: muat candle TF (+ warm-up) dan hitung kumulatif TR    |
//+------------------------------------------------------------------+
void ScanPrepare()
{
   const ENUM_TIMEFRAMES tf=InpTradeTimeframe;
   const bool useM1=(InpScanUseM1 && tf!=PERIOD_M1);

   Bars(_Symbol,tf);                          // memicu pembuatan series
   if(useM1) Bars(_Symbol,PERIOD_M1);
   if(!(bool)SeriesInfoInteger(_Symbol,tf,SERIES_SYNCHRONIZED) ||
      (useM1 && !(bool)SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED)))
   {
      g_ldTry++;
      if(g_ldTry>600) { ScFail("Data history tidak kunjung siap."); return; }
      ScShow("Menunggu data history...\n");
      return;
   }

   const ENUM_TIMEFRAMES ref=useM1 ? PERIOD_M1 : tf;
   datetime first=(datetime)SeriesInfoInteger(_Symbol,ref,SERIES_SERVER_FIRSTDATE);
   if(first<=0) first=(datetime)SeriesInfoInteger(_Symbol,ref,SERIES_FIRSTDATE);

   g_effFrom=InpScanFrom;
   if(first>g_effFrom) g_effFrom=first;
   g_effTo=InpScanTo;
   if(TimeCurrent()<g_effTo) g_effTo=TimeCurrent();
   if(g_effFrom>=g_effTo) { ScFail("Rentang waktu tidak valid atau data belum ada."); return; }

   const int tfSec=PeriodSeconds(tf);
   const long wb=(long)MathMax(MathMax(InpWarmupBars,10),g_pMax+10);
   const datetime warm=g_effFrom-(datetime)(wb*3*tfSec);

   ArraySetAsSeries(g_sTF,false);
   int n=CopyRates(_Symbol,tf,warm,g_effTo,g_sTF);
   if(n<g_pMax+10)
   {
      g_ldTry++;
      if(g_ldTry>600) { ScFail("Candle TF tidak cukup untuk rentang yang diminta."); return; }
      ScShow("Memuat candle TF...\n");
      return;
   }
   if(g_sTF[n-1].time+tfSec>TimeCurrent()) n--;   // buang candle yang masih berjalan
   g_sNTF=n;

   //--- kumulatif True Range (ATR = rata-rata sederhana TR, sama dengan EA live)
   ArrayResize(g_sTRcum,n);
   double cum=0.0;
   for(int k=0;k<n;k++)
   {
      double tr=g_sTF[k].high-g_sTF[k].low;
      if(k>0)
      {
         const double pc=g_sTF[k-1].close;
         tr=MathMax(tr,MathMax(MathAbs(g_sTF[k].high-pc),MathAbs(g_sTF[k].low-pc)));
      }
      cum+=tr;
      g_sTRcum[k]=cum;
   }

   int iStart=0;
   while(iStart<n && g_sTF[iStart].time<g_effFrom) iStart++;
   if(iStart<g_pMax+3) iStart=g_pMax+3;
   if(iStart>=n-2) { ScFail("Data candle TF tidak cukup di rentang waktu ini."); return; }
   g_iStart=iStart;
   g_effFrom=g_sTF[iStart].time;

   g_sN=0;
   g_ldTry=0;
   if(useM1)
   {
      g_ldT=g_effFrom;
      g_scState=2;
      ScShow("Memuat M1...\n");
   }
   else
   {
      ScBuildStepsFromTF();
      ScStartGenerate();
   }
}

//+------------------------------------------------------------------+
void ScAppendStep(const datetime t,const double h,const double l,const int sp)
{
   ArrayResize(g_sT, g_sN+1,600000);
   ArrayResize(g_sH, g_sN+1,600000);
   ArrayResize(g_sL, g_sN+1,600000);
   ArrayResize(g_sSp,g_sN+1,600000);
   g_sT[g_sN]=t; g_sH[g_sN]=h; g_sL[g_sN]=l; g_sSp[g_sN]=sp;
   g_sN++;
}

void ScBuildStepsFromTF()
{
   g_sN=0;
   g_stepsM1=false;
   const int cnt=g_sNTF-g_iStart;
   ArrayResize(g_sT, cnt);
   ArrayResize(g_sH, cnt);
   ArrayResize(g_sL, cnt);
   ArrayResize(g_sSp,cnt);
   for(int k=g_iStart;k<g_sNTF;k++)
   {
      g_sT[g_sN]=g_sTF[k].time;
      g_sH[g_sN]=g_sTF[k].high;
      g_sL[g_sN]=g_sTF[k].low;
      g_sSp[g_sN]=g_sTF[k].spread;
      g_sN++;
   }
}

//+------------------------------------------------------------------+
//| Langkah 2: muat M1 bertahap (blok 90 hari)                       |
//+------------------------------------------------------------------+
void ScanLoadM1()
{
   const uint t0=GetTickCount();
   while(g_ldT<g_effTo && (GetTickCount()-t0)<150)
   {
      datetime ce=g_ldT+(datetime)(90*86400-1);
      if(ce>g_effTo) ce=g_effTo;

      MqlRates r[];
      ArraySetAsSeries(r,false);
      int n=CopyRates(_Symbol,PERIOD_M1,g_ldT,ce,r);
      if(n<=0)
      {
         g_ldTry++;
         if(g_ldTry<=40)
         {
            ScShow(StringFormat("Memuat M1: %s (menunggu data, coba %d)...\n",FmtDate(g_ldT),g_ldTry));
            return;
         }
         n=0;   // dianggap kosong, lanjut ke blok berikutnya
      }
      g_ldTry=0;
      for(int k=0;k<n;k++)
         ScAppendStep(r[k].time,r[k].high,r[k].low,r[k].spread);
      g_ldT=ce+1;
   }

   if(g_ldT<g_effTo)
   {
      const double pct=100.0*(double)(g_ldT-g_effFrom)/(double)MathMax((long)(g_effTo-g_effFrom),1);
      ScShow(StringFormat("Memuat M1 %.0f%% (%s) | %d candle\n",pct,FmtDate(g_ldT),g_sN));
      return;
   }

   if(g_sN<100)
   {
      Print("[SCAN] Data M1 tidak cukup -> memakai candle TF.");
      g_sN=0;
      ScBuildStepsFromTF();
   }
   else
      g_stepsM1=true;
   ScStartGenerate();
}

//+------------------------------------------------------------------+
void ScStartGenerate()
{
   g_tMid=g_sT[0]+(datetime)((long)(g_sT[g_sN-1]-g_sT[0])/2);

   ScFreeEngines();
   ArrayResize(g_eng,g_nCv);
   for(int e=0;e<g_nCv;e++)
   {
      g_eng[e]=new CSNREngine;
      g_eng[e].Init(false,InpMaxZonesTracked,g_cvVal[e],InpEntryLatestOnly,InpEntryOnTouch);
      g_eng[e].SetQuiet(true);
   }

   g_gi=0;          // engine dipanaskan dari awal candle (warm-up)
   g_gp=0;
   g_sNEv=0;
   ArrayResize(g_sEv,0);
   ArrayResize(g_sEvAtr,0);
   g_scState=3;
}

int ScSpreadAt(const int j)
{
   const int sp=g_sSp[j];
   return (sp>0) ? sp : g_defSpread;
}

//+------------------------------------------------------------------+
//| Langkah 3: putar ulang engine, kumpulkan titik entry             |
//+------------------------------------------------------------------+
// ci = indeks candle closed terakhir yang ikut ATR
void ScAddEvent(const int cv,const int dir,const double lv,const int j,const int ci,
                const int sp,const bool touch)
{
   ArrayResize(g_sEv,g_sNEv+1,4096);
   g_sEv[g_sNEv].j0=j;
   g_sEv[g_sNEv].dir=dir;
   g_sEv[g_sNEv].level=NormalizeDouble(lv,_Digits);
   g_sEv[g_sNEv].t=g_sT[j];
   g_sEv[g_sNEv].cv=cv;
   g_sEv[g_sNEv].sp=sp;
   g_sEv[g_sNEv].touch=touch;

   ArrayResize(g_sEvAtr,(g_sNEv+1)*g_nPer,65536);
   for(int ip=0;ip<g_nPer;ip++)
   {
      const int p=g_perVal[ip];
      const double a=(g_sTRcum[ci]-g_sTRcum[ci-p])/p/_Point;
      g_sEvAtr[g_sNEv*g_nPer+ip]=a;
   }
   g_sNEv++;
}

void ScProcessCandle(const int i)
{
   SNRBar b;
   ToBar(g_sTF[i],b);

   const bool inRange=(i>=g_iStart);
   const int  tfSec=PeriodSeconds(InpTradeTimeframe);

   if(inRange)
   {
      const datetime tS=g_sTF[i].time;
      const datetime tE=(i+1<g_sNTF) ? g_sTF[i+1].time : tS+(datetime)tfSec;
      while(g_gp<g_sN && g_sT[g_gp]<tS) g_gp++;

      // entry saat sentuh: tiap langkah harga di dalam candle ini
      // (struktur = kondisi sebelum candle ini close; ATR = candle sebelumnya)
      if(InpEntryOnTouch)
      {
         for(int j=g_gp;j<g_sN && g_sT[j]<tE;j++)
         {
            const int sp=ScSpreadAt(j);
            for(int e=0;e<g_nCv;e++)
            {
               int refId=0;
               double lvl=0.0;
               const int sig=g_eng[e].CheckTouchBar(g_sH[j],g_sL[j],refId,lvl);
               if(sig==SIG_NO_TRADE) continue;
               if(InpMaxSpreadPoints>0 && sp>InpMaxSpreadPoints) continue;   // level tetap terpakai
               ScAddEvent(e,(sig==SIG_BUY)?1:-1,lvl,j,i-1,sp,true);
            }
         }
      }
      while(g_gp<g_sN && g_sT[g_gp]<tE) g_gp++;   // g_gp = langkah pertama candle berikutnya
   }

   // candle close: struktur diperbarui (BRK, swing darurat, rantai) per engine
   for(int e=0;e<g_nCv;e++)
   {
      g_eng[e].OnClosedBar(b);

      if(!InpEntryOnTouch && inRange)
      {
         const SNRDecisionResult d=g_decision.Decide(g_eng[e]);
         if(d.signal!=SIG_NO_TRADE && g_gp<g_sN)
         {
            int sp=g_sTF[i].spread;
            if(sp<=0) sp=g_defSpread;
            if(InpMaxSpreadPoints<=0 || sp<=InpMaxSpreadPoints)
               ScAddEvent(e,(d.signal==SIG_BUY)?1:-1,b.close,g_gp,i,sp,false);   // ATR termasuk candle ini
         }
      }
   }
}

void ScanGenerate()
{
   const uint t0=GetTickCount();
   while(g_gi<g_sNTF && (GetTickCount()-t0)<150)
   {
      ScProcessCandle(g_gi);
      g_gi++;
   }

   if(g_gi<g_sNTF)
   {
      const double pct=100.0*g_gi/MathMax(g_sNTF,1);
      ScShow(StringFormat("Mencari titik entry %.0f%% (%d/%d candle) | %d entry\n",
                          pct,g_gi,g_sNTF,g_sNEv));
      return;
   }

   ScFreeEngines();
   ArrayFree(g_sTF);
   ArrayFree(g_sTRcum);

   if(g_sNEv<=0) { ScFail("Tidak ada titik entry pada rentang waktu ini."); return; }

   for(int c=0;c<g_nC;c++)
   {
      ZeroMemory(g_bkP[c]);
      ZeroMemory(g_bkO[c]);
      g_busyP[c]=-1;
      g_busyO[c]=-1;
   }
   g_ei=0;
   g_scState=4;
}

//+------------------------------------------------------------------+
//| Langkah 4: hitung semua kombinasi untuk tiap titik entry         |
//+------------------------------------------------------------------+
void ScAcc(SBook &b,const double r,const datetime t)
{
   const bool h1=(t<g_tMid);
   b.n++;
   if(h1) b.n1++; else b.n2++;
   if(r>0.0)
   {
      b.win++; b.curW++; b.curL=0;
      if(b.curW>b.cw) b.cw=b.curW;
      if(h1) b.w1++; else b.w2++;
   }
   else
   {
      b.curL++; b.curW=0;
      if(b.curL>b.cl) b.cl=b.curL;
   }
   b.cum+=r;
   if(b.cum>b.peak) b.peak=b.cum;
   if(b.peak-b.cum>b.dd) b.dd=b.peak-b.cum;
}

// Kombinasi boleh entry? busy = langkah tempat posisi sebelumnya selesai.
//  touch : exit diproses sebelum sentuhan pada langkah yang sama -> j0 >= busy
//  close : keputusan diambil saat candle close, posisi yang selesai di langkah
//          pertama candle berikutnya masih terbuka -> j0 > busy
bool ScFree(const int busy,const int j0,const bool touch)
{
   if(InpAllowEntryWithPosition) return true;
   return touch ? (j0>=busy) : (j0>busy);
}

void ScanEvalEvent(const int e)
{
   const int cv=g_sEv[e].cv;
   const int c0=g_cvFrom[cv], c1=g_cvTo[cv];
   if(c0>=c1) return;

   const int      j0=g_sEv[e].j0;
   const bool     buy=(g_sEv[e].dir>0);
   const bool     touch=g_sEv[e].touch;
   const double   entry=buy ? g_sEv[e].level+g_sEv[e].sp*_Point : g_sEv[e].level;
   const datetime tEv=g_sEv[e].t;

   // ada kombinasi yang bebas untuk entry ini?
   bool any=false;
   for(int c=c0;c<c1 && !any;c++)
      if(ScFree(g_busyP[c],j0,touch) || ScFree(g_busyO[c],j0,touch)) any=true;
   if(!any) return;

   //--- jalur harga setelah entry: langkah pertama mencapai jarak d (points) untuk tiap d
   ArrayInitialize(g_tabAdvA,SC_NONE);   // sisi rugi, termasuk langkah entry (pesimis)
   ArrayInitialize(g_tabAdvB,SC_NONE);   // sisi rugi, tanpa langkah entry (optimis)
   ArrayInitialize(g_tabFav, SC_NONE);   // sisi untung

   int curA=0, curB=0, curF=0;
   for(int j=j0;j<g_sN;j++)
   {
      const double spd=ScSpreadAt(j)*_Point;
      double favp, advp;
      if(buy)
      {
         favp=(g_sH[j]-entry)/_Point;
         advp=(entry-g_sL[j])/_Point;
      }
      else
      {
         favp=(entry-(g_sL[j]+spd))/_Point;
         advp=((g_sH[j]+spd)-entry)/_Point;
      }
      const int fa=(int)MathFloor(favp+1e-6);
      const int aa=(int)MathFloor(advp+1e-6);

      if(fa>curF)
      {
         const int up=MathMin(fa,g_Tm);
         for(int d=curF+1;d<=up;d++) g_tabFav[d]=j;
         curF=fa;
      }
      if(aa>curA)
      {
         const int up=MathMin(aa,g_D);
         for(int d=curA+1;d<=up;d++) g_tabAdvA[d]=j;
         curA=aa;
      }
      if((j>j0 || !touch) && aa>curB)
      {
         const int up=MathMin(aa,g_D);
         for(int d=curB+1;d<=up;d++) g_tabAdvB[d]=j;
         curB=aa;
      }
      if(curB>=g_D) break;     // semua SL yang mungkin sudah terkena
   }

   const int nPer=g_nPer;
   for(int c=c0;c<c1;c++)
   {
      const bool actP=ScFree(g_busyP[c],j0,touch);
      const bool actO=ScFree(g_busyO[c],j0,touch);
      if(!actP && !actO) continue;

      //--- SL/TP persis seperti EA live (AtrSLPoints / AtrTPPoints)
      const double a=g_sEvAtr[e*nPer+g_cPer[c]];
      int sl=AtrSLPoints(a,g_cMul[c],g_cMin[c],g_cMax[c]);
      if(sl<1) sl=1;
      if(sl>g_D) sl=g_D;
      int tp=AtrTPPoints(sl,g_cRR[c]);
      if(tp<1) tp=1;
      if(tp>g_Tm) tp=g_Tm;
      const double rTP=(double)tp/(double)sl;

      const int jS=g_tabAdvA[sl];
      const int jT=g_tabFav[tp];

      if(actP)
      {
         if(jS==SC_NONE && jT==SC_NONE) g_busyP[c]=SC_NONE;       // belum selesai
         else if(jS<=jT) { ScAcc(g_bkP[c],-1.0,tEv); g_busyP[c]=jS; }
         else            { ScAcc(g_bkP[c],rTP,tEv);  g_busyP[c]=jT; }
      }
      if(actO)
      {
         const int jS2=g_tabAdvB[sl];
         if(jS2==SC_NONE && jT==SC_NONE) g_busyO[c]=SC_NONE;
         else if(jT<=jS2) { ScAcc(g_bkO[c],rTP,tEv);  g_busyO[c]=jT; }
         else             { ScAcc(g_bkO[c],-1.0,tEv); g_busyO[c]=jS2; }
      }
   }
}

void ScanEvaluate()
{
   const uint t0=GetTickCount();
   while(g_ei<g_sNEv && (GetTickCount()-t0)<150)
   {
      ScanEvalEvent(g_ei);
      g_ei++;
   }

   if(g_ei<g_sNEv)
   {
      ScShow(StringFormat("Menghitung %.0f%% (%d/%d entry) x %d kombinasi\n",
                          100.0*g_ei/g_sNEv,g_ei,g_sNEv,g_nC));
      return;
   }
   ScanFinish();
}

//+------------------------------------------------------------------+
//| Langkah 5: peringkat (Edge = WR - BE), Journal, dan panel        |
//+------------------------------------------------------------------+
void ScanFinish()
{
   g_scState=5;
   EventKillTimer();

   bool picked[];
   ArrayResize(picked,g_nC);
   ArrayInitialize(picked,false);

   int ne=0;
   for(int c=0;c<g_nC;c++)
      if(g_bkP[c].n>=InpScanMinTrades) ne++;

   const int wantK=MathMax(MathMax(InpScanTop,1),InpScanJournalTop);
   const int K=MathMin(ne,wantK);
   int idx[];
   ArrayResize(idx,K);
   for(int r=0;r<K;r++)
   {
      int best=-1;
      double bs=-1e18;
      for(int c=0;c<g_nC;c++)
      {
         if(picked[c] || g_bkP[c].n<InpScanMinTrades) continue;
         const double sc=ScScore(c);
         if(sc>bs) { bs=sc; best=c; }
      }
      idx[r]=best;
      if(best>=0) picked[best]=true;
   }

   const string res=g_stepsM1 ? "M1 di dalam candle" : "candle TF (tanpa M1)";
   const string dFrom=FmtDate(g_sT[0]);
   const string dTo=FmtDate(g_sT[g_sN-1]);

   //--- Journal
   PrintFormat("[SCAN] selesai | %d kombinasi | %d entry | %d lolos minimal %d trade | peringkat %s | resolusi %s | data %s - %s",
               g_nC,g_sNEv,ne,InpScanMinTrades,ScRankName(),res,dFrom,dTo);
   const int jr=MathMin(K,InpScanJournalTop);
   for(int r=0;r<jr;r++)
   {
      const int c=idx[r];
      const double rr=g_cRR[c];
      PrintFormat("[SCAN] #%d %s | N %d/%d | WR %.1f/%.1f%% | BE %.1f%% | Edge %+.1f/%+.1f | DD %.1f/%.1fR | CW %d/%d | CL %d/%d | H pes %+.1f/%+.1f opt %+.1f/%+.1f",
         r+1,ScLabel(c),g_bkP[c].n,g_bkO[c].n,
         100.0*g_bkP[c].win/MathMax(g_bkP[c].n,1),100.0*g_bkO[c].win/MathMax(g_bkO[c].n,1),
         ScBE(rr),ScEdgeP(c),ScEdgeO(c),
         ScNegDD(g_bkP[c].dd),ScNegDD(g_bkO[c].dd),
         g_bkP[c].cw,g_bkO[c].cw,g_bkP[c].cl,g_bkO[c].cl,
         ScEdgeOf(g_bkP[c].n1,g_bkP[c].w1,rr),ScEdgeOf(g_bkP[c].n2,g_bkP[c].w2,rr),
         ScEdgeOf(g_bkO[c].n1,g_bkO[c].w1,rr),ScEdgeOf(g_bkO[c].n2,g_bkO[c].w2,rr));
   }

   //--- Panel
   string s=StringFormat("=== SCAN ATR (R) | peringkat %s ===\n",ScRankName());
   if(ne<=0)
      s+=StringFormat("Belum ada kombinasi dengan >= %d trade\n",InpScanMinTrades);
   else
   {
      s+=StringFormat("Data: %s - %s (TF %s | %s)\n",dFrom,dTo,EnumToString(InpTradeTimeframe),res);
      s+="format: pesimis~optimis | BE = WR breakeven | E = WR - BE | H = E paruh lama/baru\n";
      const int top=MathMin(MathMax(InpScanTop,1),K);
      for(int r=0;r<top;r++)
      {
         const int c=idx[r];
         const double rr=g_cRR[c];
         s+=StringFormat("#%d %s | %dt | WR %.0f~%.0f%% | BE %.0f%% | E %+.1f~%+.1f | DD %.0f~%.0fR | H %+.1f/%+.1f\n",
            r+1,ScLabel(c),g_bkP[c].n,
            100.0*g_bkP[c].win/MathMax(g_bkP[c].n,1),100.0*g_bkO[c].win/MathMax(g_bkO[c].n,1),
            ScBE(rr),ScEdgeP(c),ScEdgeO(c),
            ScNegDD(g_bkP[c].dd),ScNegDD(g_bkO[c].dd),
            ScPick(ScEdgeOf(g_bkP[c].n1,g_bkP[c].w1,rr),ScEdgeOf(g_bkO[c].n1,g_bkO[c].w1,rr)),
            ScPick(ScEdgeOf(g_bkP[c].n2,g_bkP[c].w2,rr),ScEdgeOf(g_bkO[c].n2,g_bkO[c].w2,rr)));
      }
   }
   s+=StringFormat("%d kombinasi | %d entry | daftar teratas di Journal (tab Experts)\n",g_nC,g_sNEv);
   s+="Hasil sebenarnya ada di antara pesimis & optimis\n";
   ScShow(s);

   // bebaskan memori besar (teks panel sudah jadi)
   ArrayFree(g_sT);  ArrayFree(g_sH);  ArrayFree(g_sL);  ArrayFree(g_sSp);
   ArrayFree(g_sEv); ArrayFree(g_sEvAtr);
   ArrayFree(g_bkP); ArrayFree(g_bkO); ArrayFree(g_busyP); ArrayFree(g_busyO);
   ArrayFree(g_tabAdvA); ArrayFree(g_tabAdvB); ArrayFree(g_tabFav);
}

//==================================================================
// PANEL (Comment): status EA + scanner
//==================================================================
void UpdatePanel()
{
   if(!ShouldDraw()) return;

   const double ap=g_atr.Points();
   const int slNow=(ap>0.0) ? AtrSLPoints(ap,InpATRMultSL,InpATRMinSL,InpATRMaxSL) : 0;

   string txt=StringFormat("MARKET READER P1 SNR BREAKOUT v4.36 | TF %s\nSwing: %d candle konfirmasi | terakhir: %s | level aktif %d\nEntry: %s | %s | posisi: %s\nSL/TP: ATR %d x%.2f RR %.2f SL %d-%d | ATR %.0f pts -> SL %d pts\nLast : %s",
           EnumToString(InpTradeTimeframe),
           InpConfirmBars,LastSwingText(),g_engine.ActiveCount(),
           InpEntryLatestOnly?"SH/SL terbaru":"semua level",
           InpEntryOnTouch?"saat Bid sentuh":"setelah candle close",
           InpAllowEntryWithPosition?"boleh entry lagi":"entry baru diblok",
           InpATRPeriod,InpATRMultSL,InpRR,InpATRMinSL,InpATRMaxSL,ap,slNow,
           g_lastDecision);

   if(g_scanText!="")
      txt+="\n\n"+g_scanText;

   Comment(txt);
   ChartRedraw(0);
}

//==================================================================
// TANDA SH / SL di chart (koordinat waktu/harga -> independen dari chart TF)
// Tanpa garis break. Hanya teks "SH" di atas High pivot dan "SL" di
// bawah Low pivot.
//==================================================================
void DrawSwingMarks()
{
   const int nextId=g_engine.NextEventId();
   if(!ShouldDraw()) { g_lastEv=nextId-1; return; }

   for(int i=0;i<g_engine.LogCount();i++)
   {
      SNREvent e;
      if(!g_engine.GetLog(i,e)) continue;
      if(e.id<=g_lastEv) continue;
      if(e.kind!=EV_SWING_HIGH && e.kind!=EV_SWING_LOW) continue;

      const bool sh=(e.kind==EV_SWING_HIGH);
      g_markSeq++;
      const string nm=PFX_MARK+IntegerToString(g_markSeq);
      if(ObjectCreate(0,nm,OBJ_TEXT,0,e.time,e.price))
      {
         ObjectSetString(0,nm,OBJPROP_TEXT,sh?"SH":"SL");
         ObjectSetInteger(0,nm,OBJPROP_COLOR,sh?InpResistanceColor:InpSupportColor);
         ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,9);
         ObjectSetInteger(0,nm,OBJPROP_ANCHOR,sh?ANCHOR_LOWER:ANCHOR_UPPER);
         ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      }
      if(InpDrawMaxMarks>0 && g_markSeq-InpDrawMaxMarks>=1)
         ObjectDelete(0,PFX_MARK+IntegerToString(g_markSeq-InpDrawMaxMarks));
   }
   g_lastEv=nextId-1;
}

//==================================================================
// SIGNAL -> CHECK ACTIVE POSITION -> EXECUTE (dipakai close & touch)
//==================================================================
void RunSignal(const int signal,const string text)
{
   Print("[SIGNAL] "+text);

   if(!InpAllowEntryWithPosition && g_exec.HasActivePosition())
      Print("[ENTRY] NO ENTRY: posisi Market Reader (magic) masih OPEN -> signal diabaikan.");
   else if(!InpEnableTrading)
      Print("[ENTRY] trading disabled -> signal only.");
   else
      g_exec.Execute(signal,g_atr.Points());
}

//==================================================================
// WARM-UP (replay history TradeTF oldest -> newest, tanpa eksekusi)
//==================================================================
bool TryWarmup()
{
   const datetime t0=iTime(_Symbol,InpTradeTimeframe,0);
   if(t0==0) return false;

   MqlRates r[];
   ArraySetAsSeries(r,false);                         // index 0 = tertua
   const int want=MathMax(InpWarmupBars,10);
   const int n=CopyRates(_Symbol,InpTradeTimeframe,1,want,r);   // hanya candle closed
   if(n<10) return false;

   g_engine.Reset();
   g_atr.Reset();
   g_engine.SetQuiet(true);
   for(int i=0;i<n;i++)
   {
      SNRBar b; ToBar(r[i],b);
      g_engine.OnClosedBar(b);
      g_atr.OnBar(b);
   }
   g_engine.SetQuiet(false);

   g_lastProc=r[n-1].time;
   g_lastBar0=t0;
   g_lastEv=0;
   g_ready=true;
   g_lastDecision="warm-up done";
   Print(StringFormat("[MR] warm-up OK: %d bars %s, active levels=%d",
         n,EnumToString(InpTradeTimeframe),g_engine.ActiveCount()));
   DrawSwingMarks();
   UpdatePanel();
   return true;
}

//==================================================================
// CANDLE CLOSE: perbarui struktur (BRK, swing darurat, rantai SH/SL)
//==================================================================
bool ProcessNewCandles(const datetime t0)
{
   MqlRates r[];
   ArraySetAsSeries(r,false);
   const int n=CopyRates(_Symbol,InpTradeTimeframe,g_lastProc+1,t0-1,r);
   if(n<=0) return false;                             // coba lagi tick berikutnya

   for(int i=0;i<n;i++)
   {
      SNRBar b; ToBar(r[i],b);
      g_engine.OnClosedBar(b);
      g_atr.OnBar(b);
   }
   g_lastProc=r[n-1].time;
   g_lastBar0=t0;

   if(n>1)
      Print(StringFormat("[MR] catch-up %d bars; hanya signal candle terakhir yang boleh dieksekusi.",n));

   SNRBar last; ToBar(r[n-1],last);

   // SNR DECISION (hanya dari event candle closed terakhir)
   const SNRDecisionResult d=g_decision.Decide(g_engine);
   g_lastDecision=StringFormat("%s %s (%s)",TimeToString(last.time,TIME_DATE|TIME_MINUTES),SignalName(d.signal),d.reason);
   if(InpDebugMode) Print("[DECISION] "+g_lastDecision);

   // entry di close hanya terjadi jika InpEntryOnTouch=false (count==1)
   if(d.signal!=SIG_NO_TRADE)
      RunSignal(d.signal,g_lastDecision);

   DrawSwingMarks();
   UpdatePanel();
   return true;
}

//==================================================================
// TICK: entry saat Bid menyentuh SH/SL terbaru
//==================================================================
void CheckTouchEntry()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) return;

   int    refId=0;
   double lvl=0.0;
   const int sig=g_engine.CheckTouch(tk.bid,refId,lvl);
   if(sig==SIG_NO_TRADE) return;

   g_lastDecision=StringFormat("%s %s (touch s%d @ %s, bid %s)",
                               TimeToString(tk.time,TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                               SignalName(sig),refId,
                               DoubleToString(lvl,_Digits),DoubleToString(tk.bid,_Digits));
   if(InpDebugMode) Print("[DECISION] "+g_lastDecision);

   RunSignal(sig,g_lastDecision);
   UpdatePanel();
}

//==================================================================
// EVENTS
//==================================================================
int OnInit()
{
   if(InpTradeTimeframe==PERIOD_CURRENT)
   {
      Print("[MR] TradeTimeframe tidak boleh PERIOD_CURRENT (harus eksplisit, independen dari chart).");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLotSize<=0.0 || InpWarmupBars<10 || InpConfirmBars<1
      || InpATRPeriod<1 || InpATRMultSL<=0.0 || InpRR<=0.0
      || InpRiskPercent<=0.0 || InpRiskBalance<0.0)
   {
      Print("[MR] Parameter input tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   ObjectsDeleteAll(0,PFX_MARK);
   g_markSeq=0;
   g_scanText="";

   g_engine.Init(InpDebugMode,InpMaxZonesTracked,InpConfirmBars,InpEntryLatestOnly,InpEntryOnTouch);
   g_exec.Init(InpMagic,InpLotSize,InpSlippagePoints,InpMaxSpreadPoints);
   g_atr.Init(InpATRPeriod);

   // scanner (live/demo saja)
   EventKillTimer();
   g_scState=0;
   if(InpScanOn && !MQLInfoInteger(MQL_TESTER))
   {
      if(ScanInit())
         EventSetMillisecondTimer(100);
   }

   g_ready=false;
   TryWarmup();      // jika data belum siap, dicoba lagi di OnTick
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ScanFree();
   ObjectsDeleteAll(0,PFX_MARK);
   Comment("");
}

void OnTimer()
{
   ScanTimer();
}

void OnTick()
{
   if(!g_ready) { TryWarmup(); return; }

   const datetime t0=iTime(_Symbol,InpTradeTimeframe,0);
   if(t0==0) return;

   // 1) candle baru -> perbarui struktur dari candle closed.
   if(t0!=g_lastBar0)
   {
      if(!ProcessNewCandles(t0)) return;
   }

   // 2) entry saat Bid menyentuh SH/SL terbaru (struktur sudah terbaru di sini)
   if(InpEntryOnTouch)
      CheckTouchEntry();
}