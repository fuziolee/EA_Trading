//+------------------------------------------------------------------+
//|                  MarketReaderEA_Phase1_SNR_Breakout.mq5           |
//|  Market Reader EA - Phase 1 SNR-Only (standalone)  v4.33          |
//|  LAYER 1 = SH/SL berantai (zigzag N) tanpa indikator ZigZag       |
//|  LAYER 2 = Level aktif -> BREAKOUT (wick, no flip) -> garis      |
//|  ENTRY   = saat Bid menyentuh SH/SL terbaru (per tick);          |
//|            struktur diperbarui saat candle close                  |
//|  TradeTimeframe = sumber data + logic. Chart TF = tampilan saja. |
//|  v4.31 : + opsi entry walau masih ada posisi (searah/hedging)     |
//|          + statistik R dari deal history EA (trade nyata)         |
//|  v4.32 : + SIMULASI dari candle history (probabilitas per setting)|
//|          urutan sentuh/SL/TP ditelusuri dengan M1 di dalam candle |
//|  v4.33 : mode close = level ditembus jika CLOSE di luar level     |
//|          (wick tanpa close konfirmasi: level tetap aktif)         |
//+------------------------------------------------------------------+
#property copyright "Market Reader EA - Phase 1 SNR-Only"
#property version   "4.33"
#property description "Standalone SNR breakout-only EA. SH/SL berantai: candle + N konfirmasi (wick), swing darurat saat level terakhir ditembus. Entry saat wick menyentuh SH/SL terbaru. No ZigZag, no rejection, no flip."

#include <Trade\Trade.mqh>

#define PFX_ZONE "MRZ_"
#define PFX_DBG  "MRD_"

//==================================================================
// INPUTS
//==================================================================
input group "=== Market Reader (SNR) ==="
input ENUM_TIMEFRAMES      InpTradeTimeframe  = PERIOD_M1;            // TradeTimeframe (sumber SNR)
input bool                 InpDebugMode       = true;                 // DebugMode
input int                  InpWarmupBars      = 2000;                 // Warm-up bars (closed bars, TradeTF)
input int                  InpMaxZonesTracked = 500;                  // Batas level aktif & garis break di memori (0=unlimited)

input group "=== Swing SH/SL (Layer 1) ==="
input int                  InpConfirmBars     = 3;                    // Jumlah candle konfirmasi (wick tidak melewati SH/SL)

input group "=== Entry ==="
input bool                 InpEntryLatestOnly = true;                 // Entry hanya di SH/SL terbaru per tipe (level lama: BRK tanpa entry)
input bool                 InpEntryOnTouch    = true;                 // Entry saat Bid menyentuh level (false = tunggu candle CLOSE di luar level)
input bool                 InpAllowEntryWithPosition = false;         // Boleh entry walau masih ada posisi (searah/hedging, tanpa batas)

input group "=== Execution ==="
input bool                 InpEnableTrading   = true;                 // Enable order execution
input long                 InpMagic           = 88001001;             // Magic Number Market Reader EA
input double               InpLotSize         = 0.01;                 // Lot manual
input int                  InpSLPoints        = 0;                    // SL manual (points, 0=none)
input int                  InpTPPoints        = 0;                    // TP manual (points, 0=none)
input int                  InpSlippagePoints  = 30;                   // Slippage (points)
input int                  InpMaxSpreadPoints = 50;                   // Max spread (points, 0=off)

input group "=== Statistik (satuan R) ==="
input bool                 InpShowStats       = true;                 // Tampilkan statistik TRADE NYATA (deal history EA)
input int                  InpStatTrades      = 500;                  // Total Trade dihitung (N trade terakhir, 0 = semua) - berlaku untuk nyata & simulasi

input group "=== Simulasi Candle History (probabilitas) ==="
input bool                 InpSimStats        = true;                 // Aktifkan simulasi dari candle history (live/demo, bukan tester)
input int                  InpSimBars         = 30000;                // Jumlah candle TradeTF yang disimulasikan
input bool                 InpSimUseM1        = true;                 // Pakai M1 di dalam candle (akurat). false = aturan pesimis tanpa M1

enum ENUM_SCAN_RANK
{
   RANK_PF_MID = 0,   // PF rata-rata pesimis & optimis
   RANK_PF_PES = 1,   // PF pesimis
   RANK_PF_OPT = 2    // PF optimis
};

input bool           InpSimScan        = false;                  // MODE SCAN: hitung banyak kombinasi SL/TP sekaligus (SL/TP di bawah diabaikan)
input string         InpScanSL         = "100,150,200,250,300";  // Daftar SL scan (points, pisah koma, maks 12)
input string         InpScanTP         = "100,150,200,300,400";  // Daftar TP scan (points, pisah koma, maks 12)
input int            InpScanMinTrades  = 100;                    // Minimal total trade agar kombinasi diperingkat
input ENUM_SCAN_RANK InpScanRank       = RANK_PF_MID;            // Peringkat berdasarkan PF
input int            InpScanTop        = 8;                      // Jumlah baris teratas di panel (semua kombinasi dicetak ke Journal)

input group "=== Visual (display only, tidak memengaruhi logic) ==="
input color                InpResistanceColor = clrYellow;            // Warna garis break Resistance
input color                InpSupportColor    = clrRed;               // Warna garis break Support
input int                  InpLineWidth       = 1;                    // Tebal garis break
input int                  InpDrawMaxZones    = 200;                  // Jumlah garis break terbaru yang digambar
input int                  InpDebugMaxMarkers = 150;                  // Maks marker debug di chart

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
   datetime tFrom;     // awal garis (candle pivot)
   bool     entered;   // true = sudah entry saat sentuh (intrabar)
};

// Satu garis break = satu event BREAKOUT.
struct SNRArea
{
   int      id;        // unik per garis
   int      swId;      // id swing asal
   int      type;      // ENUM_ZONE_TYPE level yang ditembus
   double   price;     // level yang ditembus
   datetime tLeft;     // candle pivot
   datetime tRight;    // candle break
   bool     entry;     // true = level eligible entry (SH/SL terbaru); false = hanya ditandai BRK
};

// SNREvent.count untuk event break:
//   0 = level lama (tanpa entry)
//   1 = entry saat candle close (mode InpEntryOnTouch=false)
//   2 = sudah entry saat sentuh (intrabar)
//   3 = eligible, tetapi sentuhan tidak terpantau tick -> tanpa entry
struct SNREvent { int id; int kind; datetime time; double price; int refId; int count; int side; };

struct SNRDecisionResult { int signal; int buyVotes; int sellVotes; int ignored; string reason; };

// --- Statistik ---
struct SNRClosed  { datetime tOpen; datetime tClose; double r; };                 // satu trade tertutup (dalam R)
struct SNRPosRec  { ulong pid; datetime tOpen; datetime tClose; double volIn; double volOut; double risk; double net; };
struct SNRStat    { int n; int win; double gw; double gl; int maxCW; int maxCL; double maxDD; };

// --- Simulasi: satu trade virtual yang masih terbuka ---
struct SNRSimTrade { datetime tOpen; int dir; double entry; double sl; double tp; double slDist; };

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

int YearOf(const datetime t)
{
   MqlDateTime d;
   TimeToStruct(t,d);
   return d.year;
}

string FmtDate(const datetime t)
{
   MqlDateTime d;
   TimeToStruct(t,d);
   return StringFormat("%02d %s %d",d.day,
          StringSubstr("JanFebMarAprMayJunJulAugSepOctNovDec",(d.mon-1)*3,3),d.year);
}

