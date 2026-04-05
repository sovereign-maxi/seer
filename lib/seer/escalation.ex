defmodule Seer.Escalation do
  @moduledoc """
  Graduated penalty escalation for abusive circuits.

  Applies exponentially increasing rate limit multipliers to circuits
  that exhibit abusive behaviour. Multipliers are powers of a base
  (default 3): 3x -> 9x -> 27x -> 81x (capped).

  State is ETS-only — no disk persistence (deliberate, for privacy).
  """

  use GenServer

  require Logger

  @table __MODULE__
  @base_multiplier 3
  @max_level 4
  @cooldown_seconds 900
  @cleanup_interval_ms 60_000

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records an abuse event and applies escalating penalty."
  @spec record(binary()) :: :ok
  def record(circuit_id) do
    GenServer.call(__MODULE__, {:record, circuit_id})
  end

  @doc "Returns the escalation status for a circuit."
  @spec status(binary()) :: {:escalated, pos_integer()} | :ok
  def status(circuit_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, circuit_id) do
      [{^circuit_id, level, expires}] when now <= expires ->
        {:escalated, pow(@base_multiplier, level)}

      _other ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns true if the circuit has reached maximum escalation."
  @spec banned?(binary()) :: boolean()
  def banned?(circuit_id) do
    case status(circuit_id) do
      {:escalated, mult} -> mult >= pow(@base_multiplier, @max_level)
      :ok -> false
    end
  end

  @doc "Resets escalation state for a circuit."
  @spec reset(binary()) :: :ok
  def reset(circuit_id) do
    :ets.delete(@table, circuit_id)
    Seer.RateLimiter.reset(circuit_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def handle_call({:record, circuit_id}, _from, state) do
    now = System.monotonic_time(:second)
    expires_at = now + @cooldown_seconds

    level =
      case :ets.lookup(@table, circuit_id) do
        [{^circuit_id, current_level, _expires}] ->
          min(current_level + 1, @max_level)

        _other ->
          1
      end

    multiplier = pow(@base_multiplier, level)
    :ets.insert(@table, {circuit_id, level, expires_at})

    Seer.RateLimiter.apply_multiplier(circuit_id, multiplier, expires_at)

    Logger.warning("Escalation: circuit escalated to level #{level} (#{multiplier}x)")
    {:reply, :ok, state}
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp cleanup_expired do
    now = System.monotonic_time(:second)

    cleanup_fn = fn
      {circuit_id, _level, expires}, _acc when now > expires ->
        :ets.delete(@table, circuit_id)

      _entry, _acc ->
        :ok
    end

    :ets.foldl(cleanup_fn, :ok, @table)
  rescue
    ArgumentError -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp pow(base, exp), do: trunc(:math.pow(base, exp))
end
