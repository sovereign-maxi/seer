defmodule Seer.EscalationTest do
  use ExUnit.Case, async: false

  import Seer.TestHelpers

  alias Seer.Escalation
  alias Seer.RateLimiter

  setup :clean_state

  setup do
    # RateLimiter must be started first (Escalation calls into it)
    {:ok, rl_pid} =
      RateLimiter.start_link(
        limits: %{read: {100, 60}},
        global_multiplier: 100
      )

    {:ok, esc_pid} = Escalation.start_link()

    on_exit(fn ->
      safe_stop(esc_pid)
      safe_stop(rl_pid)
    end)

    circuit_id = :crypto.strong_rand_bytes(16)
    %{circuit_id: circuit_id}
  end

  # --- record/1 ---

  describe "record/1" do
    test "records first abuse event at level 1", %{circuit_id: cid} do
      assert :ok = Escalation.record(cid)
      assert {:escalated, 3} = Escalation.status(cid)
    end

    test "escalates to level 2 (9x multiplier)", %{circuit_id: cid} do
      Escalation.record(cid)
      Escalation.record(cid)

      assert {:escalated, 9} = Escalation.status(cid)
    end

    test "escalates to level 3 (27x multiplier)", %{circuit_id: cid} do
      for _i <- 1..3 do
        Escalation.record(cid)
      end

      assert {:escalated, 27} = Escalation.status(cid)
    end

    test "escalates to level 4 (81x multiplier)", %{circuit_id: cid} do
      for _i <- 1..4 do
        Escalation.record(cid)
      end

      assert {:escalated, 81} = Escalation.status(cid)
    end

    test "caps at max level 4", %{circuit_id: cid} do
      for _i <- 1..10 do
        Escalation.record(cid)
      end

      assert {:escalated, 81} = Escalation.status(cid)
    end

    test "applies multiplier to RateLimiter", %{circuit_id: cid} do
      Escalation.record(cid)
      assert RateLimiter.get_multiplier(cid) == 3
    end

    test "escalating multiplier updates in RateLimiter", %{circuit_id: cid} do
      Escalation.record(cid)
      assert RateLimiter.get_multiplier(cid) == 3

      Escalation.record(cid)
      assert RateLimiter.get_multiplier(cid) == 9
    end

    test "different circuits escalate independently" do
      cid1 = :crypto.strong_rand_bytes(16)
      cid2 = :crypto.strong_rand_bytes(16)

      Escalation.record(cid1)
      Escalation.record(cid1)
      Escalation.record(cid2)

      assert {:escalated, 9} = Escalation.status(cid1)
      assert {:escalated, 3} = Escalation.status(cid2)
    end

    test "returns :ok" do
      cid = :crypto.strong_rand_bytes(16)
      assert :ok = Escalation.record(cid)
    end
  end

  # --- status/1 ---

  describe "status/1" do
    test "returns :ok for unknown circuit" do
      cid = :crypto.strong_rand_bytes(16)
      assert :ok = Escalation.status(cid)
    end

    test "returns {:escalated, multiplier} for escalated circuit", %{circuit_id: cid} do
      Escalation.record(cid)
      assert {:escalated, 3} = Escalation.status(cid)
    end

    test "returns :ok for expired escalation" do
      cid = :crypto.strong_rand_bytes(16)
      :ets.insert(Seer.Escalation, {cid, 2, System.monotonic_time(:second) - 10})

      assert :ok = Escalation.status(cid)
    end

    test "returns correct multiplier for each level", %{circuit_id: cid} do
      Escalation.record(cid)
      assert {:escalated, 3} = Escalation.status(cid)

      Escalation.record(cid)
      assert {:escalated, 9} = Escalation.status(cid)

      Escalation.record(cid)
      assert {:escalated, 27} = Escalation.status(cid)

      Escalation.record(cid)
      assert {:escalated, 81} = Escalation.status(cid)
    end
  end

  # --- banned?/1 ---

  describe "banned?/1" do
    test "returns false for unknown circuit" do
      cid = :crypto.strong_rand_bytes(16)
      refute Escalation.banned?(cid)
    end

    test "returns false for low escalation levels", %{circuit_id: cid} do
      Escalation.record(cid)
      refute Escalation.banned?(cid)

      Escalation.record(cid)
      refute Escalation.banned?(cid)

      Escalation.record(cid)
      refute Escalation.banned?(cid)
    end

    test "returns true at max level (level 4)", %{circuit_id: cid} do
      for _i <- 1..4 do
        Escalation.record(cid)
      end

      assert Escalation.banned?(cid)
    end

    test "returns true when exceeding max level", %{circuit_id: cid} do
      for _i <- 1..6 do
        Escalation.record(cid)
      end

      assert Escalation.banned?(cid)
    end

    test "returns false when escalation expired" do
      cid = :crypto.strong_rand_bytes(16)
      :ets.insert(Seer.Escalation, {cid, 4, System.monotonic_time(:second) - 10})

      refute Escalation.banned?(cid)
    end
  end

  # --- reset/1 ---

  describe "reset/1" do
    test "clears escalation state", %{circuit_id: cid} do
      for _i <- 1..3 do
        Escalation.record(cid)
      end

      assert {:escalated, 27} = Escalation.status(cid)

      Escalation.reset(cid)
      assert :ok = Escalation.status(cid)
    end

    test "also resets rate limiter for circuit", %{circuit_id: cid} do
      Escalation.record(cid)
      assert RateLimiter.get_multiplier(cid) == 3

      Escalation.reset(cid)
      assert RateLimiter.get_multiplier(cid) == 1
    end

    test "reset is idempotent" do
      cid = :crypto.strong_rand_bytes(16)
      assert :ok = Escalation.reset(cid)
      assert :ok = Escalation.reset(cid)
    end

    test "reset does not affect other circuits" do
      cid1 = :crypto.strong_rand_bytes(16)
      cid2 = :crypto.strong_rand_bytes(16)

      Escalation.record(cid1)
      Escalation.record(cid2)
      Escalation.record(cid2)

      Escalation.reset(cid1)

      assert :ok = Escalation.status(cid1)
      assert {:escalated, 9} = Escalation.status(cid2)
    end

    test "after reset, escalation starts fresh from level 1", %{circuit_id: cid} do
      for _i <- 1..4 do
        Escalation.record(cid)
      end

      assert Escalation.banned?(cid)

      Escalation.reset(cid)
      Escalation.record(cid)

      assert {:escalated, 3} = Escalation.status(cid)
      refute Escalation.banned?(cid)
    end
  end

  # --- escalation progression ---

  describe "escalation progression" do
    test "full escalation ladder: 3 -> 9 -> 27 -> 81", %{circuit_id: cid} do
      expected = [3, 9, 27, 81, 81, 81]

      for expected_mult <- expected do
        Escalation.record(cid)
        {:escalated, mult} = Escalation.status(cid)
        assert mult == expected_mult
      end
    end
  end
end