string StatLine(const string label,const SNRStat &s)
{
   const double wr=(s.n>0) ? 100.0*s.win/s.n : 0.0;
   string pf="-";
   if(s.gl>0.0)      pf=DoubleToString(s.gw/s.gl,2);
   else if(s.gw>0.0) pf="inf";
   const double dd=(s.maxDD>0.0) ? -s.maxDD : 0.0;
   return StringFormat("%s | Trade %d | WR %.1f%% | PF %s | DD %.1fR | CW %d | CL %d\n",
                       label,s.n,wr,pf,dd,s.maxCW,s.maxCL);
}

//==================================================================
// LAYER 1a: DETEKTOR SWING NORMAL (tanpa ZigZag)
//   SH : candle pivot BULLISH, dan N candle berikutnya tidak ada yang
//        High-nya melewati High pivot  -> SH valid (level = High pivot).
//   SL : candle pivot BEARISH, dan N candle berikutnya tidak ada yang
//        Low-nya melewati Low pivot    -> SL valid (level = Low pivot).
//   Pakai wick (High/Low), bukan Close.
//   Detektor ini stateless; aturan berantai (SH->SL->SH) diterapkan
//   oleh engine.
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

   // Dipanggil untuk tiap candle CLOSED, kronologis.
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
      bool shOk=((p.close-p.open)>m_eps);       // pivot SH harus bullish
      bool slOk=((p.open-p.close)>m_eps);       // pivot SL harus bearish
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
//   RANTAI : swing terakhir (SH atau SL) menentukan tipe swing berikutnya.
//            Swing berikutnya harus tipe lawan DAN pivotnya setelah pivot
//            swing terakhir. Hasilnya SH,SL,SH,SL ... (zigzag bentuk N).
//
//   SWING DARURAT : jika level yang ditembus adalah swing TERAKHIR di
//            rantai (belum ada swing lawan setelahnya), swing lawan dibuat:
//              SH ditembus -> Low terendah  dari candle setelah pivot SH
//                             sampai candle penembus (inklusif) = SL.
//              SL ditembus -> High tertinggi di jendela yang sama = SH.
//            Dibentuk saat candle close (struktur tidak berubah-ubah
//            selama candle berjalan).
//
//   BREAKOUT : Mode wick  : Resistance ditembus jika High > level -> BUY.
//                           Support ditembus jika Low < level -> SELL.
//              Mode close : Resistance ditembus jika Close > level -> BUY.
//                           Support ditembus jika Close < level -> SELL.
//                           (wick tanpa close konfirmasi: level tetap aktif)
//              Setelah ditembus level dihapus (no flip).
//
//   ENTRY    : (InpEntryLatestOnly) hanya SH terbaru / SL terbaru.
//              (InpEntryOnTouch) entry terjadi di CheckTouch() per tick
//              saat Bid melewati level; level lalu ditandai "entered".
//              Saat candle close, break pada level "entered" tidak
//              memicu entry lagi.
//==================================================================
class CSNREngine
{
private:
   CSwingDetector m_det;
   SNRLevel m_lv[];
   int      m_nlv;
   SNRArea  m_areas[];
   int      m_na;
   int      m_nextId;
   int      m_nextAreaId;
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

   // RANTAI: swing terakhir
   int      m_lastType;       // -1 = belum ada, selain itu ENUM_ZONE_TYPE
   datetime m_lastRefT;       // candle pivot swing terakhir
   int      m_lastId;         // id swing terakhir (0 = belum ada)

   // SWING TERBARU PER TIPE (untuk aturan entry)
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

   void AddArea(const SNRSwing &sw,const datetime tLeft,const datetime tRight,const bool entry)
   {
      SNRArea a;
      a.id=m_nextAreaId++; a.swId=sw.id; a.type=sw.type; a.price=sw.price;
      a.tLeft=tLeft; a.tRight=tRight; a.entry=entry;
      ArrayResize(m_areas,m_na+1,256);
      m_areas[m_na]=a; m_na++;
      if(m_maxZones>0 && m_na>m_maxZones)
      {
         const int drop=m_na-m_maxZones;
         for(int i=0;i<m_na-drop;i++) m_areas[i]=m_areas[i+drop];
         m_na-=drop;
         ArrayResize(m_areas,m_na);
      }
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
   // Jendela = semua candle SETELAH pivot L sampai candle penembus b (inklusif).
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
            if(m_hist[k].low<=best)  { best=m_hist[k].low;  bt=m_hist[k].time; }   // <= : yang paling awal menang
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

         // MODE CLOSE: wick saja tidak cukup. Level baru dianggap ditembus
         // jika candle CLOSE di luar level (SH: close > level, SL: close < level).
         // Jika close tidak konfirmasi: level tetap aktif, tanpa entry & tanpa garis.
         if(!m_touchMode)
         {
            const bool closeOk = isR ? Gt(b.close,lvl) : Lt(b.close,lvl);
            if(!closeOk) continue;
         }

         // level eligible entry = SH terbaru (R) / SL terbaru (S)
         const bool eligible = (!m_latestOnly) || (L.s.id==(isR ? m_lastShId : m_lastSlId));

         int cnt;
         if(!eligible)         cnt=0;                    // level lama: BRK tanpa entry
         else if(!m_touchMode) cnt=1;                    // entry saat candle close
         else                  cnt=L.entered ? 2 : 3;    // sudah entry saat sentuh / sentuh tak terpantau

         const int kind = isR ? EV_RES_BREAK : EV_SUP_BREAK;
         AddLog(kind,b.time,isR?b.high:b.low,L.s.id,cnt,isR?1:-1,true);
         AddArea(L.s,L.tFrom,b.time,eligible);  // 1 break -> 1 garis (tetap ditandai BRK)

         // swing terakhir di rantai ditembus -> swing lawan darurat
         if(!havePend && L.s.id==m_lastId)
            havePend=BuildFallback(L,b,pend);

         RemoveLevel(i);                     // no flip: level selesai
      }

      // diproses setelah loop (aktif mulai candle berikutnya)
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
      m_nlv=0; m_na=0; m_nextId=1; m_nextAreaId=1; m_nl=0; m_nextEv=1; m_nb=0; m_lastTime=0;
      m_nh=0;
      m_lastType=-1; m_lastRefT=0; m_lastId=0;
      m_lastShId=0; m_lastSlId=0;
      m_det.Reset();
      ArrayResize(m_lv,0,256);
      ArrayResize(m_areas,0,256);
      ArrayResize(m_log,0,512);
      ArrayResize(m_bar,0,16);
      ArrayResize(m_hist,0,1024);
   }

   // Satu-satunya pintu data struktur: candle CLOSED, kronologis.
   // Urutan: 1) level aktif vs candle (BREAK + swing darurat)
   //         2) detektor swing normal -> disaring aturan rantai -> level aktif
   //         3) simpan riwayat.
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
   // Struktur (level, swing, rantai) TIDAK diubah di sini.
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

   // Versi SIMULASI dari CheckTouch: satu "langkah" harga diwakili oleh
   // High/Low bar (M1 atau candle TF). Aturan sama persis dengan CheckTouch
   // (level eligible, ditandai entered, konflik BUY+SELL = NO TRADE).
   // Tanpa log. Level disusun naik menurut id, jadi pencarian dari belakang
   // dan berhenti begitu id lebih kecil dari SH/SL terbaru (cepat).
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

   int  AreaCount() const { return m_na; }
   int  ActiveCount() const { return m_nlv; }
   bool GetArea(const int i,SNRArea &a) const { if(i<0||i>=m_na) return false; a=m_areas[i]; return true; }
   int  BarEventCount() const { return m_nb; }
   bool GetBarEvent(const int i,SNREvent &e) const { if(i<0||i>=m_nb) return false; e=m_bar[i]; return true; }
   int  LogCount() const { return m_nl; }
   bool GetLog(const int i,SNREvent &e) const { if(i<0||i>=m_nl) return false; e=m_log[i]; return true; }
   int  NextEventId() const { return m_nextEv; }
   int  LastSwingType() const { return m_lastType; }
};

