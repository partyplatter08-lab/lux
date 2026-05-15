defmodule Lux.Integrations.Hyperliquid do
  @moduledoc """
  Shared settings and helpers for Hyperliquid perpetual trading.

  The public info endpoint is safe to call without credentials. Exchange actions
  still require a caller-provided signature before they can be submitted.
  """

  @api_base_url "https://api.hyperliquid.xyz"
  @info_endpoint "/info"
  @exchange_endpoint "/exchange"

  @perp_info_types [
    :meta,
    :all_mids,
    :l2_book,
    :clearinghouse_state,
    :open_orders,
    :frontend_open_orders,
    :order_status,
    :historical_orders,
    :user_fills,
    :user_fills_by_time,
    :user_funding,
    :portfolio,
    :candle_snapshot
  ]

  @doc "Returns default Hyperliquid API settings."
  @spec client_settings() :: map()
  def client_settings do
    %{
      base_url: configured_base_url(),
      info_endpoint: @info_endpoint,
      exchange_endpoint: @exchange_endpoint,
      headers: [{"content-type", "application/json"}]
    }
  end

  @doc "Returns supported info request types used by this integration."
  @spec perp_info_types() :: [atom()]
  def perp_info_types, do: @perp_info_types

  @doc "Converts internal atom names to Hyperliquid info endpoint request types."
  @spec info_type(atom() | String.t()) :: String.t()
  def info_type(:all_mids), do: "allMids"
  def info_type(:l2_book), do: "l2Book"
  def info_type(:clearinghouse_state), do: "clearinghouseState"
  def info_type(:open_orders), do: "openOrders"
  def info_type(:frontend_open_orders), do: "frontendOpenOrders"
  def info_type(:order_status), do: "orderStatus"
  def info_type(:historical_orders), do: "historicalOrders"
  def info_type(:user_fills), do: "userFills"
  def info_type(:user_fills_by_time), do: "userFillsByTime"
  def info_type(:user_funding), do: "userFunding"
  def info_type(:candle_snapshot), do: "candleSnapshot"
  def info_type(type) when is_atom(type), do: Atom.to_string(type)
  def info_type(type) when is_binary(type), do: type

  defp configured_base_url do
    :lux
    |> Application.get_env(:accounts, [])
    |> Keyword.get(:hyperliquid_api_url, @api_base_url)
    |> to_string()
    |> String.trim_trailing("/")
    |> strip_endpoint_suffix()
  end

  defp strip_endpoint_suffix(url) do
    Enum.reduce([@info_endpoint, @exchange_endpoint], url, fn suffix, acc ->
      if String.ends_with?(acc, suffix), do: String.trim_trailing(acc, suffix), else: acc
    end)
  end
end
