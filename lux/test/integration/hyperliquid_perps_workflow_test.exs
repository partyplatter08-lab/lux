defmodule Lux.Integrations.HyperliquidPerpsWorkflowTest do
  use IntegrationCase, async: true

  alias Lux.Integrations.Hyperliquid.Client
  alias Lux.Integrations.Hyperliquid.Perps
  alias Lux.Prisms.Hyperliquid.HyperliquidOrderManagementPrism
  alias Lux.Prisms.Hyperliquid.HyperliquidPerpsDashboardPrism

  @user "0x0000000000000000000000000000000000000001"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "loads user state, plans a safe order, and builds a trading dashboard" do
    Req.Test.stub(HyperliquidWorkflowMock, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      response =
        case payload["type"] do
          "meta" ->
            %{"universe" => [%{"name" => "BTC"}, %{"name" => "ETH"}]}

          "clearinghouseState" ->
            user_state()

          "allMids" ->
            %{"ETH" => "3000"}

          "openOrders" ->
            [%{"coin" => "ETH", "oid" => 42}]

          "userFills" ->
            [%{"coin" => "ETH", "closedPnl" => "25"}]
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    opts = [plug: {Req.Test, HyperliquidWorkflowMock}]

    assert {:ok, meta} = Client.meta(opts)
    assert {:ok, user_state} = Client.clearinghouse_state(@user, opts)
    assert {:ok, mids} = Client.all_mids(opts)
    assert {:ok, orders} = Client.open_orders(@user, opts)
    assert {:ok, fills} = Client.user_fills(@user, opts)

    order = %{
      operation: "order",
      coin: "ETH",
      meta: meta,
      is_buy: true,
      sz: 0.1,
      limit_px: 3000,
      order_type: %{limit: %{tif: "Gtc"}},
      user_state: user_state,
      mids: mids,
      policy: %{max_position_notional_pct: 0.50}
    }

    assert {:ok, decision} =
             Perps.risk_check(user_state, mids, order, policy: %{max_position_notional_pct: 0.50})

    assert {:ok, planned} = HyperliquidOrderManagementPrism.handler(order, %{})

    assert {:ok, dashboard_result} =
             HyperliquidPerpsDashboardPrism.handler(
               %{address: @user, plug: {Req.Test, HyperliquidWorkflowMock}},
               %{}
             )

    dashboard =
      Perps.dashboard(%{
        user_state: user_state,
        mids: mids,
        fills: fills,
        open_orders: orders
      })

    assert decision.decision == :approved
    assert planned.exchange_action.orders |> hd() |> Map.fetch!(:a) == 1
    assert dashboard.margin.leverage == 1.5
    assert dashboard.pnl.total_pnl == 525.0
    assert dashboard.open_order_count == 1
    assert dashboard.liquidation.status == :healthy
    assert dashboard_result.dashboard.open_order_count == 1
  end

  defp user_state do
    %{
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
  end
end
