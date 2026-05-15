defmodule Lux.Prisms.Hyperliquid.PerpsPrismsTest do
  use UnitAPICase, async: true

  alias Lux.Prisms.Hyperliquid.HyperliquidOrderManagementPrism
  alias Lux.Prisms.Hyperliquid.HyperliquidPerpsDashboardPrism

  @address "0x0000000000000000000000000000000000000001"
  @meta %{"universe" => [%{"name" => "BTC"}, %{"name" => "ETH"}]}
  @user_state %{
    "crossMarginSummary" => %{
      "accountValue" => "10000",
      "totalNtlPos" => "15000",
      "totalMarginUsed" => "2000"
    },
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
          "liquidationPx" => "1500",
          "marginUsed" => "1000"
        }
      }
    ]
  }

  test "order management prism plans an order with risk verification" do
    assert {:ok, result} =
             HyperliquidOrderManagementPrism.handler(
               %{
                 operation: "order",
                 coin: "ETH",
                 meta: @meta,
                 is_buy: true,
                 sz: 0.1,
                 limit_px: 3000,
                 order_type: %{limit: %{tif: "Gtc"}},
                 user_state: @user_state,
                 mids: %{"ETH" => "3000"},
                 policy: %{max_position_notional_pct: 0.50}
               },
               %{}
             )

    assert result.status == "planned"
    assert result.exchange_action.type == "order"
    assert result.risk_decision.decision == :approved
  end

  test "order management prism plans leverage and margin controls" do
    assert {:ok, leverage} =
             HyperliquidOrderManagementPrism.handler(
               %{operation: "set_leverage", coin: "ETH", asset_index: 1, leverage: 5},
               %{}
             )

    assert leverage.exchange_action == %{
             type: "updateLeverage",
             asset: 1,
             isCross: true,
             leverage: 5
           }

    assert {:ok, margin} =
             HyperliquidOrderManagementPrism.handler(
               %{
                 operation: "update_margin",
                 coin: "ETH",
                 asset_index: 1,
                 amount: 100,
                 action: "add"
               },
               %{}
             )

    assert margin.exchange_action.ntli == 100_000_000
  end

  test "dashboard prism builds an offline perps summary" do
    assert {:ok, result} =
             HyperliquidPerpsDashboardPrism.handler(
               %{
                 address: @address,
                 user_state: @user_state,
                 mids: %{"ETH" => "3000"},
                 open_orders: [%{"coin" => "ETH", "oid" => 42}],
                 fills: [%{"coin" => "ETH", "closedPnl" => "25"}],
                 policy: %{max_position_notional_pct: 0.50}
               },
               %{}
             )

    assert result.status == "healthy"
    assert result.dashboard.open_order_count == 1
    assert result.dashboard.pnl.total_pnl == 525.0
  end
end
