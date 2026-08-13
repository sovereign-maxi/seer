defmodule Seer.NonceStore do
  @moduledoc """
  GenServer that owns the ETS table for PoW nonce tracking.

  Isolates table ownership so nonce state survives request process
  crashes. Nonce consumption is serialized through the GenServer
  to prevent TOCTOU races on concurrent requests.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @cleanup_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records an issued nonce with expiry."
  @spec track_nonce(binary(), term()) :: :ok | {:error, :table_not_available}
  def track_nonce(nonce, value) do
    :ets.insert(@table, {nonce, value})
    :ok
  rescue
    ArgumentError -> {:error, :table_not_available}
  end

  @doc """
  Atomically consumes a nonce. Returns `{:ok, difficulty}` — the
  difficulty the challenge was issued at — if the nonce was issued and
  not expired, `{:error, reason}` otherwise.

  Uses GenServer serialization to prevent TOCTOU races between
  concurrent requests attempting to consume the same nonce.
  """
  @spec consume_nonce(GenServer.server(), binary()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def consume_nonce(server \\ __MODULE__, nonce) do
    GenServer.call(server, {:consume, nonce})
  end

  @doc "Purges expired nonces from the table."
  @spec cleanup() :: :ok
  def cleanup do
    now = System.monotonic_time(:second)

    cleanup_fn = fn
      {nonce, {:issued, expires_at, _difficulty}}, _acc when now > expires_at ->
        :ets.delete(@table, nonce)

      {nonce, {:used, used_at}}, _acc when now - used_at > 300 ->
        :ets.delete(@table, nonce)

      _entry, _acc ->
        :ok
    end

    :ets.foldl(cleanup_fn, :ok, @table)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Clears all nonces (test helper)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the ETS table name."
  @spec table_name() :: atom()
  def table_name, do: @table

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:consume, nonce}, _from, state) do
    now = System.monotonic_time(:second)

    result =
      case :ets.lookup(@table, nonce) do
        [{^nonce, {:issued, expires_at, difficulty}}] when now <= expires_at ->
          :ets.insert(@table, {nonce, {:used, now}})
          {:ok, difficulty}

        [{^nonce, {:issued, _expires_at, _difficulty}}] ->
          :ets.delete(@table, nonce)
          {:error, :nonce_expired}

        [{^nonce, {:used, _at}}] ->
          {:error, :nonce_already_used}

        [] ->
          {:error, :nonce_not_found}

        _malformed_entry ->
          :ets.delete(@table, nonce)
          {:error, :nonce_not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state[:table], do: :ets.delete(state.table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
