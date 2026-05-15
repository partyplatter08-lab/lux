defmodule Lux.Prisms.Hyperliquid.HyperliquidOrderManagementPrism do
  @moduledoc """
  Plans Hyperliquid perpetual order, cancel, leverage, and margin actions.

  The prism validates request shape, builds the compact exchange action used by
  Hyperliquid signing adapters, and can run a local risk check when user state
  and mid prices are supplied. It does not handle private keys or submit live
  orders by itself.
  """

  use Lux.Prism,
    name: "Hyperliquid Perps Order Management",
    description: "Validates and plans Hyperliquid order, cancel, leverage, and margin actions",
    input_schema: %{
      type: :object,
      properties: %{
        operation: %{
          type: :string,
          enum: ["order", "cancel", "set_leverage", "update_margin"],
          description: "Action to plan"
        },
        coin: %{type: :string, description: "Perpetual coin symbol, such as ETH"},
        asset_index: %{type: :integer, description: "Optional asset index from Hyperliquid meta"},
        meta: %{type: :object, description: "Optional Hyperliquid meta payload with universe"},
        is_buy: %{type: :boolean},
        sz: %{type: :number},
        limit_px: %{type: :number},
        order_type: %{type: :object},
        reduce_only: %{type: :boolean},
        oid: %{type: [:integer, :string]},
        cloid: %{type: :string},
        leverage: %{type: :integer},
        is_cross: %{type: :boolean},
        amount: %{type: :number},
        action: %{type: :string, enum: ["add", "remove"]},
        user_state: %{type: :object},
        mids: %{type: :object},
        policy: %{type: :object}
      },
      required: ["operation", "coin"]
    },
    output_schema: %{
      type: :object,
      properties: %{
        status: %{type: :string},
        operation: %{type: :string},
        request: %{type: :object},
        exchange_action: %{type: :object},
        risk_decision: %{type: :object}
      },
      required: ["status", "operation", "request", "exchange_action"]
    }

  alias Lux.Integrations.Hyperliquid.Perps

  def handler(%{operation: "order"} = input, _ctx) do
    with {:ok, request} <- Perps.order_request(input),
         {:ok, exchange_action} <- Perps.order_action(input, action_opts(input)) do
      {:ok,
       %{
         status: "planned",
         operation: "order",
         request: request,
         exchange_action: exchange_action,
         risk_decision: risk_decision(input)
       }}
    end
  end

  def handler(%{operation: "cancel"} = input, _ctx) do
    with {:ok, request} <- Perps.cancel_request(input),
         {:ok, exchange_action} <- Perps.cancel_action(input, action_opts(input)) do
      {:ok,
       %{
         status: "planned",
         operation: "cancel",
         request: request,
         exchange_action: exchange_action
       }}
    end
  end

  def handler(%{operation: "set_leverage"} = input, _ctx) do
    with {:ok, request} <- Perps.leverage_request(input),
         {:ok, exchange_action} <- Perps.leverage_action(input, action_opts(input)) do
      {:ok,
       %{
         status: "planned",
         operation: "set_leverage",
         request: request,
         exchange_action: exchange_action
       }}
    end
  end

  def handler(%{operation: "update_margin"} = input, _ctx) do
    with {:ok, request} <- Perps.margin_request(input),
         {:ok, exchange_action} <- Perps.margin_action(input, action_opts(input)) do
      {:ok,
       %{
         status: "planned",
         operation: "update_margin",
         request: request,
         exchange_action: exchange_action
       }}
    end
  end

  def handler(_input, _ctx),
    do: {:error, ["operation must be order, cancel, set_leverage, or update_margin"]}

  defp action_opts(input) do
    %{
      meta: Map.get(input, :meta),
      asset_index: Map.get(input, :asset_index)
    }
  end

  defp risk_decision(%{user_state: user_state, mids: mids} = input) do
    case Perps.risk_check(user_state, mids, input, policy: Map.get(input, :policy, %{})) do
      {:ok, decision} -> decision
      {:error, decision} -> decision
    end
  end

  defp risk_decision(_input), do: nil
end
