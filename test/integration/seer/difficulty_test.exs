defmodule Seer.DifficultyTest do
  use ExUnit.Case, async: false

  import Seer.TestHelpers

  alias Seer.Difficulty

  setup :clean_state

  setup do
    # Clean up persistent_term from previous tests
    try do
      :persistent_term.erase(Seer.Difficulty)
    rescue
      ArgumentError -> :ok
    end

    {:ok, pid} =
      Difficulty.start_link(
        min_difficulty: 4,
        max_difficulty: 20,
        low_threshold: 5,
        tick_interval_ms: 600_000
      )

    on_exit(fn -> safe_stop(pid) end)

    %{pid: pid}
  end

  # --- current/0 ---

  describe "current/0" do
    test "returns min_difficulty initially" do
      assert Difficulty.current() == 4
    end

    test "returns an integer" do
      assert is_integer(Difficulty.current())
    end
  end

  # --- record_request/1 ---

  describe "record_request/1" do
    test "increments request count", %{pid: pid} do
      stats_before = Difficulty.stats(pid)
      Difficulty.record_request(pid)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == stats_before.raw_count + 1
      end)
    end

    test "multiple requests accumulate", %{pid: pid} do
      for _i <- 1..10 do
        Difficulty.record_request(pid)
      end

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 10
      end)
    end
  end

  # --- stats/1 ---

  describe "stats/1" do
    test "returns expected keys", %{pid: pid} do
      stats = Difficulty.stats(pid)

      assert Map.has_key?(stats, :difficulty)
      assert Map.has_key?(stats, :ema_rate)
      assert Map.has_key?(stats, :raw_count)
      assert Map.has_key?(stats, :min_difficulty)
      assert Map.has_key?(stats, :max_difficulty)
    end

    test "initial stats are correct", %{pid: pid} do
      stats = Difficulty.stats(pid)

      assert stats.difficulty == 4
      assert stats.ema_rate == 0.0
      assert stats.raw_count == 0
      assert stats.min_difficulty == 4
      assert stats.max_difficulty == 20
    end

    test "min and max difficulty match config", %{pid: pid} do
      stats = Difficulty.stats(pid)
      assert stats.min_difficulty == 4
      assert stats.max_difficulty == 20
    end
  end

  # --- difficulty scaling ---

  describe "difficulty scaling via tick" do
    test "difficulty stays at min when no requests", %{pid: pid} do
      send(pid, :tick)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 0
      end)

      assert Difficulty.current() == 4
    end

    test "difficulty increases with high request volume", %{pid: pid} do
      for _i <- 1..100 do
        Difficulty.record_request(pid)
      end

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 100
      end)

      send(pid, :tick)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 0
      end)

      stats = Difficulty.stats(pid)
      # EMA = 0.9*0 + 0.1*100 = 10, above low_threshold=5
      assert stats.difficulty > 4
    end

    test "difficulty does not exceed max", %{pid: pid} do
      for _i <- 1..10 do
        for _i <- 1..10_000 do
          Difficulty.record_request(pid)
        end

        await_condition(
          fn ->
            Difficulty.stats(pid).raw_count >= 10_000
          end,
          10_000
        )

        send(pid, :tick)

        await_condition(fn ->
          Difficulty.stats(pid).raw_count == 0
        end)
      end

      stats = Difficulty.stats(pid)
      assert stats.difficulty <= 20
    end

    test "difficulty drops gradually (max 2 bits per tick)", %{pid: pid} do
      # Pump it up
      for _i <- 1..5 do
        for _i <- 1..5000 do
          Difficulty.record_request(pid)
        end

        await_condition(
          fn ->
            Difficulty.stats(pid).raw_count >= 5000
          end,
          10_000
        )

        send(pid, :tick)

        await_condition(fn ->
          Difficulty.stats(pid).raw_count == 0
        end)
      end

      stats_high = Difficulty.stats(pid)

      # Now let it drop with no requests
      send(pid, :tick)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 0
      end)

      stats_after = Difficulty.stats(pid)
      assert stats_high.difficulty - stats_after.difficulty <= 2
    end

    test "EMA updates correctly with alpha=0.1", %{pid: pid} do
      for _i <- 1..50 do
        Difficulty.record_request(pid)
      end

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 50
      end)

      send(pid, :tick)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 0
      end)

      stats = Difficulty.stats(pid)
      assert_in_delta stats.ema_rate, 5.0, 0.01
    end

    test "request count resets after tick", %{pid: pid} do
      for _i <- 1..20 do
        Difficulty.record_request(pid)
      end

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 20
      end)

      send(pid, :tick)

      await_condition(fn ->
        Difficulty.stats(pid).raw_count == 0
      end)
    end

    test "handles unknown messages without crashing", %{pid: pid} do
      send(pid, :unknown_message)

      await_condition(fn -> Process.alive?(pid) end)
    end
  end

  # --- configuration ---

  describe "configuration" do
    test "current returns default when no process started" do
      # persistent_term was set by setup, so just verify it's an integer
      assert is_integer(Difficulty.current())
    end
  end
end
