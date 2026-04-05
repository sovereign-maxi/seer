defmodule Seer.Difficulty do
  @moduledoc """
  Adaptive PoW difficulty scaling based on request throughput.

  Uses an exponential moving average (EMA) of request rate to scale
  difficulty between configurable bounds. Current difficulty is stored
  in `:persistent_term` for lock-free reads from any process.

  ## Configuration

      Seer.Difficulty.start_link(
        min_difficulty: 12,
        max_difficulty: 28,
        low_threshold: 10,
        tick_interval_ms: 5_000
      )
  """

  use GenServer

  require Logger

  @default_min 12
  @default_max 28
  @default_low_threshold 10
  @default_tick_ms 5_000
  @ema_alpha 0.1
  @max_drop_per_tick 2
  @pt_key __MODULE__

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current PoW difficulty. Lock-free read from `:persistent_term`."
  @spec current() :: non_neg_integer()
  def current do
    :persistent_term.get(@pt_key, @default_min)
  end

  @doc "Records a request for throughput measurement."
  @spec record_request(GenServer.server()) :: :ok
  def record_request(server \\ __MODULE__) do
    GenServer.cast(server, :record_request)
  end

  @doc "Returns current stats for monitoring."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    min_d = Keyword.get(opts, :min_difficulty, @default_min)
    max_d = Keyword.get(opts, :max_difficulty, @default_max)
    low_threshold = Keyword.get(opts, :low_threshold, @default_low_threshold)
    tick_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_ms)

    if min_d < 0 or max_d < min_d do
      raise ArgumentError,
            "Difficulty: min_difficulty (#{min_d}) must be >= 0 and <= max_difficulty (#{max_d})"
    end

    if low_threshold <= 0 do
      raise ArgumentError, "Difficulty: low_threshold must be > 0, got: #{low_threshold}"
    end

    :persistent_term.put(@pt_key, min_d)
    schedule_tick(tick_ms)

    {:ok,
     %{
       min_difficulty: min_d,
       max_difficulty: max_d,
       low_threshold: low_threshold,
       tick_interval_ms: tick_ms,
       request_count: 0,
       ema_rate: 0.0,
       current_difficulty: min_d
     }}
  end

  @impl GenServer
  def handle_cast(:record_request, state) do
    {:noreply, %{state | request_count: state.request_count + 1}}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       difficulty: state.current_difficulty,
       ema_rate: state.ema_rate,
       raw_count: state.request_count,
       min_difficulty: state.min_difficulty,
       max_difficulty: state.max_difficulty
     }, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    raw_rate = state.request_count
    ema = state.ema_rate * (1 - @ema_alpha) + raw_rate * @ema_alpha

    new_difficulty = compute_difficulty(ema, state)
    clamped = clamp(new_difficulty, state.min_difficulty, state.max_difficulty)

    # Anti-oscillation: max drop of 2 bits per tick
    final =
      if clamped < state.current_difficulty do
        max(clamped, state.current_difficulty - @max_drop_per_tick)
      else
        clamped
      end

    if final != state.current_difficulty do
      :persistent_term.put(@pt_key, final)

      Logger.info(
        "Difficulty: adjusted #{state.current_difficulty} -> #{final} (ema=#{Float.round(ema, 1)})"
      )
    end

    schedule_tick(state.tick_interval_ms)

    {:noreply, %{state | request_count: 0, ema_rate: ema, current_difficulty: final}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp compute_difficulty(ema, state) do
    if ema <= state.low_threshold do
      state.min_difficulty
    else
      log_factor = :math.log2(ema / state.low_threshold)
      state.min_difficulty + round(4 * log_factor)
    end
  end

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
