#property strict
#property description "Scanner V7.13.7 - DAILY AUTO SELECTION + CLOSED TRADE STATS + FORCE CLOSE AT ENTRY END"

// ============ MODE ============
enum ENUM_EA_MODE { MODE_SCANNER=0, MODE_ENTRY=1 };
input ENUM_EA_MODE EA_Mode = MODE_ENTRY;

// ============ SCANNER SETTINGS ============
input ENUM_TIMEFRAMES Timeframe_Test = PERIOD_M1;
input double Min_WR = 60.0;
input double DD_Safe = 6.0;
input double DD_Danger = 20.0;

// ============ ENTRY SETTINGS ============
input int AutoSelectionLookbackDays = 120;
input int MinSamplesTotal = 10;
input double ManualLot = 0.01;
input int TP_Points = 500;
input int SL_Points = 500;
input int Slippage = 30;
input ulong MagicNumber = 7136001;
input bool AllowMultiplePositions = false;
input string EntryStartTime = "01:00";
input string EntryEndTime = "23:00";
input bool EnableForceCloseAtEntryEnd = true; // NEW: close EA positions at EntryEndTime

input bool UseSessionFilter = false;
input bool EnableAsianSession = true;
input string AsianStartTime = "01:00";
input string AsianEndTime = "09:00";
input bool EnableEuropeSession = true;
input string EuropeStartTime = "08:00";
input string EuropeEndTime = "17:00";
input bool EnableUSSession = true;
input string USStartTime = "14:00";
input string USEndTime = "23:00";
input int GMT_Offset = 0;

#include <Trade/Trade.mqh>
CTrade Trade;

// ============ SCANNER ARRAYS ============
// [0]=WinBuy [1]=TotalBuy [2]=WinSell [3]=TotalSell
// [4]=Equity R [5]=Peak Equity R [6]=Maximum Drawdown R
double Stats[1440][7];
int HistoryBuy[1440][1000];
int HistorySell[1440][1000];
int HistoryCountBuy[1440];
int HistoryCountSell[1440];
bool TradedBuyThisMinute[1440];
bool TradedSellThisMinute[1440];
bool AutoBuySlot[1440];
bool AutoSellSlot[1440];
double AutoBuyWR[1440];
double AutoSellWR[1440];
int AutoBuyN[1440];
int AutoSellN[1440];
int AutoBuyWin[1440];
int AutoSellWin[1440];
double AutoBuyDD[1440];
double AutoSellDD[1440];
int AutoSelectedCount=0;
double PointVal=0.0;
double RR=1.0;
datetime LastBarTime=0;
datetime LastPanelTime=0;
datetime LastStatsUpdate=0;
int LastDay=-1;
int EntryDayKey=-1;
int LastSelectionDayKey=-1;
int TradesTodayWin=0, TradesTodayLoss=0, TradesTotalWin=0, TradesTotalLoss=0;

struct PositionResult
{
   ulong position_id;
   double entry_volume;
   double exit_volume;
   double net_profit;
   datetime last_exit_time;
};
PositionResult PositionResults[];

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
datetime ToWIB(datetime server_time) { return server_time + GMT_Offset*3600; }

string FormatJamWIB(datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);
   return StringFormat("%02d:%02d",dt.hour,dt.min);
}

int GetIndexWIB(datetime server_time)
{
   MqlDateTime dt; TimeToStruct(ToWIB(server_time),dt);
   return dt.hour*60+dt.min;
}

int GetWIBDayKey(datetime wib)
{
   MqlDateTime dt; TimeToStruct(wib,dt);
   return dt.year*10000+dt.mon*100+dt.day;
}

//+------------------------------------------------------------------+
//| Consecutive wins/losses                                          |
//+------------------------------------------------------------------+
void GetConsecutive(int &arr[],int count,int &maxWin,int &maxLose)
{
   maxWin=0; maxLose=0; int curW=0,curL=0;
   for(int i=0;i<count;i++)
   {
      if(arr[i]==1) { curW++; curL=0; if(curW>maxWin) maxWin=curW; }
      else { curL++; curW=0; if(curL>maxLose) maxLose=curL; }
   }
}

//+------------------------------------------------------------------+
//| Parse HH:MM and time-window helpers                              |
//+------------------------------------------------------------------+
int ParseMinuteOfDay(string value)
{
   StringTrimLeft(value); StringTrimRight(value);
   if(StringLen(value)!=5 || StringSubstr(value,2,1)!=":") return -1;
   int hh=(int)StringToInteger(StringSubstr(value,0,2));
   int mm=(int)StringToInteger(StringSubstr(value,3,2));
   if(hh<0 || hh>23 || mm<0 || mm>59) return -1;
   return hh*60+mm;
}