//==================================================================
// MODULE: SNR DECISION  (events candle close -> BUY / SELL / NO TRADE)
//   RES_BREAK = BUY, SUP_BREAK = SELL.
//   Hanya break dengan count==1 (entry saat close, mode InpEntryOnTouch=false)
//   yang dihitung sebagai vote. Selain itu hanya dicatat "ignored":
//     0 = level lama, 2 = sudah entry saat sentuh, 3 = sentuh tak terpantau.
//   Konflik di candle yang sama = NO TRADE.
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
// MODULE: EXECUTION (manual lot/SL/TP) - tidak diubah
//==================================================================
class CExecutor
{
private:
   CTrade m_t;
   long   m_magic;
   double m_lot;
   int    m_sl, m_tp, m_maxSpread;

   double NormLot(double lot)
   {
      const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      const double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      const double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
      if(step>0) lot=MathFloor(lot/step+1e-8)*step;
      lot=MathMax(mn,MathMin(mx,lot));
      return NormalizeDouble(lot,8);
   }

public:
   void Init(const long magic,const double lot,const int sl,const int tp,const int slip,const int maxSpread)
   {
      m_magic=magic; m_lot=lot; m_sl=sl; m_tp=tp; m_maxSpread=maxSpread;
      m_t.SetExpertMagicNumber((ulong)magic);
      m_t.SetDeviationInPoints((ulong)slip);
      m_t.SetTypeFillingBySymbol(_Symbol);
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

   bool Execute(const int signal)
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
      const double lot=NormLot(m_lot);
      double sl=0.0, tp=0.0;
      bool ok=false;
      if(signal==SIG_BUY)
      {
         if(m_sl>0) sl=NormalizeDouble(tk.ask-m_sl*_Point,dg);
         if(m_tp>0) tp=NormalizeDouble(tk.ask+m_tp*_Point,dg);
         ok=m_t.Buy(lot,_Symbol,0.0,sl,tp,"MR_SNR_P1");
      }
      else if(signal==SIG_SELL)
      {
         if(m_sl>0) sl=NormalizeDouble(tk.bid+m_sl*_Point,dg);
         if(m_tp>0) tp=NormalizeDouble(tk.bid-m_tp*_Point,dg);
         ok=m_t.Sell(lot,_Symbol,0.0,sl,tp,"MR_SNR_P1");
      }
      Print(StringFormat("[EXEC] %s lot=%.2f sl=%s tp=%s ok=%s retcode=%u (%s)",
            SignalName(signal),lot,DoubleToString(sl,dg),DoubleToString(tp,dg),
            ok?"true":"false",m_t.ResultRetcode(),m_t.ResultRetcodeDescription()));
      return ok;
   }
};

//==================================================================
// MODULE: STATISTIK (satuan R)
//   Dua sumber data memakai penghitung yang sama:
//   (1) TRADE NYATA : Update() membaca DEAL HISTORY eksekusi asli EA
//       - Posisi dikenali dari deal IN (magic + simbol chart). Deal OUT
//         dicocokkan lewat position id (SL/TP-hit ikut terhitung).
//       - Risiko awal = |entry - SL awal| x lot (SL awal dari order pembuka).
//         R = (profit + swap + komisi + fee) / risiko awal.
//       - Trade tanpa SL awal tidak bisa dihitung R-nya -> tidak dihitung.
//   (2) SIMULASI : AddClosed() diisi oleh CSim (trade virtual dari candle).
//   Window = N trade tertutup terakhir (urut waktu close), 0 = semua.
//   Tahunan = berdasarkan tahun close, dihitung di dalam window.
//   Win = R > 0. CW/CL = streak terpanjang. DD = peak->lembah kurva R
//   kumulatif (mulai 0 di awal window / awal tahun).
//==================================================================
class CStats
{
private:
   long      m_magic;
   SNRPosRec m_pos[];     // posisi yang masih terbuka
   int       m_np;
   SNRClosed m_cl[];      // trade tertutup (urut waktu close)
   int       m_nc;
   int       m_done;      // jumlah deal history yang sudah diproses
   int       m_noSL;      // trade tertutup tanpa SL awal (tidak dihitung)

   int FindPos(const ulong pid) const
   {
      for(int i=m_np-1;i>=0;i--)
         if(m_pos[i].pid==pid) return i;
      return -1;
   }

   void Accum(const int from,const int to,const int year,SNRStat &s) const
   {
      ZeroMemory(s);
      double cum=0.0, peak=0.0;
      int cw=0, cl=0;
      for(int i=from;i<to;i++)
      {
         if(year>0 && YearOf(m_cl[i].tClose)!=year) continue;
         const double r=m_cl[i].r;
         s.n++;
         if(r>0.0) { s.win++; s.gw+=r; cw++; cl=0; if(cw>s.maxCW) s.maxCW=cw; }
         else      { s.gl-=r;          cl++; cw=0; if(cl>s.maxCL) s.maxCL=cl; }
         cum+=r;
         if(cum>peak) peak=cum;
         if(peak-cum>s.maxDD) s.maxDD=peak-cum;
      }
   }

public:
   void Init(const long magic) { m_magic=magic; Reset(); }

   void Reset()
   {
      m_np=0; m_nc=0; m_done=0; m_noSL=0;
      ArrayResize(m_pos,0,16);
      ArrayResize(m_cl,0,256);
   }

   // Dipakai simulasi: tambah satu trade tertutup (urut waktu close).
   void AddClosed(const datetime tOpen,const datetime tClose,const double r)
   {
      ArrayResize(m_cl,m_nc+1,1024);
      m_cl[m_nc].tOpen=tOpen;
      m_cl[m_nc].tClose=tClose;
      m_cl[m_nc].r=r;
      m_nc++;
   }

   // Proses deal baru sejak pemanggilan terakhir (trade nyata).
   void Update()
   {
      if(!HistorySelect(0,TimeCurrent()+86400)) return;
      const int total=HistoryDealsTotal();
      if(total<m_done) Reset();       // history dimuat ulang -> bangun ulang

      const double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv<=0.0) tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

      for(int i=m_done;i<total;i++)
      {
         const ulong tk=HistoryDealGetTicket(i);
         if(tk==0) continue;

         const long dtype=HistoryDealGetInteger(tk,DEAL_TYPE);
         if(dtype!=DEAL_TYPE_BUY && dtype!=DEAL_TYPE_SELL) continue;

         const long   entry=HistoryDealGetInteger(tk,DEAL_ENTRY);
         const ulong  pid=(ulong)HistoryDealGetInteger(tk,DEAL_POSITION_ID);
         const double vol=HistoryDealGetDouble(tk,DEAL_VOLUME);
         const double cash=HistoryDealGetDouble(tk,DEAL_PROFIT)
                          +HistoryDealGetDouble(tk,DEAL_SWAP)
                          +HistoryDealGetDouble(tk,DEAL_COMMISSION)
                          +HistoryDealGetDouble(tk,DEAL_FEE);

         if(entry==DEAL_ENTRY_IN)
         {
            if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=m_magic) continue;
            if(HistoryDealGetString(tk,DEAL_SYMBOL)!=_Symbol) continue;

            const double px=HistoryDealGetDouble(tk,DEAL_PRICE);
            const double sl=HistoryOrderGetDouble((ulong)HistoryDealGetInteger(tk,DEAL_ORDER),ORDER_SL);
            double risk=0.0;
            if(sl>0.0 && ts>0.0 && tv>0.0)
               risk=MathAbs(px-sl)/ts*tv*vol;

            int k=FindPos(pid);
            if(k<0)
            {
               ArrayResize(m_pos,m_np+1,16);
               k=m_np; m_np++;
               ZeroMemory(m_pos[k]);
               m_pos[k].pid=pid;
               m_pos[k].tOpen=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
            }
            m_pos[k].volIn+=vol;
            m_pos[k].risk+=risk;
            m_pos[k].net+=cash;
         }
         else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
         {
            const int k=FindPos(pid);
            if(k<0) continue;                   // bukan posisi EA ini
            m_pos[k].net+=cash;
            m_pos[k].volOut+=vol;
            m_pos[k].tClose=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);

