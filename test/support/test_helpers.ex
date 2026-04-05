defmodule Seer.TestHelpers do
  @moduledoc """
  Centralized cleanup and process helpers for Seer tests.
  """

  @doc """
  ExUnit setup callback — cleans all ETS tables between tests.
  Use with `setup :clean_state` after importing this module.
  """
  @spec clean_state(map()) :: :ok
  def clean_state(_context \\ %{}) do
    safe_ets_clear(Seer.NonceStore)
    safe_ets_clear(Seer.RateLimiter)
    safe_ets_clear(Seer.Escalation)
    :ok
  end

  @doc "Stops a GenServer safely, catching exits if already dead."
  @spec safe_stop(pid() | atom(), timeout()) :: :ok
  def safe_stop(pid_or_name, timeout \\ 5_000) do
    GenServer.stop(pid_or_name, :normal, timeout)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Polls until `fun` returns truthy or timeout. Raises on timeout."
  @spec await_condition((-> boolean()), pos_integer()) :: :ok
  def await_condition(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "await_condition timed out"
      end

      Process.sleep(10)
      do_poll(fun, deadline)
    end
  end

  defp safe_ets_clear(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  rescue
    _error -> :ok
  end
end
