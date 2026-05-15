defmodule Lux.Integrations.Hyperliquid.PerpsTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.Hyperliquid.Perps

  @meta %{"universe" => [%{"name" => "BTC"}, %{"name" => "ETH"}]}
  @user_state %{
    "crossMarginSummary" => %{
      "accountValue" => "10000",
      "totalNtlPos" => "15000",
      "totalMarginUsed" => "2000"
    },
    "crossMaintenanceMarginUsed" => "500",
    "withdrawable" => "7500",
    "assetPositions" => [
      %{
        "position" => %{
          "coin" => "ETH",
          "szi" => "1",
          "entryPx" => "2500",
          "positionValue" => "3000",
          "unrealizedPnl" => "500",
          "returnOnEquity" => "0.16",
          "leverage" => %{"type" => "cross", "value" => 3},
          "liquidationPx" => "2400",
          "marginUsed" => "1000"
        }
      }
    ]
  }

  describe "position and margin tracking" do
    test "normalizes positions and summarizes margin" do
      assert [%{coin: "ETH", side: :long, size: 1.0, liquidation_price: 2400.0}] =
               Perps.positions(@user_state)

      margin = Perps.margin_summary(@user_state)
      assert margin.account_value == 10_000.0
      assert margin.leverage == 1.5
      assert margin.margin_usage == 0.2
      assert margin.maintenance_usage == 0.05
    end

    test "tracks realized, unrealized, and funding PnL" do
      pnl =
        Perps.pnl_tracking(
          @user_state,
          [%{"closedPnl" => "125.5", "fee" => "1.5"}],
          [%{"delta" => "-2"}]
        )

      assert pnl.realized_pnl == 124.0
      assert pnl.unrealized_pnl == 500.0
      assert pnl.funding_pnl == -2.0
      assert pnl.total_pnl == 622.0
      assert pnl.return_on_margin == 0.622
    end
  end

  describe "request and action planning" do
    test "validates order shape and builds compact order actions" do
      assert {:ok, order} =
               Perps.order_request(%{
                 coin: "ETH",
                 is_buy: true,
                 sz: "0.5",
                 limit_px: "3000",
                 order_type: %{limit: %{tif: "Gtc"}}
               })

      assert order.sz == 0.5
      assert order.limit_px == 3000.0

      assert {:ok, action} = Perps.order_action(order, @meta)
      assert action.type == "order"

      assert [%{a: 1, b: true, p: "3000", s: "0.5", r: false, t: %{limit: %{tif: "Gtc"}}}] =
               action.orders

      assert {:error, errors} =
               Perps.order_request(%{coin: "", is_buy: "yes", sz: 0, limit_px: 0})

      assert "coin is required" in errors
      assert "is_buy must be boolean" in errors
    end

    test "builds trigger, cancel, leverage, and isolated margin actions" do
      assert {:ok, trigger_action} =
               Perps.order_action(
                 %{
                   coin: "ETH",
                   is_buy: false,
                   sz: 0.25,
                   limit_px: 2800,
                   reduce_only: true,
                   order_type: %{trigger: %{triggerPx: 2750, isMarket: true, tpsl: "sl"}}
                 },
                 @meta
               )

      assert [%{t: %{trigger: %{triggerPx: "2750", isMarket: true, tpsl: "sl"}}}] =
               trigger_action.orders

      assert {:ok, %{type: "cancel", cancels: [%{a: 1, o: 42}]}} =
               Perps.cancel_action(%{coin: "ETH", oid: 42}, @meta)

      assert {:ok, %{type: "updateLeverage", asset: 1, isCross: true, leverage: 4}} =
               Perps.leverage_action(%{coin: "ETH", leverage: 4}, @meta)

      assert {:ok, %{type: "updateIsolatedMargin", asset: 1, isBuy: true, ntli: -125_000_000}} =
               Perps.margin_action(%{coin: "ETH", amount: 125, action: "remove"}, @meta)
    end
  end

  describe "risk controls" do
    test "blocks orders when liquidation buffer is too small" do
      assert {:error, decision} =
               Perps.risk_check(
                 @user_state,
                 %{"ETH" => "2500"},
                 %{coin: "ETH", is_buy: true, sz: 0.1, limit_px: 2500}
               )

      assert decision.decision == :blocked
      assert "existing position liquidation buffer is below policy" in decision.alerts
      assert decision.liquidation.status == :attention_required
    end

    test "approves small orders when policy passes" do
      safer_state =
        put_in(@user_state, ["assetPositions", Access.at(0), "position", "liquidationPx"], "1500")

      assert {:ok, decision} =
               Perps.risk_check(
                 safer_state,
                 %{"ETH" => "3000"},
                 %{coin: "ETH", is_buy: true, sz: 0.1, limit_px: 3000},
                 policy: %{max_position_notional_pct: 0.50}
               )

      assert decision.decision == :approved
      assert decision.order_notional == 300.0
      assert decision.projected_leverage == 1.53
    end
  end

  describe "dashboard/2" do
    test "builds a compact trading dashboard" do
      dashboard =
        Perps.dashboard(%{
          user_state: @user_state,
          mids: %{"ETH" => "2500"},
          fills: [%{"closedPnl" => "10"}],
          open_orders: [%{"coin" => "ETH"}]
        })

      assert dashboard.margin.account_value == 10_000.0
      assert dashboard.pnl.total_pnl == 510.0
      assert dashboard.open_order_count == 1
      assert dashboard.liquidation.status == :attention_required
    end
  end
end