            if(m_pos[k].volOut>=m_pos[k].volIn-1e-8)    // posisi tertutup penuh
            {
               if(m_pos[k].risk>0.0)
               {
                  AddClosed(m_pos[k].tOpen,m_pos[k].tClose,m_pos[k].net/m_pos[k].risk);
               }
               else m_noSL++;
               m_pos[k]=m_pos[m_np-1];
               m_np--;
            }
         }
      }
      m_done=total;
   }

   string BuildText(const string title,const int maxTrades) const
   {
      string s=title+"\n";
      if(m_nc<=0)
      {
         s+="Belum ada trade tertutup\n";
         if(m_noSL>0) s+=StringFormat("Tanpa SL (tidak dihitung): %d\n",m_noSL);
         return s;
      }

      int from=0;
      if(maxTrades>0 && m_nc>maxTrades) from=m_nc-maxTrades;
      const int to=m_nc;

      datetime tStart=m_cl[from].tOpen;
      for(int i=from+1;i<to;i++)
         if(m_cl[i].tOpen<tStart) tStart=m_cl[i].tOpen;
      const datetime tEnd=m_cl[to-1].tClose;

      s+=StringFormat("Total Trade : %d (input %s)\n",to-from,maxTrades>0 ? IntegerToString(maxTrades) : "semua");
      s+=StringFormat("Data        : %s - %s\n",FmtDate(tStart),FmtDate(tEnd));

      SNRStat st;
      Accum(from,to,0,st);
      s+=StatLine("ALL ",st);

      const int y0=YearOf(m_cl[from].tClose);
      const int y1=YearOf(m_cl[to-1].tClose);
      for(int y=y0;y<=y1;y++)
      {
         Accum(from,to,y,st);
         if(st.n>0) s+=StatLine(IntegerToString(y),st);
      }

      if(m_noSL>0) s+=StringFormat("Tanpa SL (tidak dihitung): %d\n",m_noSL);
      return s;
   }
};

//==================================================================
// MODULE: SIMULASI dari CANDLE HISTORY (trade virtual -> R)  [v4.34]
//
//   Engine terpisah memutar ulang candle TradeTF kronologis dengan logic
//   SH/SL yang sama persis. Struktur hanya berubah saat candle close.
//   Di DALAM tiap candle TF, harga ditelusuri langkah demi langkah
//   (bar M1 bila cocok dengan candle TF, jika tidak: candle TF itu sendiri).
//
//   Dua batas dihitung bersamaan (touch/entry identik, hanya penyelesaian
//   SL/TP yang beda):
//     PESIMIS : SL & TP sama-sama mungkin -> SL dulu; di langkah entry SL dicek.
//     OPTIMIS : SL & TP sama-sama mungkin -> TP dulu; di langkah entry SL diabaikan.
//   Hasil sebenarnya ada di antara keduanya.
//
//   MODE SCAN: struktur & titik sentuh tidak bergantung SL/TP, jadi satu
//   replay menghitung semua kombinasi SL x TP (masing-masing pesimis+optimis).
//
//   Harga: BUY masuk di level + spread (ask), keluar di bid; SELL masuk
//   di level (bid), keluar di ask (High/Low + spread). Spread = spread bar
//   (jika 0 -> spread simbol saat ini). Filter InpMaxSpreadPoints ikut.
//   R: SL = -1R, TP = TP/SL. Trade belum selesai tidak dihitung.
//==================================================================
struct SNRScanRes
{
   int      n;
   double   wr;
   double   pf;
   double   dd;
   double   pf1;      // PF separuh trade yang lebih lama
   double   pf2;      // PF separuh trade yang lebih baru
   int      cw;
   int      cl;
   datetime tStart;
   datetime tEnd;
};

double PfOf(const double gw,const double gl)
{
   if(gl>0.0) return gw/gl;
   return (gw>0.0) ? 999.0 : 0.0;
}

double Cap99(const double x)  { return MathMin(x,99.0); }
double NegDD(const double d)  { return (d>0.0) ? -d : 0.0; }

// "100,150,200" -> {100,150,200}; nilai <=0 dan duplikat dibuang, maks 12.
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

// Satu "buku" = satu kombinasi SL/TP pada satu skenario (pesimis/optimis).
class CSimBook
{
private:
   bool        m_opt;      // true = optimis (TP dulu), false = pesimis (SL dulu)
   bool        m_keep;     // true = mode scan (simpan daftar trade sendiri)
   int         m_slPts;
   int         m_tpPts;
   SNRSimTrade m_tr[];
   int         m_no;
   CStats      m_st;       // dipakai mode tunggal (teks)
   SNRClosed   m_cl[];     // dipakai mode scan
   int         m_nc;

   void Add(const datetime tOpen,const datetime tClose,const double r)
   {
      if(m_keep)
      {
         ArrayResize(m_cl,m_nc+1,256);
         m_cl[m_nc].tOpen=tOpen;
         m_cl[m_nc].tClose=tClose;
         m_cl[m_nc].r=r;
         m_nc++;
      }
      else
         m_st.AddClosed(tOpen,tClose,r);
   }

   bool ExitHit(const SNRSimTrade &t,const double hi,const double lo,const double sp,
                const bool entryStep,double &r) const
   {
      bool slHit, tpHit;
      if(t.dir>0)
      {
         slHit=(lo<=t.sl);
         tpHit=(t.tp>0.0 && hi>=t.tp);
      }
      else
      {
         slHit=(hi+sp>=t.sl);
         tpHit=(t.tp>0.0 && lo+sp<=t.tp);
      }

      const double rTP=(t.dir>0) ? (t.tp-t.entry)/t.slDist : (t.entry-t.tp)/t.slDist;

      if(m_opt)
      {
         if(tpHit)                    { r=rTP;  return true; }
         if(slHit && !entryStep)      { r=-1.0; return true; }
         return false;
      }

      if(slHit) { r=-1.0; return true; }
      if(tpHit) { r=rTP;  return true; }
      return false;
   }

public:
   void Init(const bool optimistic,const int slPts,const int tpPts,const bool keep)
   {
      m_opt=optimistic;
      m_keep=keep;
      m_slPts=slPts;
      m_tpPts=tpPts;
      m_st.Init(0);
      m_no=0;
      m_nc=0;
      ArrayResize(m_tr,0,16);
      ArrayResize(m_cl,0,256);
   }

   int OpenCount() const { return m_no; }

   // Exit trade yang sudah terbuka sebelum langkah ini.
   void Exits(const datetime t,const double hi,const double lo,const double sp)
   {
      for(int i=m_no-1;i>=0;i--)
      {
         double r=0.0;
         if(ExitHit(m_tr[i],hi,lo,sp,false,r))
         {
            Add(m_tr[i].tOpen,t,r);
            m_tr[i]=m_tr[m_no-1];
            m_no--;
         }
      }
   }