bool IsMinuteInWindow(int nowMinute,string startText,string endText)
{
   int startMinute=ParseMinuteOfDay(startText), endMinute=ParseMinuteOfDay(endText);
   if(startMinute<0 || endMinute<0) return false;
   if(startMinute<=endMinute) return nowMinute>=startMinute && nowMinute<=endMinute;
   return nowMinute>=startMinute || nowMinute<=endMinute;
}

// NEW: cutoff is reached at EntryEndTime and remains active until next start.
bool IsEntryEndReached(int nowMinute)
{
   int startMinute=ParseMinuteOfDay(EntryStartTime);
   int endMinute=ParseMinuteOfDay(EntryEndTime);
   if(startMinute<0 || endMinute<0) return false;
   if(startMinute<=endMinute) return nowMinute>=endMinute;
   // Overnight window, e.g. 23:00 to 01:00: cutoff is 01:00..22:59.
   return (nowMinute>=endMinute && nowMinute<startMinute);
}

//+------------------------------------------------------------------+
//| Session helpers                                                  |
//+------------------------------------------------------------------+
string SessionName(int nowMinute)
{
   bool asian=IsMinuteInWindow(nowMinute,AsianStartTime,AsianEndTime);
   bool europe=IsMinuteInWindow(nowMinute,EuropeStartTime,EuropeEndTime);
   bool us=IsMinuteInWindow(nowMinute,USStartTime,USEndTime);
   string result="OFF SESSION";
   if(asian) result="ASIAN";
   if(europe) result=(result=="OFF SESSION"?"EUROPE":result+"+EUROPE");
   if(us) result=(result=="OFF SESSION"?"US":result+"+US");
   return result;
}

bool IsEnabledSession(int nowMinute)
{
   if(!UseSessionFilter) return true;
   bool allowed=false;
   if(EnableAsianSession && IsMinuteInWindow(nowMinute,AsianStartTime,AsianEndTime)) allowed=true;
   if(EnableEuropeSession && IsMinuteInWindow(nowMinute,EuropeStartTime,EuropeEndTime)) allowed=true;
   if(EnableUSSession && IsMinuteInWindow(nowMinute,USStartTime,USEndTime)) allowed=true;
   return allowed;
}

//+------------------------------------------------------------------+
//| Position checks and force close                                  |
//+------------------------------------------------------------------+
bool IsOurPositionOpen()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) return true;
   }
   return false;
}

