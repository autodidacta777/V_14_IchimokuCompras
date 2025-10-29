//+------------------------------------------------------------------+
//|  EA_Ichimoku_Bull_Kijun_Trailing.mq4                             |
//|  Solo COMPRAS - rebote/ acercamiento a Tenkan, filtro nube,      |
//|  SL en parte inferior de la nube -2 pips, TP $8, trailing en     |
//|  Kijun después de 8 velas (solo progresivo)                      |
//+------------------------------------------------------------------+
#property strict

//--- parámetros de usuario
input double Lots = 0.01;
input double TP_USD = 8.0;
input double CloudSL_SubtractPips = 2.0;    // SL = cloudBottom - 2 pips (para BUY)
input double Tenkan_TolerancePips = 2.0;    // tolerancia para acercamiento a Tenkan (pips)
input double TrailingOffsetPips = 1.0;      // SL = Kijun - 1 pip cuando trailing activo
input int    MaxTrades = 8;
input int    MagicNumber = 777010;

//--- control 1 trade por vela
datetime ultimaVelaOperada = 0;

//--- estructura para registrar trade abierto y la vela de apertura
struct TradeData { int ticket; datetime openBarTime; };
TradeData trades[128];
int tradeCount = 0;

//------------------------------------------------------------------
// Utilidades
//------------------------------------------------------------------
double PipSize()
{
   int d = MarketInfo(Symbol(), MODE_DIGITS);
   double p = MarketInfo(Symbol(), MODE_POINT);
   if(d == 3 || d == 5) return p * 10.0;
   return p;
}

double ValuePerPointForLot()
{
   // Valor monetario de 1 "point" para 1 lote (MODE_TICKVALUE).
   double v = MarketInfo(Symbol(), MODE_TICKVALUE);
   if(v <= 0) v = 0.0001;
   return v;
}

int CountEAOpenOrders()
{
   int cnt = 0;
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            cnt++;
   }
   return cnt;
}

datetime GetOpenBarTimeForTicket(int ticket)
{
   for(int i=0; i<tradeCount; i++)
      if(trades[i].ticket == ticket) return trades[i].openBarTime;
   return 0;
}