   void Open(const int sig,const double price,const datetime t,const int spPts,
             const bool checkNow,const double hi,const double lo)
   {
      if(m_slPts<=0) return;
      if(InpMaxSpreadPoints>0 && spPts>InpMaxSpreadPoints) return;     // sama seperti EA: skip
      if(!InpAllowEntryWithPosition && m_no>0) return;                 // masih ada posisi

      const double sp=spPts*_Point;
      SNRSimTrade x;
      ZeroMemory(x);
      x.tOpen=t;
      x.dir=(sig==SIG_BUY) ? 1 : -1;
      x.slDist=m_slPts*_Point;
      x.entry=(sig==SIG_BUY) ? price+sp : price;
      if(sig==SIG_BUY)
      {
         x.sl=x.entry-x.slDist;
         x.tp=(m_tpPts>0) ? x.entry+m_tpPts*_Point : 0.0;
      }
      else
      {
         x.sl=x.entry+x.slDist;
         x.tp=(m_tpPts>0) ? x.entry-m_tpPts*_Point : 0.0;
      }

      double r=0.0;
      if(checkNow && ExitHit(x,hi,lo,sp,true,r))      // langkah entry
      {
         Add(t,t,r);
         return;
      }
      ArrayResize(m_tr,m_no+1,16);
      m_tr[m_no]=x;
      m_no++;
   }

   // Teks mode tunggal.
   string Text(const string title,const int maxTrades) const
   {
      return m_st.BuildText(title,maxTrades);
   }

   // Ringkasan window (N trade terakhir) untuk mode scan.
   void Result(const int maxTrades,SNRScanRes &o) const
   {
      ZeroMemory(o);
      if(m_nc<=0) return;

      int from=0;
      if(maxTrades>0 && m_nc>maxTrades) from=m_nc-maxTrades;
      const int to=m_nc;
      o.n=to-from;
      o.tStart=m_cl[from].tOpen;
      o.tEnd=m_cl[to-1].tClose;

      const int mid=from+o.n/2;
      double cum=0.0, peak=0.0, gw=0.0, gl=0.0;
      double g1w=0.0, g1l=0.0, g2w=0.0, g2l=0.0;
      int win=0, cw=0, cl=0;
      for(int i=from;i<to;i++)
      {
         const double r=m_cl[i].r;
         if(m_cl[i].tOpen<o.tStart) o.tStart=m_cl[i].tOpen;
         if(r>0.0)
         {
            win++; gw+=r; cw++; cl=0;
            if(cw>o.cw) o.cw=cw;
            if(i<mid) g1w+=r; else g2w+=r;
         }
         else
         {
            gl-=r; cl++; cw=0;
            if(cl>o.cl) o.cl=cl;
            if(i<mid) g1l-=r; else g2l-=r;
         }
         cum+=r;
         if(cum>peak) peak=cum;
         if(peak-cum>o.dd) o.dd=peak-cum;
      }
      o.wr=100.0*win/o.n;
      o.pf=PfOf(gw,gl);
      o.pf1=PfOf(g1w,g1l);
      o.pf2=PfOf(g2w,g2l);
   }
};

class CSim
{
private:
   CSNREngine   m_eng;
   CSNRDecision m_dec;
   CSimBook    *m_bk[];        // indeks 2k = pesimis, 2k+1 = optimis untuk kombinasi k
   int          m_nb;
   int          m_slv[];       // SL per kombinasi
   int          m_tpv[];       // TP per kombinasi
   int          m_nk;
   bool         m_scan;
   int          m_defSpread;
   int          m_cM1;
   int          m_cFB;
   bool         m_printed;

   int SpreadOf(const int s) const { return (s>0) ? s : m_defSpread; }

   void Clear()
   {
      for(int i=0;i<m_nb;i++)
         if(CheckPointer(m_bk[i])==POINTER_DYNAMIC) delete m_bk[i];
      ArrayResize(m_bk,0);
      m_nb=0;
      m_nk=0;
   }

   double Pick(const double p,const double o) const
   {
      if(InpScanRank==RANK_PF_PES) return p;
      if(InpScanRank==RANK_PF_OPT) return o;
      return 0.5*(p+o);
   }

   string RankName() const
   {
      if(InpScanRank==RANK_PF_PES) return "pesimis";
      if(InpScanRank==RANK_PF_OPT) return "optimis";
      return "rata-rata";
   }

   // Satu langkah harga (bar M1 atau candle TF).
   void Step(const datetime t,const double hi,const double lo,const int spPts)
   {
      const double sp=spPts*_Point;

      // 1) exit trade yang sudah terbuka sebelum langkah ini
      for(int i=0;i<m_nb;i++)
         if(m_bk[i].OpenCount()>0) m_bk[i].Exits(t,hi,lo,sp);

      // 2) sentuh level -> entry (touch sama untuk semua kombinasi)
      //    Hanya di mode wick (InpEntryOnTouch=true). Mode close: entry di ProcessCandle().
      if(!InpEntryOnTouch) return;
      int    refId=0;
      double lvl=0.0;
      const int sig=m_eng.CheckTouchBar(hi,lo,refId,lvl);
      if(sig!=SIG_NO_TRADE)
      {
         for(int i=0;i<m_nb;i++)
            m_bk[i].Open(sig,lvl,t,spPts,true,hi,lo);
      }
   }

   string ScanText(const int maxTrades,const string reso)
   {
      SNRScanRes rp[], ro[];
      double     sc[];
      bool       el[];
      int        idx[];
      ArrayResize(rp,m_nk);
      ArrayResize(ro,m_nk);
      ArrayResize(sc,m_nk);
      ArrayResize(el,m_nk);
      ArrayResize(idx,0);

      int ne=0;
      for(int k=0;k<m_nk;k++)
      {
         m_bk[2*k].Result(maxTrades,rp[k]);
         m_bk[2*k+1].Result(maxTrades,ro[k]);
         sc[k]=Pick(Cap99(rp[k].pf),Cap99(ro[k].pf));
         el[k]=(rp[k].n>=InpScanMinTrades);
         if(el[k])
         {
            ArrayResize(idx,ne+1);
            idx[ne]=k;
            ne++;
         }
      }

      // urut menurun menurut skor
      for(int a=0;a<ne-1;a++)
         for(int b=a+1;b<ne;b++)
            if(sc[idx[b]]>sc[idx[a]])
            {
               const int tmp=idx[a];
               idx[a]=idx[b];
               idx[b]=tmp;
            }

      const string win=(maxTrades>0) ? IntegerToString(maxTrades) : "semua";

      // --- Journal: daftar lengkap (sekali saja) ---
      if(!m_printed)
      {
         m_printed=true;
         Print(StringFormat("[SCAN] %d kombinasi | peringkat PF %s | window %s trade | minimal %d trade | format: pesimis/optimis",
               m_nk,RankName(),win,InpScanMinTrades));
         for(int r=0;r<ne;r++)
         {
            const int k=idx[r];
            Print(StringFormat("[SCAN] #%d SL%d TP%d | N %d/%d | WR %.1f/%.1f%% | PF %.2f/%.2f | DD %.1f/%.1fR | CW %d/%d | CL %d/%d | PF paruh1/paruh2 pes %.2f/%.2f opt %.2f/%.2f | %s - %s",
               r+1,m_slv[k],m_tpv[k],rp[k].n,ro[k].n,rp[k].wr,ro[k].wr,
               Cap99(rp[k].pf),Cap99(ro[k].pf),NegDD(rp[k].dd),NegDD(ro[k].dd),
               rp[k].cw,ro[k].cw,rp[k].cl,ro[k].cl,
               Cap99(rp[k].pf1),Cap99(rp[k].pf2),Cap99(ro[k].pf1),Cap99(ro[k].pf2),
               FmtDate(rp[k].tStart),FmtDate(rp[k].tEnd)));
         }
         for(int k=0;k<m_nk;k++)
            if(!el[k])
               Print(StringFormat("[SCAN] -- SL%d TP%d | N %d (kurang dari minimal %d, tidak diperingkat)",
                     m_slv[k],m_tpv[k],rp[k].n,InpScanMinTrades));
      }

      // --- Panel: Top N ---
      string s=StringFormat("=== SCAN SL/TP (R) | peringkat PF %s ===\n",RankName());
      if(ne<=0)
         s+=StringFormat("Belum ada kombinasi dengan >= %d trade\n",InpScanMinTrades);
      else
      {
         const int k0=idx[0];
         s+=StringFormat("Data: %s - %s (window %s trade)\n",FmtDate(rp[k0].tStart),FmtDate(rp[k0].tEnd),win);
         s+="format: pesimis~optimis | H = PF paruh lama/baru\n";
         const int top=MathMin(MathMax(InpScanTop,1),ne);
         for(int r=0;r<top;r++)
         {
            const int k=idx[r];
            s+=StringFormat("#%d SL%d/TP%d | %dt | WR %.0f~%.0f%% | PF %.2f~%.2f | DD %.0f~%.0fR | H %.2f/%.2f\n",
               r+1,m_slv[k],m_tpv[k],rp[k].n,rp[k].wr,ro[k].wr,
               Cap99(rp[k].pf),Cap99(ro[k].pf),NegDD(rp[k].dd),NegDD(ro[k].dd),
               Cap99(Pick(rp[k].pf1,ro[k].pf1)),Cap99(Pick(rp[k].pf2,ro[k].pf2)));
         }
      }
      s+=StringFormat("%d kombinasi | daftar lengkap di Journal (tab Experts)\n",m_nk);
      if(reso!="") s+=reso+"\n";
      return s;
   }

public:
   CSim()
   {
      m_nb=0; m_nk=0; m_scan=false; m_defSpread=0; m_cM1=0; m_cFB=0; m_printed=false;
   }

