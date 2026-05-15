defmodule Lux.Integrations.Hyperliquid.Perps do
  @moduledoc """
  Perpetual trading helpers for Hyperliquid position, margin, PnL, and risk control.

  These functions are deterministic and credential-free. They normalize Hyperliquid
  account payloads, validate order/margin/leverage requests, and build compact
  exchange actions that can be signed by a caller-owned signer.
  """

  @default_policy %{
    max_leverage: 5.0,
    max_order_notional_pct: 0.10,
    max_position_notional_pct: 0.35,
    max_margin_usage_pct: 0.65,
    min_liquidation_buffer_pct: 0.12,
    min_account_value: 0.0
  }

  @limit_tifs ["Alo", "Ioc", "Gtc"]
  @trigger_types ["tp", "sl"]
  @margin_actions ["add", "remove"]

  @doc "Returns the default risk policy used by `risk_check/4`."
  @spec default_policy() :: map()
  def default_policy, do: @default_policy

  @doc "Normalizes Hyperliquid asset positions."
  @spec positions(map()) :: [map()]
  def positions(user_state) when is_map(user_state) do
    user_state
    |> value(:assetPositions, [])
    |> Enum.map(&normalize_position/1)
    |> Enum.reject(&(&1.size == 0.0))
  end

  @doc "Summarizes account margin, leverage, and maintenance usage."
  @spec margin_summary(map()) :: map()
  def margin_summary(user_state) when is_map(user_state) do
    margin = value(user_state, :crossMarginSummary, value(user_state, :marginSummary, %{}))
    account_value = numeric(value(margin, :accountValue, 0))
    total_notional = numeric(value(margin, :totalNtlPos, 0))
    margin_used = numeric(value(margin, :totalMarginUsed, 0))
    maintenance = numeric(value(user_state, :crossMaintenanceMarginUsed, 0))

    %{
      account_value: account_value,
      total_notional: total_notional,
      margin_used: margin_used,
      maintenance_margin_used: maintenance,
      withdrawable: numeric(value(user_state, :withdrawable, 0)),
      leverage: ratio(total_notional, account_value),
      margin_usage: ratio(margin_used, account_value),
      maintenance_usage: ratio(maintenance, account_value)
    }
  end

  @doc "Builds a validated order request compatible with the existing execution prism."
  @spec order_request(map()) :: {:ok, map()} | {:error, [String.t()]}
  def order_request(params) when is_map(params) do
    {order_type, order_type_errors} =
      validate_order_type(value(params, :order_type, %{limit: %{tif: "Gtc"}}))

    request = %{
      coin: value(params, :coin),
      asset_index: value(params, :asset_index),
      is_buy: value(params, :is_buy),
      sz: numeric(value(params, :sz, value(params, :size, 0))),
      limit_px: numeric(value(params, :limit_px, value(params, :price, 0))),
      order_type: order_type,
      reduce_only: value(params, :reduce_only, false),
      cloid: value(params, :cloid),
      grouping: value(params, :grouping, "na")
    }

    errors =
      order_type_errors
      |> maybe_add(not is_binary(request.coin) or request.coin == "", "coin is required")
      |> maybe_add(not is_boolean(request.is_buy), "is_buy must be boolean")
      |> maybe_add(request.sz <= 0, "size must be positive")
      |> maybe_add(request.limit_px <= 0, "limit price must be positive")
      |> maybe_add(not is_boolean(request.reduce_only), "reduce_only must be boolean")

    if errors == [], do: {:ok, request}, else: {:error, Enum.reverse(errors)}
  end

  @doc "Builds a cancel request for oid or cloid order management."
  @spec cancel_request(map()) :: {:ok, map()} | {:error, [String.t()]}
  def cancel_request(params) when is_map(params) do
    request = %{
      coin: value(params, :coin),
      asset_index: value(params, :asset_index),
      oid: value(params, :oid),
      cloid: value(params, :cloid)
    }

    errors =
      []
      |> maybe_add(not is_binary(request.coin) or request.coin == "", "coin is required")
      |> maybe_add(is_nil(request.oid) and is_nil(request.cloid), "oid or cloid is required")

    if errors == [], do: {:ok, request}, else: {:error, Enum.reverse(errors)}
  end

  @doc "Builds a leverage-control request."
  @spec leverage_request(map()) :: {:ok, map()} | {:error, [String.t()]}
  def leverage_request(params) when is_map(params) do
    request = %{
      coin: value(params, :coin),
      asset_index: value(params, :asset_index),
      leverage: round(numeric(value(params, :leverage, 0))),
      is_cross: value(params, :is_cross, true)
    }

    errors =
      []
      |> maybe_add(not is_binary(request.coin) or request.coin == "", "coin is required")
      |> maybe_add(
        request.leverage < 1 or request.leverage > 50,
        "leverage must be between 1 and 50"
      )
      |> maybe_add(not is_boolean(request.is_cross), "is_cross must be boolean")

    if errors == [], do: {:ok, request}, else: {:error, Enum.reverse(errors)}
  end

  @doc "Builds an isolated-margin adjustment request."
  @spec margin_request(map()) :: {:ok, map()} | {:error, [String.t()]}
  def margin_request(params) when is_map(params) do
    action = value(params, :action, "add")
    amount = numeric(value(params, :amount, 0))

    request = %{
      coin: value(params, :coin),
      asset_index: value(params, :asset_index),
      action: action,
      amount: amount,
      margin_delta: if(action == "remove", do: -amount, else: amount),
      is_buy: value(params, :is_buy, true)
    }

    errors =
      []
      |> maybe_add(not is_binary(request.coin) or request.coin == "", "coin is required")
      |> maybe_add(action not in @margin_actions, "action must be add or remove")
      |> maybe_add(amount <= 0, "amount must be positive")
      |> maybe_add(not is_boolean(request.is_buy), "is_buy must be boolean")

    if errors == [], do: {:ok, request}, else: {:error, Enum.reverse(errors)}
  end

  @doc "Builds a compact Hyperliquid order action from a validated request."
  @spec order_action(map(), map() | keyword() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def order_action(order, meta_or_opts \\ nil) do
    with {:ok, request} <- order_request(order),
         {:ok, asset} <- resolve_asset(meta_or_opts, request) do
      compact_order =
        %{
          a: asset,
          b: request.is_buy,
          p: decimal_string(request.limit_px),
          s: decimal_string(abs(request.sz)),
          r: request.reduce_only,
          t: compact_order_type(request.order_type)
        }
        |> maybe_put(:c, request.cloid)

      {:ok, %{type: "order", orders: [compact_order], grouping: request.grouping}}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc "Builds a compact Hyperliquid cancel or cancel-by-cloid action."
  @spec cancel_action(map(), map() | keyword() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def cancel_action(cancel, meta_or_opts \\ nil) do
    with {:ok, request} <- cancel_request(cancel),
         {:ok, asset} <- resolve_asset(meta_or_opts, request) do
      if request.cloid do
        {:ok, %{type: "cancelByCloid", cancels: [%{asset: asset, cloid: request.cloid}]}}
      else
        {:ok, %{type: "cancel", cancels: [%{a: asset, o: request.oid}]}}
      end
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc "Builds a compact Hyperliquid updateLeverage action."
  @spec leverage_action(map(), map() | keyword() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def leverage_action(leverage, meta_or_opts \\ nil) do
    with {:ok, request} <- leverage_request(leverage),
         {:ok, asset} <- resolve_asset(meta_or_opts, request) do
      {:ok,
       %{
         type: "updateLeverage",
         asset: asset,
         isCross: request.is_cross,
         leverage: request.leverage
       }}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc "Builds a compact Hyperliquid updateIsolatedMargin action."
  @spec margin_action(map(), map() | keyword() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def margin_action(margin, meta_or_opts \\ nil) do
    with {:ok, request} <- margin_request(margin),
         {:ok, asset} <- resolve_asset(meta_or_opts, request) do
      {:ok,
       %{
         type: "updateIsolatedMargin",
         asset: asset,
         isBuy: request.is_buy,
         ntli: round(request.margin_delta * 1_000_000)
       }}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc "Returns PnL totals from current positions, fills, and funding records."
  @spec pnl_tracking(map(), [map()], [map()]) :: map()
  def pnl_tracking(user_state, fills \\ [], funding \\ []) do
    open_positions = positions(user_state)

    realized =
      fills
      |> Enum.map(&(numeric(value(&1, :closedPnl, 0)) - numeric(value(&1, :fee, 0))))
      |> Enum.sum()

    funding_total =
      funding
      |> Enum.map(&numeric(value(&1, :delta, value(&1, :payment, 0))))
      |> Enum.sum()

    unrealized = Enum.reduce(open_positions, 0.0, &(&1.unrealized_pnl + &2))
    margin_used = Enum.reduce(open_positions, 0.0, &(&1.margin_used + &2))
    total_pnl = realized + unrealized + funding_total

    %{
      open_positions: open_positions,
      realized_pnl: realized,
      unrealized_pnl: unrealized,
      funding_pnl: funding_total,
      total_pnl: total_pnl,
      margin_used: margin_used,
      return_on_margin: ratio(total_pnl, margin_used)
    }
  end

  @doc "Calculates liquidation buffers and risk levels for open positions."
  @spec liquidation_monitor(map(), map(), keyword() | map()) :: map()
  def liquidation_monitor(user_state, mids, opts \\ []) do
    policy = policy(opts)

    monitored =
      user_state
      |> positions()
      |> Enum.map(fn position ->
        mark = market_price(mids, position.coin, position.mark_price)
        buffer = liquidation_buffer(position, mark)
        level = liquidation_level(buffer, policy)

        position
        |> Map.put(:mark_price, mark)
        |> Map.put(:liquidation_buffer_pct, buffer)
        |> Map.put(:risk_level, level)
        |> Map.put(:liquidation_alert, level in [:warning, :critical])
      end)

    %{
      status:
        if(Enum.any?(monitored, & &1.liquidation_alert), do: :attention_required, else: :healthy),
      positions: monitored,
      alerts:
        monitored
        |> Enum.filter(& &1.liquidation_alert)
        |> Enum.map(
          &"#{&1.coin} liquidation buffer is #{Float.round(&1.liquidation_buffer_pct * 100, 2)}%"
        )
    }
  end

  @doc "Checks a proposed order against margin, leverage, notional, and liquidation policy."
  @spec risk_check(map(), map(), map(), keyword() | map()) ::
          {:ok, map()} | {:error, map() | [String.t()]}
  def risk_check(user_state, mids, order, opts \\ []) do
    with {:ok, request} <- order_request(order) do
      policy = policy(opts)
      margin = margin_summary(user_state)
      mark = market_price(mids, request.coin, request.limit_px)
      order_notional = request.sz * mark
      existing_position = Enum.find(positions(user_state), &(&1.coin == request.coin))

      current_position_notional =
        if existing_position, do: abs(existing_position.position_value), else: 0.0

      projected_position_notional =
        if request.reduce_only do
          max(current_position_notional - order_notional, 0.0)
        else
          current_position_notional + order_notional
        end

      projected_total_notional =
        if request.reduce_only do
          max(margin.total_notional - order_notional, 0.0)
        else
          margin.total_notional + order_notional
        end

      projected_leverage = ratio(projected_total_notional, margin.account_value)
      order_notional_pct = ratio(order_notional, margin.account_value)
      position_notional_pct = ratio(projected_position_notional, margin.account_value)

      projected_margin_usage =
        ratio(
          margin.margin_used + initial_margin(order_notional, projected_leverage),
          margin.account_value
        )

      liquidation = liquidation_monitor(user_state, mids, policy: policy)

      alerts =
        []
        |> maybe_add(
          margin.account_value <= policy.min_account_value,
          "account value is below policy"
        )
        |> maybe_add(
          projected_leverage > policy.max_leverage,
          "projected leverage exceeds policy"
        )
        |> maybe_add(
          order_notional_pct > policy.max_order_notional_pct,
          "order notional exceeds policy"
        )
        |> maybe_add(
          position_notional_pct > policy.max_position_notional_pct,
          "projected position notional exceeds policy"
        )
        |> maybe_add(
          projected_margin_usage > policy.max_margin_usage_pct,
          "projected margin usage exceeds policy"
        )
        |> maybe_add(
          liquidation.status != :healthy,
          "existing position liquidation buffer is below policy"
        )

      decision = %{
        decision: if(alerts == [], do: :approved, else: :blocked),
        order: request,
        mark_price: mark,
        order_notional: order_notional,
        order_notional_pct: order_notional_pct,
        projected_position_notional_pct: position_notional_pct,
        projected_leverage: projected_leverage,
        projected_margin_usage: projected_margin_usage,
        margin: margin,
        liquidation: liquidation,
        policy: policy,
        alerts: Enum.reverse(alerts)
      }

      if decision.decision == :approved, do: {:ok, decision}, else: {:error, decision}
    end
  end

  @doc "Builds a compact trading dashboard payload."
  @spec dashboard(map(), keyword() | map()) :: map()
  def dashboard(input, opts \\ []) do
    user_state = value(input, :user_state, %{})
    mids = value(input, :mids, %{})
    fills = value(input, :fills, [])
    funding = value(input, :funding, [])
    orders = value(input, :open_orders, [])

    liquidation = liquidation_monitor(user_state, mids, opts)

    %{
      status: if(liquidation.status == :healthy, do: :healthy, else: :attention_required),
      margin: margin_summary(user_state),
      positions: positions(user_state),
      pnl: pnl_tracking(user_state, fills, funding),
      liquidation: liquidation,
      open_orders: orders,
      open_order_count: length(orders)
    }
  end

  defp normalize_position(%{"position" => position} = wrapped) do
    position
    |> Map.put_new("cumulativeFunding", value(wrapped, :cumulativeFunding, %{}))
    |> normalize_position()
  end

  defp normalize_position(%{position: position} = wrapped) do
    position
    |> Map.put_new(:cumulativeFunding, value(wrapped, :cumulativeFunding, %{}))
    |> normalize_position()
  end

  defp normalize_position(position) do
    size = numeric(value(position, :szi, value(position, :size, 0)))
    entry = nullable_numeric(value(position, :entryPx))
    liquidation = nullable_numeric(value(position, :liquidationPx))
    leverage = leverage_value(value(position, :leverage))

    %{
      coin: value(position, :coin),
      size: size,
      abs_size: abs(size),
      side: if(size >= 0, do: :long, else: :short),
      entry_price: entry,
      position_value: numeric(value(position, :positionValue, 0)),
      unrealized_pnl: numeric(value(position, :unrealizedPnl, 0)),
      return_on_equity: numeric(value(position, :returnOnEquity, 0)),
      leverage: leverage,
      liquidation_price: liquidation,
      margin_used: numeric(value(position, :marginUsed, 0)),
      max_leverage: numeric(value(position, :maxLeverage, 0)),
      mark_price: numeric(value(position, :markPx, entry || 0)),
      cumulative_funding: numeric(value(value(position, :cumulativeFunding, %{}), :payment, 0))
    }
  end

  defp validate_order_type(order_type) do
    case {value(order_type, :limit), value(order_type, :trigger)} do
      {limit, _trigger} when is_map(limit) ->
        tif = value(limit, :tif)

        if tif in @limit_tifs do
          {%{limit: %{tif: tif}}, []}
        else
          {order_type, ["limit tif must be one of #{Enum.join(@limit_tifs, ", ")}"]}
        end

      {_limit, trigger} when is_map(trigger) ->
        trigger_px = numeric(value(trigger, :triggerPx, value(trigger, :trigger_px, 0)))
        is_market = value(trigger, :isMarket, value(trigger, :is_market))
        tpsl = value(trigger, :tpsl)

        errors =
          []
          |> maybe_add(trigger_px <= 0, "trigger price must be positive")
          |> maybe_add(not is_boolean(is_market), "trigger isMarket must be boolean")
          |> maybe_add(tpsl not in @trigger_types, "trigger tpsl must be tp or sl")

        if errors == [] do
          {%{trigger: %{triggerPx: trigger_px, isMarket: is_market, tpsl: tpsl}}, []}
        else
          {order_type, Enum.reverse(errors)}
        end

      _ ->
        {order_type, ["order_type must include limit or trigger"]}
    end
  end

  defp compact_order_type(%{limit: %{tif: tif}}), do: %{limit: %{tif: tif}}

  defp compact_order_type(%{trigger: trigger}) do
    %{
      trigger: %{
        isMarket: trigger.isMarket,
        triggerPx: decimal_string(trigger.triggerPx),
        tpsl: trigger.tpsl
      }
    }
  end

  defp resolve_asset(meta_or_opts, request) do
    cond do
      is_integer(value(request, :asset_index)) ->
        {:ok, value(request, :asset_index)}

      is_integer(value(opts_map(meta_or_opts), :asset_index)) ->
        {:ok, value(opts_map(meta_or_opts), :asset_index)}

      true ->
        opts = opts_map(meta_or_opts)
        meta = value(opts, :meta, meta_or_opts)
        asset_index(meta, request.coin)
    end
  end

  defp asset_index(meta, coin) when is_map(meta) do
    direct = Map.get(meta, coin)

    cond do
      is_integer(direct) ->
        {:ok, direct}

      is_list(value(meta, :universe)) ->
        meta
        |> value(:universe)
        |> Enum.find_index(&(value(&1, :name) == coin))
        |> case do
          nil -> {:error, "asset_index or meta universe entry for #{coin} is required"}
          index -> {:ok, index}
        end

      true ->
        {:error, "asset_index or meta universe entry for #{coin} is required"}
    end
  end

  defp asset_index(_meta, coin),
    do: {:error, "asset_index or meta universe entry for #{coin} is required"}

  defp liquidation_buffer(%{liquidation_price: nil}, _mark), do: 1.0
  defp liquidation_buffer(_position, mark) when mark <= 0, do: 0.0
  defp liquidation_buffer(%{liquidation_price: liq}, mark), do: abs(mark - liq) / mark

  defp liquidation_level(buffer, policy) when buffer <= policy.min_liquidation_buffer_pct / 2,
    do: :critical

  defp liquidation_level(buffer, policy) when buffer < policy.min_liquidation_buffer_pct,
    do: :warning

  defp liquidation_level(_buffer, _policy), do: :safe

  defp market_price(mids, coin, fallback), do: numeric(value(mids, coin, fallback))

  defp initial_margin(_notional, leverage) when leverage <= 0, do: 0.0
  defp initial_margin(notional, leverage), do: notional / max(leverage, 1.0)

  defp policy(opts), do: Map.merge(@default_policy, opts |> value(:policy, %{}) |> opts_map())

  defp leverage_value(%{"value" => value, "type" => type}),
    do: %{type: type, value: numeric(value)}

  defp leverage_value(%{value: value, type: type}), do: %{type: type, value: numeric(value)}
  defp leverage_value(value), do: %{type: nil, value: numeric(value)}

  defp ratio(_numerator, denominator) when denominator in [0, 0.0], do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp maybe_add(alerts, true, message), do: [message | alerts]
  defp maybe_add(alerts, false, _message), do: alerts

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key, default \\ nil)
  defp value(nil, _key, default), do: default
  defp value(map, key, default) when is_map(map), do: map_get(map, key, default)
  defp value(list, key, default) when is_list(list), do: Keyword.get(list, key, default)

  defp map_get(map, key, default) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      true -> default
    end
  end

  defp opts_map(nil), do: %{}
  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp nullable_numeric(nil), do: nil
  defp nullable_numeric("nil"), do: nil
  defp nullable_numeric(value), do: numeric(value)

  defp numeric(nil), do: 0.0
  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)

  defp decimal_string(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 8)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
