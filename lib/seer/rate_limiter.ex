defmodule Seer.RateLimiter do
  @moduledoc """
  Per-circuit and global sliding window rate limiter.

  Uses ETS atomic counters with a two-bucket sliding window.
  Operations and their limits are configurable at startup.

  ## Configuration

      Seer.RateLimiter.start_link(
        limits: %{
          read: {100, 60},     # 100 requests per 60 seconds
          write: {10, 300},    # 10 requests per 300 seconds
          expensive: {5, 300}  # 5 requests per 300 seconds
        },
        global_multiplier: 100 # global limits are 100x per-circuit
      )

  ## Global-bucket sizing

  The global bucket exists to bound the total signing/write cost
  the venue absorbs even under a spray of small attackers. Its
  size is `max_requests * global_multiplier` — a single attacker
  hitting the per-circuit cap contributes only `1/multiplier` to
  the global. Too low a multiplier lets a single attacker willing
  to burn their quota 429 the whole venue's login/read surface.
  Default multiplier is 100 so a single attacker has to genuinely
  flood before other users are affected.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @cleanup_interval_ms 60_000

  @default_limits %{
    read: {100, 60},
    write: {10, 300},
    expensive: {5, 300}
  }

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks if a request is within rate limits.

  Returns `:ok`, `{:error, :rate_limited}`, or `{:error, {:unknown_operation, op}}`
  if the operation is not in the configured limits.
  """
  @spec check(binary(), atom()) :: :ok | {:error, :rate_limited | {:unknown_operation, atom()}}
  def check(circuit_id, operation) do
    limits = :persistent_term.get(Seer.RateLimiter.Config, @default_limits)
    global_mult = :persistent_term.get(Seer.RateLimiter.GlobalMult, 10)

    case Map.get(limits, operation) do
      nil ->
        {:error, {:unknown_operation, operation}}

      {max_requests, window_seconds} ->
        now = System.monotonic_time(:second)
        multiplier = get_multiplier(circuit_id)
        effective_max = max(1, div(max_requests, multiplier))

        with :ok <- check_global(operation, max_requests * global_mult, window_seconds, now) do
          check_circuit(circuit_id, operation, effective_max, window_seconds, now)
        end
    end
  end

  @doc "Applies a rate limit multiplier to a circuit (stricter limits)."
  @spec apply_multiplier(binary(), pos_integer(), integer()) :: :ok
  def apply_multiplier(circuit_id, multiplier, expires_at_mono) do
    :ets.insert(@table, {{:multiplier, circuit_id}, multiplier, expires_at_mono})
    :ok
  end

  @doc "Returns the current multiplier for a circuit (1 if none/expired)."
  @spec get_multiplier(binary()) :: pos_integer()
  def get_multiplier(circuit_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, {:multiplier, circuit_id}) do
      [{{:multiplier, ^circuit_id}, mult, expires}] when now <= expires -> mult
      _other -> 1
    end
  rescue
    ArgumentError -> 1
  end

  @doc "Resets all rate limit entries for a circuit."
  @spec reset(binary()) :: :ok
  def reset(circuit_id) do
    # Rate limit entries have key {{:circuit, circuit_id, operation}, bucket}
    # and value {count, timestamp}. Match on the circuit_id in the nested key.
    :ets.match_delete(@table, {{{:circuit, circuit_id, :_}, :_}, :_, :_})
    :ets.delete(@table, {:multiplier, circuit_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the configured limits."
  @spec limits() :: map()
  def limits do
    :persistent_term.get(Seer.RateLimiter.Config, @default_limits)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    limits_config = Keyword.get(opts, :limits, @default_limits)
    global_mult = Keyword.get(opts, :global_multiplier, 100)

    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :persistent_term.put(Seer.RateLimiter.Config, limits_config)
    :persistent_term.put(Seer.RateLimiter.GlobalMult, global_mult)

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

  defp check_circuit(circuit_id, operation, max_requests, window_seconds, now) do
    bucket = div(now, window_seconds)
    key = {:circuit, circuit_id, operation}
    count = get_sliding_count(key, bucket, window_seconds, now)

    if count < max_requests do
      increment_bucket(key, bucket)
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp check_global(operation, max_requests, window_seconds, now) do
    bucket = div(now, window_seconds)
    key = {:global, :all, operation}
    count = get_sliding_count(key, bucket, window_seconds, now)

    if count < max_requests do
      increment_bucket(key, bucket)
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp get_sliding_count(key, current_bucket, window_seconds, now) do
    current_key = {key, current_bucket}
    prev_key = {key, current_bucket - 1}

    current_count =
      case :ets.lookup(@table, current_key) do
        [{^current_key, count, _ts}] -> count
        _other -> 0
      end

    prev_count =
      case :ets.lookup(@table, prev_key) do
        [{^prev_key, count, _ts}] -> count
        _other -> 0
      end

    elapsed_fraction = rem(now, window_seconds) / window_seconds
    round(current_count + prev_count * (1 - elapsed_fraction))
  rescue
    ArgumentError -> 0
  end

  defp increment_bucket(key, bucket) do
    ets_key = {key, bucket}
    now = System.monotonic_time(:second)

    # Atomic increment. If the key doesn't exist, insert it first.
    # The {2, 1} means: position 2 (count field), increment by 1.
    try do
      :ets.update_counter(@table, ets_key, {2, 1})
      # Update timestamp in position 3
      :ets.update_element(@table, ets_key, {3, now})
    rescue
      ArgumentError ->
        # Key doesn't exist yet; insert with count=1.
        # Race: another process may insert between the failed
        # update_counter and this insert. That's acceptable: the
        # second insert overwrites with count=1, which at worst loses
        # one count (the rate limiter errs conservative).
        :ets.insert(@table, {ets_key, 1, now})
    end
  end

  defp cleanup_expired do
    now = System.monotonic_time(:second)
    cutoff = now - 600

    cleanup_fn = fn
      {key, _count, ts}, _acc when is_integer(ts) and ts < cutoff ->
        :ets.delete(@table, key)

      {{:multiplier, _cid} = key, _mult, expires}, _acc when now > expires ->
        :ets.delete(@table, key)

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
end
