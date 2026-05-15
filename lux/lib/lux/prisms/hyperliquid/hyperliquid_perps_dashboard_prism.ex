defmodule Lux.Prisms.Hyperliquid.HyperliquidPerpsDashboardPrism do
  @moduledoc """
  Builds a Hyperliquid perpetual trading dashboard for positions, PnL, margin, and liquidation risk.

  Callers may pass already-fetched `user_state`, `mids`, `open_orders`, `fills`,
  and `funding` for an offline calculation. If those are omitted, the prism uses
  the mockable Hyperliquid client to fetch public info endpoint data for `address`.
  """

  use Lux.Prism,
    name: "Hyperliquid Perps Dashboard",
    description: "Summarizes Hyperliquid positions, margin, PnL, orders, and liquidation risk",
    input_schema: %{
      type: :object,
      properties: %{
        address: %{
          type: :string,
          description: "Wallet, subaccount, or vault address",
          pattern: "^0x[a-fA-F0-9]{40}$"
        },
        user_state: %{type: :object},
        mids: %{type: :object},
        open_orders: %{type: :array},
        fills: %{type: :array},
        funding: %{type: :array},
        policy: %{type: :object}
      },
      required: ["address"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        address: %{type: :string},
        dashboard: %{type: :object}
      },
      required: ["status", "address", "dashboard"]
    }

  alias Lux.Integrations.Hyperliquid.Client
  alias Lux.Integrations.Hyperliquid.Perps

  def handler(%{address: address} = input, _ctx) do
    opts = client_opts(input)

    with {:ok, user_state} <-
           fetch_or_use(input, :user_state, fn -> Client.clearinghouse_state(address, opts) end),
         {:ok, mids} <- fetch_or_use(input, :mids, fn -> Client.all_mids(opts) end),
         {:ok, open_orders} <-
           fetch_or_use(input, :open_orders, fn -> Client.open_orders(address, opts) end),
         {:ok, fills} <- fetch_or_use(input, :fills, fn -> Client.user_fills(address, opts) end) do
      dashboard =
        Perps.dashboard(
          %{
            user_state: user_state,
            mids: mids,
            open_orders: open_orders,
            fills: fills,
            funding: Map.get(input, :funding, [])
          },
          policy: Map.get(input, :policy, %{})
        )

      {:ok, %{status: Atom.to_string(dashboard.status), address: address, dashboard: dashboard}}
    end
  end

  defp fetch_or_use(input, key, fetch_fun) do
    case Map.fetch(input, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_fun.()
    end
  end

  defp client_opts(input) do
    input
    |> Map.take([:base_url, :headers, :plug, :receive_timeout])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