//------------------------------------------------------------------
// OnTick
//------------------------------------------------------------------
void OnTick()
{
   // 1) Limite de operaciones simultaneas
   if(CountEAOpenOrders() >= MaxTrades) return;

   // 2) Control: max 1 operación por vela
   datetime currentBarTime = iTime(NULL, 0, 0);
   if(currentBarTime == ultimaVelaOperada) return;

   // 3) Calcular Ichimoku (parámetros estándar)
   double tenkan0 = iIchimoku(NULL,0,9,26,52,MODE_TENKANSEN,0);
   double kijun0  = iIchimoku(NULL,0,9,26,52,MODE_KIJUNSEN,0);
   double senkouA = iIchimoku(NULL,0,9,26,52,MODE_SENKOUSPANA,26);
   double senkouB = iIchimoku(NULL,0,9,26,52,MODE_SENKOUSPANB,26);

   double cloudTop = MathMax(senkouA, senkouB);
   double cloudBottom = MathMin(senkouA, senkouB);

   // 4) Filtros de entrada: Precio por encima de la nube y Tenkan > Kijun (tendencia alcista)
   bool porEncimaNube = (Bid > cloudTop);
   bool tendenciaAlcista = (tenkan0 > kijun0);

   // 5) Condición rebote/ acercamiento a Tenkan (tolerancia)
   double pip = PipSize();
   double tol = Tenkan_TolerancePips * pip;
   double tenkan_prev = iIchimoku(NULL,0,9,26,52,MODE_TENKANSEN,1);
   double close_prev = iClose(NULL,0,1);

   // Para BUY: rebote desde abajo -> cierre anterior por debajo de Tenkan y ahora Ask >= Tenkan - tol
   bool cercaTenkan = (MathAbs(Ask - tenkan0) <= tol);
   bool reboteDesdeAbajo = (close_prev < tenkan_prev && Ask >= tenkan0 - tol);

   // 6) Si se cumplen condiciones -> abrir BUY
   if(porEncimaNube && tendenciaAlcista && cercaTenkan && reboteDesdeAbajo)
   {
      // calcular TP en precio (USD -> points)
      double tickValue = ValuePerPointForLot(); // valor de 1 point para 1 lote
      double valuePerPointThisLot = tickValue * Lots; // valor monetario de 1 point para nuestro lote

      if(valuePerPointThisLot <= 0) valuePerPointThisLot = 0.0001;

      double pointsTP = TP_USD / valuePerPointThisLot; // cantidad de "points" (1 point = MarketInfo(...MODE_POINT))
      double point = MarketInfo(Symbol(), MODE_POINT);

      double tp_price = Ask + pointsTP * point;

      // SL inicial = cloudBottom - 2 pips
      double sl_price = cloudBottom - CloudSL_SubtractPips * pip;

      // Fallback: si SL queda muy cerca o por encima del precio, usamos SL por USD
      double pointsSL_fallback = (1.0) / valuePerPointThisLot; // 1 USD fallback
      double fallback_sl_price = Bid - pointsSL_fallback * point;
      if(sl_price >= Ask - 1e-9) sl_price = fallback_sl_price;

      int slippage = 3;
      int ticket = OrderSend(Symbol(), OP_BUY, Lots, Ask, slippage, sl_price, tp_price,
                             "Buy_Tenkan_Rebound_Cloud", MagicNumber, 0, clrGreen);

      if(ticket > 0)
      {
         Print("✅ Compra abierta. Ticket=", ticket, " Price=", DoubleToString(Ask,Digits),
               " SL=", DoubleToString(sl_price,Digits), " TP=", DoubleToString(tp_price,Digits));
         ultimaVelaOperada = currentBarTime;

         // registrar trade con la vela de apertura
         trades[tradeCount].ticket = ticket;
         trades[tradeCount].openBarTime = currentBarTime;
         tradeCount++;
         if(tradeCount > ArraySize(trades)-1) tradeCount = ArraySize(trades)-1; // seguridad
      }
      else
      {
         Print("❌ Error al abrir compra: ", GetLastError());
      }
   }

   // 7) Trailing: activar después de 8 velas desde la apertura y actualizar cada vela
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != OP_BUY) continue;

      int ticket = OrderTicket();
      datetime openBar = GetOpenBarTimeForTicket(ticket);
      if(openBar == 0) continue;

      // calcular cuántas velas han pasado desde la apertura
      int barsPassed = iBarShift(NULL, 0, openBar, true);
      // iBarShift devuelve el shift relativo, si la vela abierta fue la actual, barsPassed = 0; si pasó 8 velas, barsPassed >=8
      if(barsPassed < 8) continue;

      // obtener Kijun actual
      double cur_kijun = iIchimoku(NULL,0,9,26,52,MODE_KIJUNSEN,0);

      // new SL = Kijun - TrailingOffsetPips
      double pip = PipSize();
      double newSL = cur_kijun - TrailingOffsetPips * pip;

      // asegurar que newSL esté por debajo del price actual (Ask), si no forzamos pequeña separación
      if(newSL >= Ask) newSL = Ask - pip;

      double currentSL = OrderStopLoss();

      // solo mover SL si mejora (solo progresivo: subir SL hacia precio -> newSL > currentSL)
      // para BUY, "mejor" significa SL más alto (mayor valor), por eso newSL > currentSL
      bool shouldModify = false;
      if(currentSL == 0) shouldModify = true;
      else if(newSL > currentSL + (0.5 * pip)) shouldModify = true;

      if(shouldModify)
      {
         bool ok = OrderModify(ticket, OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrBlue);
         if(ok)
            Print("🔄 Trailing Kijun aplicado. Ticket=", ticket, " nuevoSL=", DoubleToString(newSL,Digits),
                  " barsPassed=", barsPassed);
         else
            Print("⚠️ Error al modificar SL (trailing): ", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