   ~CSim() { Clear(); }

   void Init()
   {
      Clear();
      m_eng.Init(false,InpMaxZonesTracked,InpConfirmBars,InpEntryLatestOnly,InpEntryOnTouch);
      m_eng.SetQuiet(true);
      m_cM1=0; m_cFB=0; m_printed=false;
      m_defSpread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

      m_scan=InpSimScan;
      ArrayResize(m_slv,0);
      ArrayResize(m_tpv,0);

      if(m_scan)
      {
         int sl[], tp[];
         const int ns=ParsePoints(InpScanSL,sl);
         const int nt=ParsePoints(InpScanTP,tp);
         if(ns>0 && nt>0)
         {
            for(int i=0;i<ns;i++)
               for(int j=0;j<nt;j++)
               {
                  ArrayResize(m_slv,m_nk+1);
                  ArrayResize(m_tpv,m_nk+1);
                  m_slv[m_nk]=sl[i];
                  m_tpv[m_nk]=tp[j];
                  m_nk++;
               }
         }
         else
         {
            Print("[SIM] Daftar SL/TP scan tidak valid -> memakai SL/TP tunggal.");
            m_scan=false;
         }
      }

      if(!m_scan)
      {
         ArrayResize(m_slv,1);
         ArrayResize(m_tpv,1);
         m_slv[0]=InpSLPoints;
         m_tpv[0]=InpTPPoints;
         m_nk=1;
      }

      m_nb=2*m_nk;
      ArrayResize(m_bk,m_nb);
      for(int k=0;k<m_nk;k++)
      {
         m_bk[2*k]=new CSimBook;
         m_bk[2*k+1]=new CSimBook;
         m_bk[2*k].Init(false,m_slv[k],m_tpv[k],m_scan);
         m_bk[2*k+1].Init(true,m_slv[k],m_tpv[k],m_scan);
      }
      if(m_scan) Print(StringFormat("[SIM] Mode scan: %d kombinasi SL/TP",m_nk));
   }

   // Satu candle TF yang sudah CLOSED, kronologis.
   void ProcessCandle(const SNRBar &b,const int spreadPts)
   {
      const int tfSec=PeriodSeconds(InpTradeTimeframe);
      const int sp=SpreadOf(spreadPts);

      bool usedM1=false;
      if(InpSimUseM1 && InpTradeTimeframe!=PERIOD_M1)
      {
         MqlRates m[];
         ArraySetAsSeries(m,false);
         const int nm=CopyRates(_Symbol,PERIOD_M1,b.time,b.time+tfSec-1,m);
         if(nm>0)
         {
            double mh=m[0].high, ml=m[0].low;
            for(int j=1;j<nm;j++)
            {
               if(m[j].high>mh) mh=m[j].high;
               if(m[j].low<ml)  ml=m[j].low;
            }
            const double tol=_Point*5.0;
            if(MathAbs(mh-b.high)<=tol && MathAbs(ml-b.low)<=tol)
            {
               usedM1=true;
               for(int j=0;j<nm;j++)
                  Step(m[j].time,m[j].high,m[j].low,SpreadOf(m[j].spread));
            }
         }
      }
      if(usedM1) m_cM1++;
      else       { m_cFB++; Step(b.time,b.high,b.low,sp); }

      // candle close: struktur diperbarui (BRK, swing darurat, rantai)
      m_eng.OnClosedBar(b);

      // mode entry saat candle close
      if(!InpEntryOnTouch)
      {
         const SNRDecisionResult d=m_dec.Decide(m_eng);
         if(d.signal!=SIG_NO_TRADE)
         {
            for(int i=0;i<m_nb;i++)
               m_bk[i].Open(d.signal,b.close,b.time+tfSec,sp,false,0.0,0.0);
         }
      }
   }

   string Text(const int maxTrades)
   {
      if(m_nb<2) return "";

      const int tot=m_cM1+m_cFB;
      string reso="";
      if(tot>0)
         reso=StringFormat("Resolusi: M1 %.0f%% | candle TF %.0f%%",100.0*m_cM1/tot,100.0*m_cFB/tot);

      if(m_scan) return ScanText(maxTrades,reso);

      string s=m_bk[0].Text("=== SIMULASI PESIMIS: SL dulu (R) ===",maxTrades);
      s+="\n"+m_bk[1].Text("=== SIMULASI OPTIMIS: TP dulu (R) ===",maxTrades);
      if(tot>0)
         s+=reso+StringFormat(" | belum selesai: %d/%d\n",m_bk[0].OpenCount(),m_bk[1].OpenCount());
      s+="Hasil sebenarnya ada di antara pesimis & optimis\n";
      return s;
   }
};

//==================================================================
// GLOBALS
//==================================================================
CSNREngine   g_engine;
CSNRDecision g_decision;
CExecutor    g_exec;
CStats       g_stats;
CSim         g_sim;

bool     g_ready        = false;
datetime g_lastBar0     = 0;      // open time bar berjalan (TradeTF) saat terakhir diproses
datetime g_lastProc     = 0;      // open time candle closed terakhir yang diproses engine
int      g_lastEv       = 0;      // id event terakhir yang sudah digambar
string   g_lastDecision = "-";
bool     g_statDirty    = false;  // ada deal baru -> statistik nyata perlu diperbarui
string   g_statText     = "";     // teks statistik trade nyata untuk panel

// simulasi
MqlRates g_simRates[];
int      g_simState     = 0;      // 0=menunggu data, 1=replay, 2=ikuti candle baru
int      g_simIdx       = 0;
int      g_simN         = 0;
datetime g_simLast      = 0;
datetime g_simBar0      = 0;
string   g_simText      = "";

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

// Perbarui teks statistik trade nyata. Dilewati di tester non-visual.
void RefreshStats()
{
   if(!InpShowStats || !ShouldDraw()) return;
   g_stats.Update();
   g_statText=g_stats.BuildText("=== STATISTIK TRADE NYATA (R) ===",InpStatTrades);
}

