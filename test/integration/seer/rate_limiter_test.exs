defmodule Seer.RateLimiterTest do
  use ExUnit.Case, async: false

  import Seer.TestHelpers

  alias Seer.RateLimiter

  setup :clean_state

  setup do
    {:ok, pid} =
      RateLimiter.start_link(
        limits: %{
          read: {5, 60},
          write: {2, 60},
          expensive: {1, 60}
        },
        global_multiplier: 100
      )

    on_exit(fn -> safe_stop(pid) end)

    circuit_id = :crypto.strong_rand_bytes(16)
    %{pid: pid, circuit_id: circuit_id}
  end

  # --- check/2 ---

  describe "check/2" do
    test "allows requests within limits", %{circuit_id: cid} do
      assert :ok = RateLimiter.check(cid, :read)
    end

    test "allows multiple requests up to limit", %{circuit_id: cid} do
      for _i <- 1..5 do
        assert :ok = RateLimiter.check(cid, :read)
      end
    end

    test "rejects requests exceeding per-circuit limit", %{circuit_id: cid} do
      for _i <- 1..5 do
        assert :ok = RateLimiter.check(cid, :read)
      end

      assert {:error, :rate_limited} = RateLimiter.check(cid, :read)
    end

    test "different circuits have separate limits" do
      cid1 = :crypto.strong_rand_bytes(16)
      cid2 = :crypto.strong_rand_bytes(16)

      for _i <- 1..5 do
        assert :ok = RateLimiter.check(cid1, :read)
      end

      assert :ok = RateLimiter.check(cid2, :read)
    end

    test "different operations have separate limits", %{circuit_id: cid} do
      for _i <- 1..5 do
        assert :ok = RateLimiter.check(cid, :read)
      end

      assert {:error, :rate_limited} = RateLimiter.check(cid, :read)
      assert :ok = RateLimiter.check(cid, :write)
    end

    test "rejects unknown operation types", %{circuit_id: cid} do
      assert {:error, {:unknown_operation, :unknown_op}} = RateLimiter.check(cid, :unknown_op)
    end

    test "write operation has lower limit", %{circuit_id: cid} do
      assert :ok = RateLimiter.check(cid, :write)
      assert :ok = RateLimiter.check(cid, :write)
      assert {:error, :rate_limited} = RateLimiter.check(cid, :write)
    end

    test "expensive operation has limit of 1", %{circuit_id: cid} do
      assert :ok = RateLimiter.check(cid, :expensive)
      assert {:error, :rate_limited} = RateLimiter.check(cid, :expensive)
    end
  end

  # --- apply_multiplier/3 ---

  describe "apply_multiplier/3" do
    test "applies multiplier to a circuit", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      assert :ok = RateLimiter.apply_multiplier(cid, 3, expires)
      assert RateLimiter.get_multiplier(cid) == 3
    end

    test "multiplier reduces effective rate limit", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 5, expires)

      # read limit=5, multiplier=5 -> effective max = max(1, 5/5) = 1
      assert :ok = RateLimiter.check(cid, :read)
      assert {:error, :rate_limited} = RateLimiter.check(cid, :read)
    end

    test "multiplier expires", %{circuit_id: cid} do
      past = System.monotonic_time(:second) - 1
      RateLimiter.apply_multiplier(cid, 10, past)

      assert RateLimiter.get_multiplier(cid) == 1
    end

    test "higher multiplier overwrites lower", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 2, expires)
      RateLimiter.apply_multiplier(cid, 8, expires)

      assert RateLimiter.get_multiplier(cid) == 8
    end
  end

  # --- get_multiplier/1 ---

  describe "get_multiplier/1" do
    test "returns 1 for circuit with no multiplier" do
      cid = :crypto.strong_rand_bytes(16)
      assert RateLimiter.get_multiplier(cid) == 1
    end

    test "returns active multiplier", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 4, expires)
      assert RateLimiter.get_multiplier(cid) == 4
    end

    test "returns 1 for expired multiplier", %{circuit_id: cid} do
      past = System.monotonic_time(:second) - 10
      RateLimiter.apply_multiplier(cid, 5, past)
      assert RateLimiter.get_multiplier(cid) == 1
    end
  end

  # --- reset/1 ---

  describe "reset/1" do
    test "clears multiplier and escalation state for a circuit", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 5, expires)
      assert RateLimiter.get_multiplier(cid) == 5

      RateLimiter.reset(cid)
      assert RateLimiter.get_multiplier(cid) == 1
    end

    test "clears multiplier", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 10, expires)
      assert RateLimiter.get_multiplier(cid) == 10

      RateLimiter.reset(cid)
      assert RateLimiter.get_multiplier(cid) == 1
    end

    test "reset is idempotent" do
      cid = :crypto.strong_rand_bytes(16)
      assert :ok = RateLimiter.reset(cid)
      assert :ok = RateLimiter.reset(cid)
    end

    test "reset does not affect other circuits" do
      cid1 = :crypto.strong_rand_bytes(16)
      cid2 = :crypto.strong_rand_bytes(16)

      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid1, 5, expires)
      RateLimiter.apply_multiplier(cid2, 7, expires)

      RateLimiter.reset(cid1)
      assert RateLimiter.get_multiplier(cid1) == 1
      assert RateLimiter.get_multiplier(cid2) == 7
    end
  end

  # --- limits/0 ---

  describe "limits/0" do
    test "returns the configured limits" do
      limits = RateLimiter.limits()
      assert is_map(limits)
      assert Map.has_key?(limits, :read)
      assert Map.has_key?(limits, :write)
      assert Map.has_key?(limits, :expensive)
    end
  end

  # --- configurable limits ---

  describe "configurable limits" do
    test "effective max never below 1 with high multiplier", %{circuit_id: cid} do
      expires = System.monotonic_time(:second) + 300
      RateLimiter.apply_multiplier(cid, 100, expires)

      # read limit=5, multiplier=100 -> effective = max(1, 5/100) = max(1, 0) = 1
      assert :ok = RateLimiter.check(cid, :read)
      assert {:error, :rate_limited} = RateLimiter.check(cid, :read)
    end
  end

  # --- GenServer lifecycle ---

  describe "GenServer lifecycle" do
    test "handles cleanup message without crashing", %{pid: pid} do
      send(pid, :cleanup)

      await_condition(fn -> Process.alive?(pid) end)
    end

    test "handles unknown messages without crashing", %{pid: pid} do
      send(pid, :unknown_message)

      await_condition(fn -> Process.alive?(pid) end)
    end
  end
end
