defmodule Lux.Integrations.Hyperliquid.Client do
  @moduledoc """
  Req-based Hyperliquid REST client for public info reads and signed exchange payloads.

  Most issue #82 workflows can be exercised through the public `/info` endpoint and
  deterministic exchange action planning. `exchange/2` only submits a payload that
  already includes the required nonce/signature fields.
  """

  alias Lux.Integrations.Hyperliquid

  @type request_opts :: keyword() | map()

  @doc "Calls Hyperliquid's `/info` endpoint with a raw payload."
  @spec info(map(), request_opts()) :: {:ok, term()} | {:error, term()}
  def info(payload, opts \\ %{}) when is_map(payload) do
    request(:post, :info_endpoint, payload, opts)
  end

  @doc "Submits an already signed payload to Hyperliquid's `/exchange` endpoint."
  @spec exchange(map(), request_opts()) :: {:ok, term()} | {:error, term()}
  def exchange(payload, opts \\ %{}) when is_map(payload) do
    request(:post, :exchange_endpoint, payload, opts)
  end

  @doc "Fetches perpetual universe metadata."
  @spec meta(request_opts()) :: {:ok, map()} | {:error, term()}
  def meta(opts \\ %{}), do: info(%{type: Hyperliquid.info_type(:meta)}, opts)

  @doc "Fetches all mid prices."
  @spec all_mids(request_opts()) :: {:ok, map()} | {:error, term()}
  def all_mids(opts \\ %{}), do: info(%{type: Hyperliquid.info_type(:all_mids)}, opts)

  @doc "Fetches an L2 order book snapshot for a perpetual coin."
  @spec l2_book(String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def l2_book(coin, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:l2_book), coin: coin}, opts)
  end

  @doc "Fetches a user's perpetual clearinghouse state."
  @spec clearinghouse_state(String.t(), request_opts()) :: {:ok, map()} | {:error, term()}
  def clearinghouse_state(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:clearinghouse_state), user: normalize_user(user)}, opts)
  end

  @doc "Fetches open orders for a user."
  @spec open_orders(String.t(), request_opts()) :: {:ok, list()} | {:error, term()}
  def open_orders(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:open_orders), user: normalize_user(user)}, opts)
  end

  @doc "Fetches frontend open orders for a user."
  @spec frontend_open_orders(String.t(), request_opts()) :: {:ok, list()} | {:error, term()}
  def frontend_open_orders(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:frontend_open_orders), user: normalize_user(user)}, opts)
  end

  @doc "Fetches order status by order id or client order id."
  @spec order_status(String.t(), integer() | String.t(), request_opts()) ::
          {:ok, map()} | {:error, term()}
  def order_status(user, oid, opts \\ %{}) do
    info(
      %{type: Hyperliquid.info_type(:order_status), user: normalize_user(user), oid: oid},
      opts
    )
  end

  @doc "Fetches historical order records for a user."
  @spec historical_orders(String.t(), request_opts()) :: {:ok, list()} | {:error, term()}
  def historical_orders(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:historical_orders), user: normalize_user(user)}, opts)
  end

  @doc "Fetches recent user fills."
  @spec user_fills(String.t(), request_opts()) :: {:ok, list()} | {:error, term()}
  def user_fills(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:user_fills), user: normalize_user(user)}, opts)
  end

  @doc "Fetches user funding records for a time window."
  @spec user_funding(String.t(), integer(), integer() | nil, request_opts()) ::
          {:ok, list()} | {:error, term()}
  def user_funding(user, start_time, end_time \\ nil, opts \\ %{}) do
    %{
      type: Hyperliquid.info_type(:user_funding),
      user: normalize_user(user),
      startTime: start_time
    }
    |> maybe_put(:endTime, end_time)
    |> info(opts)
  end

  @doc "Fetches portfolio history for a user."
  @spec portfolio(String.t(), request_opts()) :: {:ok, term()} | {:error, term()}
  def portfolio(user, opts \\ %{}) do
    info(%{type: Hyperliquid.info_type(:portfolio), user: normalize_user(user)}, opts)
  end

  @doc "Fetches a recent candle snapshot."
  @spec candle_snapshot(String.t(), String.t(), integer(), integer(), request_opts()) ::
          {:ok, list()} | {:error, term()}
  def candle_snapshot(coin, interval, start_time, end_time, opts \\ %{}) do
    info(
      %{
        type: Hyperliquid.info_type(:candle_snapshot),
        req: %{coin: coin, interval: interval, startTime: start_time, endTime: end_time}
      },
      opts
    )
  end

  defp request(method, endpoint_key, payload, opts) do
    settings = Hyperliquid.client_settings()
    opts = opts_list(opts)
    base_url = Keyword.get(opts, :base_url, settings.base_url) |> String.trim_trailing("/")
    endpoint = Map.fetch!(settings, endpoint_key)
    headers = settings.headers ++ Keyword.get(opts, :headers, [])

    [
      method: method,
      url: base_url <> endpoint,
      headers: headers,
      json: payload
    ]
    |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
    |> Keyword.merge(Keyword.take(opts, [:receive_timeout, :retry, :max_retries]))
    |> maybe_add_plug(Keyword.get(opts, :plug))
    |> Req.new()
    |> Req.request()
    |> normalize_response()
  end

  defp normalize_response({:ok, %{status: status, body: %{"error" => error}}}) do
    {:error, {status, error}}
  end

  defp normalize_response({:ok, %{status: status, body: %{"status" => "err"} = body}})
       when status in 200..299 do
    {:error, body}
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp normalize_response({:ok, %{status: status, body: body}}), do: {:error, {status, body}}
  defp normalize_response({:error, error}), do: {:error, error}

  defp normalize_user(user) when is_binary(user), do: String.downcase(user)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp opts_list(opts) when is_map(opts), do: Map.to_list(opts)
  defp opts_list(opts) when is_list(opts), do: opts

  defp maybe_add_plug(options, nil), do: options
  defp maybe_add_plug(options, plug), do: Keyword.put(options, :plug, plug)
end