//==================================================================
// PANEL (Comment): status EA + simulasi + statistik nyata
//==================================================================
void UpdatePanel()
{
   if(!ShouldDraw()) return;

   string txt=StringFormat("MARKET READER P1 SNR BREAKOUT v4.33\nSNR source TF : %s  (chart TF: %s - display only)\nSwing rule    : rantai SH/SL, %d candle konfirmasi (wick) + swing darurat\nSwing terakhir: %s\nActive levels : %d | Break lines: %d\nMode          : Breakout only (no flip)\nEntry         : %s | %s\nSaat ada posisi: %s\nLast decision : %s",
           EnumToString(InpTradeTimeframe),EnumToString((ENUM_TIMEFRAMES)Period()),
           InpConfirmBars,LastSwingText(),
           g_engine.ActiveCount(),g_engine.AreaCount(),
           InpEntryLatestOnly?"SH/SL terbaru saja":"semua level",
           InpEntryOnTouch?"saat Bid menyentuh level":"setelah candle close",
           InpAllowEntryWithPosition?"boleh entry lagi (searah/hedging)":"entry baru diblok",
           g_lastDecision);

   if(InpSimStats && g_simText!="")
      txt+="\n\n"+g_simText;
   if(InpShowStats && g_statText!="")
      txt+="\n"+g_statText;

   Comment(txt);
   ChartRedraw(0);
}

//==================================================================
// SIMULASI: pengumpan data (dipanggil dari OnTimer)
//   state 0 : tunggu data history siap, muat InpSimBars candle closed
//   state 1 : replay bertahap (tidak membekukan terminal) + progres
//   state 2 : ikuti candle baru yang close
//==================================================================
bool SimEnabled()
{
   return (InpSimStats && !MQLInfoInteger(MQL_TESTER) && (InpSimScan || InpSLPoints>0));
}

void SimRefreshText()
{
   g_simText=g_sim.Text(InpStatTrades);
}

void SimFeed()
{
   if(!SimEnabled()) return;

   if(g_simState==0)
   {
      if(!(bool)SeriesInfoInteger(_Symbol,InpTradeTimeframe,SERIES_SYNCHRONIZED))
      {
         g_simText="=== SIMULASI CANDLE HISTORY (R) ===\nMenunggu data history...\n";
         UpdatePanel();
         return;
      }
      ArraySetAsSeries(g_simRates,false);
      g_simN=CopyRates(_Symbol,InpTradeTimeframe,1,MathMax(InpSimBars,100),g_simRates);
      if(g_simN<100)
      {
         g_simText="=== SIMULASI CANDLE HISTORY (R) ===\nMenunggu data history...\n";
         UpdatePanel();
         return;
      }
      g_sim.Init();
      g_simIdx=0;
      g_simState=1;
      return;
   }

   if(g_simState==1)
   {
      const uint t0=GetTickCount();
      while(g_simIdx<g_simN && (GetTickCount()-t0)<150)
      {
         SNRBar b;
         ToBar(g_simRates[g_simIdx],b);
         g_sim.ProcessCandle(b,g_simRates[g_simIdx].spread);
         g_simIdx++;
      }

      if(g_simIdx>=g_simN)
      {
         g_simLast=g_simRates[g_simN-1].time;
         g_simBar0=0;                  // paksa catch-up candle yang close selama replay
         g_simState=2;
         ArrayFree(g_simRates);
         SimRefreshText();
      }
      else
         g_simText=StringFormat("=== SIMULASI CANDLE HISTORY (R) ===\nMemproses %d%% (%d/%d candle)\n",
                                (int)(100.0*g_simIdx/g_simN),g_simIdx,g_simN);
      UpdatePanel();
      return;
   }

   if(g_simState==2)
   {
      const datetime t0=iTime(_Symbol,InpTradeTimeframe,0);
      if(t0==0 || t0==g_simBar0) return;

      MqlRates r[];
      ArraySetAsSeries(r,false);
      const int n=CopyRates(_Symbol,InpTradeTimeframe,g_simLast+1,t0-1,r);
      if(n<=0) { g_simBar0=t0; return; }

      for(int i=0;i<n;i++)
      {
         SNRBar b;
         ToBar(r[i],b);
         g_sim.ProcessCandle(b,r[i].spread);
      }
      g_simLast=r[n-1].time;
      g_simBar0=t0;
      SimRefreshText();
      UpdatePanel();
   }
}

//==================================================================
// VISUALISASI  (koordinat waktu/harga -> independen dari chart TF)
// 1 event BREAKOUT = 1 garis horizontal di level SH/SL,
// dari candle pivot sampai candle break.
// Break tanpa entry (level lama) tetap digambar; label debug "brk".
//==================================================================
void DrawZones()
{
   if(!ShouldDraw()) return;
   ObjectsDeleteAll(0,PFX_ZONE);

   const int tfSec=PeriodSeconds(InpTradeTimeframe);
   int drawn=0;
   for(int i=g_engine.AreaCount()-1;i>=0 && drawn<InpDrawMaxZones;i--)
   {
      SNRArea a;
      if(!g_engine.GetArea(i,a)) continue;
      drawn++;

      const bool  res = (a.type==ZT_RESISTANCE);
      const color clr = res ? InpResistanceColor : InpSupportColor;
      const datetime tRight = a.tRight+(datetime)tfSec;          // sampai candle break selesai

      const string nl=StringFormat("%sL_%d",PFX_ZONE,a.id);
      if(ObjectCreate(0,nl,OBJ_TREND,0,a.tLeft,a.price,tRight,a.price))
      {
         ObjectSetInteger(0,nl,OBJPROP_COLOR,clr);
         ObjectSetInteger(0,nl,OBJPROP_WIDTH,MathMax(InpLineWidth,1));
         ObjectSetInteger(0,nl,OBJPROP_STYLE,STYLE_SOLID);
         ObjectSetInteger(0,nl,OBJPROP_RAY_RIGHT,false);
         ObjectSetInteger(0,nl,OBJPROP_RAY_LEFT,false);
         ObjectSetInteger(0,nl,OBJPROP_BACK,false);
         ObjectSetInteger(0,nl,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nl,OBJPROP_HIDDEN,true);
         ObjectSetString(0,nl,OBJPROP_TOOLTIP,
            StringFormat("s%d %s %s BREAKOUT%s",a.swId,res?"R":"S",DoubleToString(a.price,_Digits),
                         a.entry?"":" (no entry)"));
      }

      if(InpDebugMode)   // label hanya di DebugMode
      {
         const string nt=StringFormat("%sT_%d",PFX_ZONE,a.id);
         if(ObjectCreate(0,nt,OBJ_TEXT,0,a.tLeft,a.price))
         {
            ObjectSetString(0,nt,OBJPROP_TEXT,
               StringFormat("s%d %s %s",a.swId,res?"R":"S",a.entry?"BRK":"brk"));
            ObjectSetInteger(0,nt,OBJPROP_COLOR,clr);
            ObjectSetInteger(0,nt,OBJPROP_FONTSIZE,8);
            ObjectSetInteger(0,nt,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
            ObjectSetInteger(0,nt,OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,nt,OBJPROP_HIDDEN,true);
         }
      }
   }

   UpdatePanel();
}

void DrawDebugEvents()
{
   const int nextId=g_engine.NextEventId();
   if(!InpDebugMode || !ShouldDraw()) { g_lastEv=nextId-1; return; }

   const int minId=nextId-InpDebugMaxMarkers;
   for(int i=0;i<g_engine.LogCount();i++)
   {
      SNREvent e;
      if(!g_engine.GetLog(i,e)) continue;
      if(e.id<=g_lastEv || e.id<minId) continue;

      string txt; color clr;
      switch(e.kind)
      {
         case EV_SWING_HIGH: txt="SH"; clr=clrRed; break;
         case EV_SWING_LOW:  txt="SL"; clr=clrLime; break;
         case EV_RES_TOUCH:
         case EV_SUP_TOUCH:  txt=StringFormat("TOUCH s%d",e.refId); clr=clrOrange; break;
         default:
            if(e.count==1)      { txt=StringFormat("BRK s%d",e.refId); clr=clrDeepSkyBlue; }
            else if(e.count==2) { txt=StringFormat("BRK s%d (entry saat sentuh)",e.refId); clr=clrDeepSkyBlue; }
            else if(e.count==3) { txt=StringFormat("BRK s%d (sentuh tak terpantau)",e.refId); clr=clrSilver; }
            else                { txt=StringFormat("brk s%d (no entry)",e.refId); clr=clrGray; }
            break;
      }
      const string nm=PFX_DBG+IntegerToString(e.id);
      if(ObjectCreate(0,nm,OBJ_TEXT,0,e.time,e.price))
      {
         ObjectSetString(0,nm,OBJPROP_TEXT,txt);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
         ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,8);
         ObjectSetInteger(0,nm,OBJPROP_ANCHOR,e.side>0?ANCHOR_LOWER:ANCHOR_UPPER);
         ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      }
      if(e.id-InpDebugMaxMarkers>=1)
         ObjectDelete(0,PFX_DBG+IntegerToString(e.id-InpDebugMaxMarkers));
   }
   g_lastEv=nextId-1;
}