// Close all positions opened by this EA on this chart symbol only.
// Attempts are throttled to once every five seconds if closure fails/remains partial.
void ForceCloseAtEntryEnd(datetime wibNow)
{
   if(!EnableForceCloseAtEntryEnd || EA_Mode!=MODE_ENTRY) return;
   if(ParseMinuteOfDay(EntryStartTime)<0 || ParseMinuteOfDay(EntryEndTime)<0) return;

   MqlDateTime dt; TimeToStruct(wibNow,dt);
   int nowMinute=dt.hour*60+dt.min;
   if(!IsEntryEndReached(nowMinute)) return;

   datetime serverNow=TimeCurrent();
   if(serverNow<=0) return;
   static datetime lastAttempt=0;
   if(lastAttempt>0 && serverNow-lastAttempt<5) return;
   lastAttempt=serverNow;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      ResetLastError();
      bool requestOK=Trade.PositionClose(ticket);
      uint retcode=Trade.ResultRetcode();
      if(requestOK && (retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL))
      {
         Print("FORCE CLOSE | ",TimeToString(wibNow,TIME_DATE|TIME_SECONDS),
               " WIB | symbol=",_Symbol," | ticket=",ticket,
               " | retcode=",retcode," | ",Trade.ResultRetcodeDescription());
      }
      else
      {
         Print("FORCE CLOSE FAILED | ",TimeToString(wibNow,TIME_DATE|TIME_SECONDS),
               " WIB | symbol=",_Symbol," | ticket=",ticket,
               " | retcode=",retcode," | ",Trade.ResultRetcodeDescription(),
               " | error=",GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Reset daily entry state                                          |
//+------------------------------------------------------------------+
void ResetEntryDayIfNeeded(datetime wibNow)
{
   int dayKey=GetWIBDayKey(wibNow); if(dayKey==EntryDayKey) return;
   ArrayInitialize(TradedBuyThisMinute,false); ArrayInitialize(TradedSellThisMinute,false);
   EntryDayKey=dayKey;
   MqlDateTime dt; TimeToStruct(wibNow,dt);
   Print("ENTRY DAY START | ",StringFormat("%04d-%02d-%02d",dt.year,dt.mon,dt.day),
         " WIB | session=",SessionName(dt.hour*60+dt.min));
}

//+------------------------------------------------------------------+
//| Build automatic slots from historical data                       |
//+------------------------------------------------------------------+
void BuildAutoSelection()
{
   ArrayInitialize(AutoBuySlot,false); ArrayInitialize(AutoSellSlot,false);
   ArrayInitialize(AutoBuyWR,0.0); ArrayInitialize(AutoSellWR,0.0);
   ArrayInitialize(AutoBuyN,0); ArrayInitialize(AutoSellN,0);
   ArrayInitialize(AutoBuyWin,0); ArrayInitialize(AutoSellWin,0);
   ArrayInitialize(AutoBuyDD,0.0); ArrayInitialize(AutoSellDD,0.0);
   AutoSelectedCount=0;

   if(TP_Points<=0 || SL_Points<=0)
   { Print("AUTO SELECTION ERROR: TP_Points dan SL_Points harus > 0."); return; }
   RR=(double)TP_Points/SL_Points;
   int barsAvailable=Bars(_Symbol,Timeframe_Test);
   if(barsAvailable<20) { Print("AUTO SELECTION: data historis belum cukup."); return; }
   int seconds=PeriodSeconds(Timeframe_Test); if(seconds<=0) seconds=60;
   int barsNeeded=barsAvailable-1;
   if(AutoSelectionLookbackDays>0)
      barsNeeded=MathMin(barsNeeded,(int)(AutoSelectionLookbackDays*86400/seconds)+1);

   MqlRates rates[]; ArraySetAsSeries(rates,true);
   int copied=CopyRates(_Symbol,Timeframe_Test,0,barsNeeded+1,rates);
   if(copied<20) { Print("AUTO SELECTION: CopyRates tidak memperoleh data cukup. copied=",copied); return; }

   int winB[1440],winS[1440];
   double eqB[1440],peakB[1440],ddB[1440],eqS[1440],peakS[1440],ddS[1440];
   ArrayInitialize(winB,0); ArrayInitialize(winS,0);
   ArrayInitialize(eqB,0.0); ArrayInitialize(peakB,0.0); ArrayInitialize(ddB,0.0);
   ArrayInitialize(eqS,0.0); ArrayInitialize(peakS,0.0); ArrayInitialize(ddS,0.0);
   double winR=(double)TP_Points/SL_Points;

   // Rates series: larger index is older; process historical entries oldest to newest.
   for(int i=copied-1;i>=2;i--)
   {
      datetime wib=ToWIB(rates[i].time); MqlDateTime tm; TimeToStruct(wib,tm);
      int idx=tm.hour*60+tm.min; double entry=rates[i].open;
      int resultB=-1,resultS=-1;
      for(int j=i-1;j>=1;j--)
      {
         bool bTP=(rates[j].high>=entry+TP_Points*_Point);
         bool bSL=(rates[j].low<=entry-SL_Points*_Point);
         if(resultB==-1 && (bTP||bSL)) resultB=(bTP&&!bSL)?1:0;
         bool sTP=(rates[j].low<=entry-TP_Points*_Point);
         bool sSL=(rates[j].high>=entry+SL_Points*_Point);
         if(resultS==-1 && (sTP||sSL)) resultS=(sTP&&!sSL)?1:0;
         if(resultB!=-1 && resultS!=-1) break;
      }
      if(resultB!=-1)
      {
         AutoBuyN[idx]++; if(resultB==1) winB[idx]++;
         eqB[idx]+=(resultB==1?winR:-1.0); if(eqB[idx]>peakB[idx]) peakB[idx]=eqB[idx];
         double d=peakB[idx]-eqB[idx]; if(d>ddB[idx]) ddB[idx]=d;
      }
      if(resultS!=-1)
      {
         AutoSellN[idx]++; if(resultS==1) winS[idx]++;
         eqS[idx]+=(resultS==1?winR:-1.0); if(eqS[idx]>peakS[idx]) peakS[idx]=eqS[idx];
         double d=peakS[idx]-eqS[idx]; if(d>ddS[idx]) ddS[idx]=d;
      }
   }

   for(int k=0;k<1440;k++)
   {
      AutoBuyWin[k]=winB[k]; AutoSellWin[k]=winS[k];
      AutoBuyWR[k]=(AutoBuyN[k]>0?(double)winB[k]/AutoBuyN[k]*100.0:0.0);
      AutoSellWR[k]=(AutoSellN[k]>0?(double)winS[k]/AutoSellN[k]*100.0:0.0);
      AutoBuyDD[k]=ddB[k]; AutoSellDD[k]=ddS[k];
      int totalN=AutoBuyN[k]+AutoSellN[k];
      bool buyOK=(totalN>=MinSamplesTotal && AutoBuyN[k]>0 && AutoBuyWR[k]>=Min_WR && ddB[k]<DD_Safe && ddB[k]<DD_Danger);
      bool sellOK=(totalN>=MinSamplesTotal && AutoSellN[k]>0 && AutoSellWR[k]>=Min_WR && ddS[k]<DD_Safe && ddS[k]<DD_Danger);
      if(buyOK && sellOK)
      {
         if(AutoBuyWR[k]>AutoSellWR[k]) AutoBuySlot[k]=true;
         else if(AutoSellWR[k]>AutoBuyWR[k]) AutoSellSlot[k]=true;
      }
      else if(buyOK) AutoBuySlot[k]=true;
      else if(sellOK) AutoSellSlot[k]=true;

      if(AutoBuySlot[k]||AutoSellSlot[k])
      {
         AutoSelectedCount++; bool isBuy=AutoBuySlot[k];
         Print(StringFormat("AUTO SLOT %02d:%02d WIB | %s | WR %.2f%% | N=%d | W=%d | L=%d | DD=%.2fR",
               k/60,k%60,(isBuy?"BUY":"SELL"),(isBuy?AutoBuyWR[k]:AutoSellWR[k]),
               (isBuy?AutoBuyN[k]:AutoSellN[k]),(isBuy?AutoBuyWin[k]:AutoSellWin[k]),
               (isBuy?AutoBuyN[k]-AutoBuyWin[k]:AutoSellN[k]-AutoSellWin[k]),
               (isBuy?AutoBuyDD[k]:AutoSellDD[k])));
      }
   }
   Print("AUTO SELECTION COMPLETE | lookback days=",AutoSelectionLookbackDays,
         " | timeframe=",EnumToString(Timeframe_Test)," | selected slots=",AutoSelectedCount,
         " | RR=",DoubleToString(RR,2)," | WR>=",DoubleToString(Min_WR,1),"%",
         " | total N>=",MinSamplesTotal," | DD<",DoubleToString(DD_Safe,1),"R and DD<",
         DoubleToString(DD_Danger,1),"R");
}

//+------------------------------------------------------------------+
//| Refresh automatic selection once per new WIB day                 |
//+------------------------------------------------------------------+
void RefreshSelectionIfNewDay(datetime wibNow)
{
   int dayKey=GetWIBDayKey(wibNow); if(dayKey==LastSelectionDayKey) return;
   if(LastSelectionDayKey==-1) { LastSelectionDayKey=dayKey; return; }
   LastSelectionDayKey=dayKey;
   Print("DAILY SELECTION REFRESH | ",TimeToString(wibNow,TIME_DATE)," WIB | rebuilding historical slots...");
   BuildAutoSelection();
   Print("DAILY SELECTION READY | selected slots=",AutoSelectedCount," | RR=",DoubleToString(RR,2));
}

//+------------------------------------------------------------------+
//| Profit factor based on R                                         |
//+------------------------------------------------------------------+
double CalcPF(int wins,int total)
{
   if(total<=0) return 0.0;
   int losses=total-wins; double grossProfit=wins*RR, grossLoss=losses*1.0;
   if(grossLoss<=0.0) { if(grossProfit>0.0) return -1.0; return 0.0; }
   return grossProfit/grossLoss;
}

//+------------------------------------------------------------------+
//| Position result history helpers                                  |
//+------------------------------------------------------------------+
int FindPositionResult(ulong positionId)
{
   for(int i=0;i<ArraySize(PositionResults);i++)
      if(PositionResults[i].position_id==positionId) return i;
   return -1;
}

int AddPositionResult(ulong positionId)
{
   int n=ArraySize(PositionResults);
   if(ArrayResize(PositionResults,n+1)!=n+1) return -1;
   PositionResults[n].position_id=positionId; PositionResults[n].entry_volume=0.0;
   PositionResults[n].exit_volume=0.0; PositionResults[n].net_profit=0.0;
   PositionResults[n].last_exit_time=0;
   return n;
}

//+------------------------------------------------------------------+
//| Update closed trade statistics from account history              |
//+------------------------------------------------------------------+
void UpdateClosedTradeStats(bool forceUpdate=false)
{
   datetime serverNow=TimeCurrent(); if(serverNow<=0) return;
   if(!forceUpdate && LastStatsUpdate>0 && serverNow-LastStatsUpdate<5) return;
   LastStatsUpdate=serverNow;
   datetime wibNow=ToWIB(serverNow); int todayKey=GetWIBDayKey(wibNow);
   TradesTodayWin=0; TradesTodayLoss=0; TradesTotalWin=0; TradesTotalLoss=0;
   ArrayResize(PositionResults,0);
   if(!HistorySelect((datetime)0,serverNow)) { Print("TRADE STATS ERROR | HistorySelect gagal."); return; }
   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dealTicket=HistoryDealGetTicket(i); if(dealTicket==0) continue;
      if(HistoryDealGetString(dealTicket,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(dealTicket,DEAL_MAGIC)!=MagicNumber) continue;
      ENUM_DEAL_TYPE dealType=(ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket,DEAL_TYPE);
      if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL) continue;
      ulong positionId=(ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID); if(positionId==0) continue;
      ENUM_DEAL_ENTRY dealEntry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      double volume=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
      double net=HistoryDealGetDouble(dealTicket,DEAL_PROFIT)+HistoryDealGetDouble(dealTicket,DEAL_COMMISSION)+
                 HistoryDealGetDouble(dealTicket,DEAL_SWAP)+HistoryDealGetDouble(dealTicket,DEAL_FEE);
      datetime dealTime=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
      int p=FindPositionResult(positionId); if(p<0) p=AddPositionResult(positionId); if(p<0) continue;
      PositionResults[p].net_profit+=net;
      if(dealEntry==DEAL_ENTRY_IN) PositionResults[p].entry_volume+=volume;
      else if(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY)
      {
         PositionResults[p].exit_volume+=volume;
         if(dealTime>PositionResults[p].last_exit_time) PositionResults[p].last_exit_time=dealTime;
      }
      else if(dealEntry==DEAL_ENTRY_INOUT)
      {
         PositionResults[p].exit_volume+=volume;
         if(dealTime>PositionResults[p].last_exit_time) PositionResults[p].last_exit_time=dealTime;
      }
   }
   for(int p=0;p<ArraySize(PositionResults);p++)
   {
      double entryVol=PositionResults[p].entry_volume, exitVol=PositionResults[p].exit_volume;
      if(entryVol<=0.0 || exitVol<=0.0) continue;
      double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
      double tolerance=MathMax(volumeStep*0.5,0.0000001);
      if(exitVol+tolerance<entryVol) continue;
      datetime exitTime=PositionResults[p].last_exit_time; if(exitTime<=0) continue;
      double result=PositionResults[p].net_profit;
      if(result>0.0) TradesTotalWin++; else if(result<0.0) TradesTotalLoss++;
      if(GetWIBDayKey(ToWIB(exitTime))==todayKey)
      {
         if(result>0.0) TradesTodayWin++; else if(result<0.0) TradesTodayLoss++;
      }
   }
}

//+------------------------------------------------------------------+
//| Update entry mode panel                                          |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(EA_Mode!=MODE_ENTRY) return;
   datetime serverNow=TimeCurrent(); if(serverNow<=0 || serverNow==LastPanelTime) return;
   LastPanelTime=serverNow; datetime wibNow=ToWIB(serverNow);
   RefreshSelectionIfNewDay(wibNow);
   MqlDateTime dt; TimeToStruct(wibNow,dt); ResetEntryDayIfNeeded(wibNow);
   UpdateClosedTradeStats(); int nowMinute=dt.hour*60+dt.min;

   string nextSlot="Tidak ada slot"; int nextIndex=-1,nextDelta=1441;
   for(int k=0;k<1440;k++)
   {
      if(!AutoBuySlot[k] && !AutoSellSlot[k]) continue;
      int delta=(k-nowMinute+1440)%1440;
      if(delta==0)
      {
         if(AutoBuySlot[k] && TradedBuyThisMinute[k]) continue;
         if(AutoSellSlot[k] && TradedSellThisMinute[k]) continue;
      }
      if(delta<nextDelta) { nextDelta=delta; nextIndex=k; }
   }
   string nextStats="N/A";
   if(nextIndex>=0)
   {
      bool isBuy=AutoBuySlot[nextIndex];
      nextSlot=StringFormat("%02d:%02d WIB %s",nextIndex/60,nextIndex%60,(isBuy?"BUY":"SELL"));
      if(nextDelta>=1440) nextSlot+=" (+1 hari)";
      int n=(isBuy?AutoBuyN[nextIndex]:AutoSellN[nextIndex]);
      int w=(isBuy?AutoBuyWin[nextIndex]:AutoSellWin[nextIndex]);
      int l=n-w; double wr=(isBuy?AutoBuyWR[nextIndex]:AutoSellWR[nextIndex]);
      double dd=(isBuy?AutoBuyDD[nextIndex]:AutoSellDD[nextIndex]); double pf=CalcPF(w,n);
      string pfText=(pf<0.0?"INF":DoubleToString(pf,2));
      nextStats=StringFormat("WR %.2f%% | N %d | W %d | L %d | DD %.2fR | PF %s",wr,n,w,l,dd,pfText);
   }
   int closedToday=TradesTodayWin+TradesTodayLoss, closedTotal=TradesTotalWin+TradesTotalLoss;
   string cutoffState="OFF";
   if(EnableForceCloseAtEntryEnd)
      cutoffState=(IsEntryEndReached(nowMinute)?"CUTOFF ACTIVE":"ARMED AT "+EntryEndTime);
   string panel="SCANNER V7.13.7 - DAILY AUTO ENTRY\n"+
      "Symbol: "+_Symbol+" | TF: "+EnumToString(Timeframe_Test)+"\n"+
      "WIB: "+TimeToString(wibNow,TIME_DATE|TIME_SECONDS)+"\n"+
      "Session: "+SessionName(nowMinute)+" | Filter: "+(UseSessionFilter?"ON":"OFF")+"\n"+
      "Entry window: "+EntryStartTime+" - "+EntryEndTime+"\n"+
      "Force close: "+cutoffState+"\n"+
      "Next slot: "+nextSlot+"\n"+"Slot stats: "+nextStats+"\n"+
      "Selected slots: "+IntegerToString(AutoSelectedCount)+" | RR: "+DoubleToString(RR,2)+"\n"+
      "CLOSED TODAY: WIN "+IntegerToString(TradesTodayWin)+" | LOSE "+IntegerToString(TradesTodayLoss)+" | TOTAL "+IntegerToString(closedToday)+"\n"+
      "CLOSED TOTAL: WIN "+IntegerToString(TradesTotalWin)+" | LOSE "+IntegerToString(TradesTotalLoss)+" | TOTAL "+IntegerToString(closedTotal)+"\n"+
      "Lot: "+DoubleToString(ManualLot,4)+" | SL: "+IntegerToString(SL_Points)+" | TP: "+IntegerToString(TP_Points);
   Comment(panel);
}

//+------------------------------------------------------------------+
//| Automatic entry                                                  |
//+------------------------------------------------------------------+
void ProcessEntryMode()
{
   datetime serverNow=TimeCurrent(); if(serverNow<=0) return;
   datetime wibNow=ToWIB(serverNow);

   // Force close first, then block all new entries from the cutoff onward.
   ForceCloseAtEntryEnd(wibNow);
   MqlDateTime cutoffDT; TimeToStruct(wibNow,cutoffDT);
   int cutoffMinute=cutoffDT.hour*60+cutoffDT.min;
   if(EnableForceCloseAtEntryEnd && IsEntryEndReached(cutoffMinute)) return;

   RefreshSelectionIfNewDay(wibNow);
   MqlDateTime dt; TimeToStruct(wibNow,dt); int nowMinute=dt.hour*60+dt.min;
   ResetEntryDayIfNeeded(wibNow);
   if(ParseMinuteOfDay(EntryStartTime)<0 || ParseMinuteOfDay(EntryEndTime)<0)
   { Print("ENTRY DISABLED: EntryStartTime/EntryEndTime harus HH:MM."); return; }
   if(!IsMinuteInWindow(nowMinute,EntryStartTime,EntryEndTime)) return;
   if(!IsEnabledSession(nowMinute)) return;

   bool isBuy=false;
   if(AutoBuySlot[nowMinute]) isBuy=true;
   else if(AutoSellSlot[nowMinute]) isBuy=false;
   else return;
   if(isBuy && TradedBuyThisMinute[nowMinute]) return;
   if(!isBuy && TradedSellThisMinute[nowMinute]) return;

   if(!AllowMultiplePositions && IsOurPositionOpen())
   {
      Print("ENTRY SKIP ",FormatJamWIB(wibNow)," ",(isBuy?"BUY":"SELL"),
            " | posisi EA pada simbol ini masih terbuka.");
      if(isBuy) TradedBuyThisMinute[nowMinute]=true; else TradedSellThisMinute[nowMinute]=true;
      return;
   }

   double lot=ManualLot;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(lot<minLot || lot>maxLot || stepLot<=0.0)
   {
      Print("ENTRY ERROR: ManualLot di luar batas simbol. Lot=",DoubleToString(lot,4),
            " min=",DoubleToString(minLot,4)," max=",DoubleToString(maxLot,4)); return;
   }
   lot=MathFloor(lot/stepLot+1e-8)*stepLot;
   int volumeDigits=2;
   if(stepLot>=1.0) volumeDigits=0; else if(stepLot>=0.1) volumeDigits=1;
   else if(stepLot>=0.01) volumeDigits=2; else if(stepLot>=0.001) volumeDigits=3; else volumeDigits=4;
   lot=NormalizeDouble(lot,volumeDigits);

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); double sl=0.0,tp=0.0;
   if(SL_Points>0) sl=NormalizeDouble(isBuy?tick.ask-SL_Points*_Point:tick.bid+SL_Points*_Point,digits);
   if(TP_Points>0) tp=NormalizeDouble(isBuy?tick.ask+TP_Points*_Point:tick.bid-TP_Points*_Point,digits);
   Trade.SetExpertMagicNumber(MagicNumber); Trade.SetDeviationInPoints(Slippage);
   bool sent=false;
   if(isBuy) sent=Trade.Buy(lot,_Symbol,0.0,sl,tp,"Scanner selected BUY");
   else sent=Trade.Sell(lot,_Symbol,0.0,sl,tp,"Scanner selected SELL");
   if(sent)
   {
      if(isBuy) TradedBuyThisMinute[nowMinute]=true; else TradedSellThisMinute[nowMinute]=true;
      Print("ENTRY OK | ",FormatJamWIB(wibNow)," WIB | ",SessionName(nowMinute)," | ",(isBuy?"BUY":"SELL"),
            " | lot=",DoubleToString(lot,volumeDigits)," | SL points=",SL_Points," | TP points=",TP_Points,
            " | retcode=",Trade.ResultRetcode()," ",Trade.ResultRetcodeDescription());
   }
   else Print("ENTRY FAILED | ",FormatJamWIB(wibNow)," WIB | ",(isBuy?"BUY":"SELL"),
              " | retcode=",Trade.ResultRetcode()," ",Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   PointVal=_Point; RR=(SL_Points>0 && TP_Points>0?(double)TP_Points/SL_Points:0.0);
   ArrayInitialize(Stats,0.0); ArrayInitialize(HistoryCountBuy,0); ArrayInitialize(HistoryCountSell,0);
   ArrayInitialize(TradedBuyThisMinute,false); ArrayInitialize(TradedSellThisMinute,false);
   Trade.SetExpertMagicNumber(MagicNumber); Trade.SetDeviationInPoints(Slippage);
   if(EA_Mode==MODE_SCANNER)
      Print("SCANNER V7.13.7 STARTED | TF:",EnumToString(Timeframe_Test)," | metrics in R");
   else
   {
      Print("ENTRY MODE STARTED | automatic historical slot selection | active=",EntryStartTime,"-",EntryEndTime,
            " WIB | force close=",(EnableForceCloseAtEntryEnd?"ON":"OFF"),
            " | lot=",DoubleToString(ManualLot,4)," | SL=",SL_Points," TP=",TP_Points,
            " | RR=",DoubleToString(RR,2)," | session filter=",(UseSessionFilter?"ON":"OFF"),
            " | GMT offset=",GMT_Offset);
      BuildAutoSelection();
      datetime initialWIB=ToWIB(TimeCurrent()); LastSelectionDayKey=GetWIBDayKey(initialWIB);
      EventSetTimer(1);
      UpdateClosedTradeStats(true); UpdatePanel();
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(EA_Mode==MODE_ENTRY) { ProcessEntryMode(); UpdatePanel(); return; }
   // SCANNER MODE: original scanning flow retained.
   datetime curr_bar=iTime(_Symbol,Timeframe_Test,0);
   if(curr_bar==0 || curr_bar==LastBarTime) return;
   LastBarTime=curr_bar;
   datetime wib_time=ToWIB(curr_bar); MqlDateTime dt_wib; TimeToStruct(wib_time,dt_wib);
   if(dt_wib.day!=LastDay)
   { ArrayInitialize(TradedBuyThisMinute,false); ArrayInitialize(TradedSellThisMinute,false); LastDay=dt_wib.day; }
   int idx=dt_wib.hour*60+dt_wib.min; double open_price=iOpen(_Symbol,Timeframe_Test,0);
   double tp_dist=(TP_Points+Slippage)*PointVal, sl_dist=(SL_Points+Slippage)*PointVal;
   int barsInDay=1440/MathMax(1,PeriodSeconds(Timeframe_Test)); if(barsInDay<0) barsInDay=0;

   if(!TradedBuyThisMinute[idx])
   {
      int resultBuy=-1;
      for(int i=1;i<3000;i++)
      {
         datetime t=iTime(_Symbol,Timeframe_Test,i); if(t==0) break;
         if(iHigh(_Symbol,Timeframe_Test,i)>=open_price+tp_dist) { resultBuy=1; break; }
         if(iLow(_Symbol,Timeframe_Test,i)<=open_price-sl_dist) { resultBuy=0; break; }
      }
      if(resultBuy!=-1)
      {
         TradedBuyThisMinute[idx]=true; Stats[idx][1]++; if(resultBuy==1) Stats[idx][0]++;
         if(HistoryCountBuy[idx]<1000) HistoryBuy[idx][HistoryCountBuy[idx]++]=resultBuy;
         double profitR=(resultBuy==1?RR:-1.0); Stats[idx][4]+=profitR;
         if(Stats[idx][4]>Stats[idx][5]) Stats[idx][5]=Stats[idx][4];
         double dd=Stats[idx][5]-Stats[idx][4]; if(dd>Stats[idx][6]) Stats[idx][6]=dd;
      }
   }
   if(!TradedSellThisMinute[idx])
   {
      int resultSell=-1;
      for(int i=1;i<3000;i++)
      {
         datetime t=iTime(_Symbol,Timeframe_Test,i); if(t==0) break;
         if(iLow(_Symbol,Timeframe_Test,i)<=open_price-tp_dist) { resultSell=1; break; }
         if(iHigh(_Symbol,Timeframe_Test,i)>=open_price+sl_dist) { resultSell=0; break; }
      }
      if(resultSell!=-1)
      {
         TradedSellThisMinute[idx]=true; Stats[idx][3]++; if(resultSell==1) Stats[idx][2]++;
         if(HistoryCountSell[idx]<1000) HistorySell[idx][HistoryCountSell[idx]++]=resultSell;
         double profitR=(resultSell==1?RR:-1.0); Stats[idx][4]+=profitR;
         if(Stats[idx][4]>Stats[idx][5]) Stats[idx][5]=Stats[idx][4];
         double dd=Stats[idx][5]-Stats[idx][4]; if(dd>Stats[idx][6]) Stats[idx][6]=dd;
      }
   }
}

//+------------------------------------------------------------------+
//| Timer                                                            |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(EA_Mode!=MODE_ENTRY) return;
   datetime serverNow=TimeCurrent();
   if(serverNow>0)
   {
      datetime wibNow=ToWIB(serverNow);
      // Important: force close still runs if no new market tick arrives.
      ForceCloseAtEntryEnd(wibNow);
      RefreshSelectionIfNewDay(wibNow);
   }
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer(); Comment("");
   if(EA_Mode==MODE_ENTRY)
   {
      UpdateClosedTradeStats(true);
      Print("ENTRY MODE STOPPED | CLOSED WIN TODAY=",TradesTodayWin,
            " | CLOSED LOSE TODAY=",TradesTodayLoss," | CLOSED WIN TOTAL=",TradesTotalWin,
            " | CLOSED LOSE TOTAL=",TradesTotalLoss);
      return;
   }
   Print("\n================ HASIL 24 JAM FULL WIB V7.13.7 TF:",EnumToString(Timeframe_Test)," ================");
   Print("JAM_WIB | BUY_WR% | SELL_WR% | N | DD(R) | MaxLoseB | MaxLoseS | REKOMENDASI");
   Print("----------------------------------------------------------------------------");
   for(int i=0;i<1440;i++)
   {
      double wr_buy=0.0,wr_sell=0.0; int maxWinB=0,maxLoseB=0,maxWinS=0,maxLoseS=0;
      if(Stats[i][1]>0) wr_buy=Stats[i][0]/Stats[i][1]*100.0;
      if(Stats[i][3]>0) wr_sell=Stats[i][2]/Stats[i][3]*100.0;
      int totalN=(int)(Stats[i][1]+Stats[i][3]); int tempBuy[1000],tempSell[1000];
      for(int j=0;j<HistoryCountBuy[i];j++) tempBuy[j]=HistoryBuy[i][j];
      for(int j=0;j<HistoryCountSell[i];j++) tempSell[j]=HistorySell[i][j];
      GetConsecutive(tempBuy,HistoryCountBuy[i],maxWinB,maxLoseB);
      GetConsecutive(tempSell,HistoryCountSell[i],maxWinS,maxLoseS);
      string edge="NONE"; double dd=Stats[i][6];
      if(dd>=DD_Danger) edge=">>> SKIP <<< BAHAYA";
      else if(dd<DD_Safe && totalN>=10)
      {
         if(wr_buy>=Min_WR && wr_buy>wr_sell) edge=">>> BUY <<< AMAN";
         else if(wr_sell>=Min_WR && wr_sell>wr_buy) edge=">>> SELL <<< AMAN";
      }
      int jam=i/60,menit=i%60;
      datetime dummy=StringToTime(StringFormat("2026.01.01 %02d:%02d",jam,menit));
      string jam_wib=FormatJamWIB(dummy);
      Print(StringFormat("%s | %7.2f%% | %8.2f%% | %3d | %6.2fR | %8d | %8d | %-20s",
            jam_wib,wr_buy,wr_sell,totalN,dd,maxLoseB,maxLoseS,edge));
   }
   Print("================================================================");
}