void DrawSignalMarker(const int signal,const SNRBar &b,const string note)
{
   if(!ShouldDraw() || !InpDebugMode) return;
   const string nm=StringFormat("%sSIG_%I64d",PFX_DBG,(long)b.time);
   const double px=(signal==SIG_BUY) ? b.low : b.high;
   if(ObjectCreate(0,nm,OBJ_ARROW,0,b.time,px))
   {
      ObjectSetInteger(0,nm,OBJPROP_ARROWCODE,signal==SIG_BUY?233:234);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,signal==SIG_BUY?clrDodgerBlue:clrCrimson);
      ObjectSetInteger(0,nm,OBJPROP_WIDTH,3);
      ObjectSetInteger(0,nm,OBJPROP_ANCHOR,signal==SIG_BUY?ANCHOR_TOP:ANCHOR_BOTTOM);
      ObjectSetString(0,nm,OBJPROP_TOOLTIP,SignalName(signal)+" | "+note);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   }
}

//==================================================================
// SIGNAL -> CHECK ACTIVE POSITION -> EXECUTE (dipakai close & touch)
//   InpAllowEntryWithPosition=true : cek posisi dilewati (searah/hedging,
//   tanpa batas). false : entry diblok jika posisi magic ini masih open.
//==================================================================
void RunSignal(const int signal,const SNRBar &mark,const string text)
{
   Print("[SIGNAL] "+text);
   DrawSignalMarker(signal,mark,text);

   if(!InpAllowEntryWithPosition && g_exec.HasActivePosition())
      Print("[ENTRY] NO ENTRY: posisi Market Reader (magic) masih OPEN -> signal diabaikan.");
   else if(!InpEnableTrading)
      Print("[ENTRY] trading disabled -> signal only.");
   else
      g_exec.Execute(signal);
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
   g_engine.SetQuiet(true);
   for(int i=0;i<n;i++)
   {
      SNRBar b; ToBar(r[i],b);
      g_engine.OnClosedBar(b);
   }
   g_engine.SetQuiet(false);

   g_lastProc=r[n-1].time;
   g_lastBar0=t0;
   g_lastEv=0;
   g_ready=true;
   g_lastDecision="warm-up done";
   Print(StringFormat("[MR] warm-up OK: %d bars %s, active levels=%d, break lines=%d",
         n,EnumToString(InpTradeTimeframe),g_engine.ActiveCount(),g_engine.AreaCount()));
   DrawZones();
   DrawDebugEvents();
   return true;
}

//==================================================================
// CANDLE CLOSE: perbarui struktur (BRK, swing darurat, rantai SH/SL)
//==================================================================
bool ProcessNewCandles(const datetime t0)
{
   // ambil semua candle CLOSED sejak candle terakhir yang diproses
   MqlRates r[];
   ArraySetAsSeries(r,false);
   const int n=CopyRates(_Symbol,InpTradeTimeframe,g_lastProc+1,t0-1,r);
   if(n<=0) return false;                             // coba lagi tick berikutnya

   for(int i=0;i<n;i++)
   {
      SNRBar b; ToBar(r[i],b);
      g_engine.OnClosedBar(b);
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
      RunSignal(d.signal,last,g_lastDecision);

   DrawZones();
   DrawDebugEvents();
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

   SNRBar mark;
   mark.time=iTime(_Symbol,InpTradeTimeframe,0);
   mark.open=tk.bid; mark.high=tk.bid; mark.low=tk.bid; mark.close=tk.bid;
   RunSignal(sig,mark,g_lastDecision);

   DrawDebugEvents();
   ChartRedraw(0);
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
   if(InpLotSize<=0.0 || InpSLPoints<0 || InpTPPoints<0 || InpWarmupBars<10 || InpConfirmBars<1
      || InpStatTrades<0 || InpSimBars<100)
   {
      Print("[MR] Parameter input tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   ObjectsDeleteAll(0,PFX_ZONE);
   ObjectsDeleteAll(0,PFX_DBG);

   g_engine.Init(InpDebugMode,InpMaxZonesTracked,InpConfirmBars,InpEntryLatestOnly,InpEntryOnTouch);
   g_exec.Init(InpMagic,InpLotSize,InpSLPoints,InpTPPoints,InpSlippagePoints,InpMaxSpreadPoints);

   // statistik trade nyata
   g_stats.Init(InpMagic);
   g_statText="";
   g_statDirty=false;
   RefreshStats();

   // simulasi candle history (live/demo saja)
   EventKillTimer();
   g_simState=0; g_simIdx=0; g_simN=0; g_simLast=0; g_simBar0=0;
   g_simText="";
   if(InpSimStats && !MQLInfoInteger(MQL_TESTER))
   {
      if(!InpSimScan && InpSLPoints<=0)
         g_simText="=== SIMULASI CANDLE HISTORY (R) ===\nIsi SL manual > 0 dulu (R dihitung dari SL)\n";
      else
      {
         g_simText="=== SIMULASI CANDLE HISTORY (R) ===\nMenyiapkan data...\n";
         EventSetMillisecondTimer(100);
      }
   }

   g_ready=false;
   TryWarmup();      // jika data belum siap, dicoba lagi di OnTick
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0,PFX_ZONE);
   ObjectsDeleteAll(0,PFX_DBG);
   Comment("");
}

void OnTimer()
{
   SimFeed();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   // Ganti chart TF: hanya menggambar ulang, SNR tidak berubah.
   if(id==CHARTEVENT_CHART_CHANGE && g_ready) DrawZones();
}

// Ada deal baru (entry/close) -> statistik nyata diperbarui di tick berikutnya.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
      g_statDirty=true;
}

void OnTick()
{
   if(!g_ready) { TryWarmup(); return; }

   // 0) statistik trade nyata: bangun ulang tiap candle baru (live) + saat ada deal baru
   static datetime lastStatBar=0;
   const datetime tb=iTime(_Symbol,InpTradeTimeframe,0);
   if(!MQLInfoInteger(MQL_TESTER) && tb!=0 && tb!=lastStatBar)
   {
      lastStatBar=tb;
      g_stats.Reset();
      g_statDirty=true;
   }
   if(g_statDirty)
   {
      g_statDirty=false;
      RefreshStats();
      UpdatePanel();
   }

   const datetime t0=iTime(_Symbol,InpTradeTimeframe,0);
   if(t0==0) return;

   // 1) candle baru -> perbarui struktur dari candle closed.
   //    Jika gagal (data belum siap), lewati tick ini supaya cek sentuhan
   //    tidak memakai level yang belum diperbarui.
   if(t0!=g_lastBar0)
   {
      if(!ProcessNewCandles(t0)) return;
   }

   // 2) entry saat Bid menyentuh SH/SL terbaru (struktur sudah terbaru di sini)
   if(InpEntryOnTouch)
      CheckTouchEntry();
}