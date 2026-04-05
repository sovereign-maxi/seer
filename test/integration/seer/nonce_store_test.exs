defmodule Seer.NonceStoreTest do
  use ExUnit.Case, async: false

  import Seer.TestHelpers

  alias Seer.NonceStore

  setup :clean_state

  setup do
    {:ok, pid} = NonceStore.start_link()

    on_exit(fn -> safe_stop(pid) end)

    :ok
  end

  # --- track_nonce/2 ---

  describe "track_nonce/2" do
    test "stores a nonce with value" do
      nonce = :crypto.strong_rand_bytes(16)
      expires = System.monotonic_time(:second) + 120

      assert :ok = NonceStore.track_nonce(nonce, {:issued, expires})
      assert [{^nonce, {:issued, ^expires}}] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "overwrites existing nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      expires1 = System.monotonic_time(:second) + 60
      expires2 = System.monotonic_time(:second) + 120

      NonceStore.track_nonce(nonce, {:issued, expires1})
      NonceStore.track_nonce(nonce, {:issued, expires2})

      assert [{^nonce, {:issued, ^expires2}}] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "can store multiple different nonces" do
      nonces =
        for _i <- 1..10 do
          nonce = :crypto.strong_rand_bytes(16)
          expires = System.monotonic_time(:second) + 120
          NonceStore.track_nonce(nonce, {:issued, expires})
          nonce
        end

      for nonce <- nonces do
        assert [{^nonce, _value}] = :ets.lookup(NonceStore.table_name(), nonce)
      end
    end
  end

  # --- consume_nonce/1 ---

  describe "consume_nonce/1" do
    test "consumes a valid issued nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      expires = System.monotonic_time(:second) + 120
      NonceStore.track_nonce(nonce, {:issued, expires})

      assert :ok = NonceStore.consume_nonce(nonce)
      assert [{^nonce, {:used, _ts}}] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "returns error for expired nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      past = System.monotonic_time(:second) - 10
      NonceStore.track_nonce(nonce, {:issued, past})

      assert {:error, :nonce_expired} = NonceStore.consume_nonce(nonce)
      assert [] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "returns error for already used nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      expires = System.monotonic_time(:second) + 120
      NonceStore.track_nonce(nonce, {:issued, expires})

      assert :ok = NonceStore.consume_nonce(nonce)
      assert {:error, :nonce_already_used} = NonceStore.consume_nonce(nonce)
    end

    test "returns error for unknown nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      assert {:error, :nonce_not_found} = NonceStore.consume_nonce(nonce)
    end

    test "consuming marks the nonce as used with timestamp" do
      nonce = :crypto.strong_rand_bytes(16)
      expires = System.monotonic_time(:second) + 120
      NonceStore.track_nonce(nonce, {:issued, expires})

      before_consume = System.monotonic_time(:second)
      :ok = NonceStore.consume_nonce(nonce)

      [{^nonce, {:used, used_at}}] = :ets.lookup(NonceStore.table_name(), nonce)
      assert used_at >= before_consume
    end

    test "boundary: nonce exactly at expiry time is still valid" do
      nonce = :crypto.strong_rand_bytes(16)
      now = System.monotonic_time(:second)
      NonceStore.track_nonce(nonce, {:issued, now})

      assert :ok = NonceStore.consume_nonce(nonce)
    end
  end

  # --- cleanup/0 ---

  describe "cleanup/0" do
    test "removes expired issued nonces" do
      nonce_expired = :crypto.strong_rand_bytes(16)
      nonce_valid = :crypto.strong_rand_bytes(16)

      past = System.monotonic_time(:second) - 10
      future = System.monotonic_time(:second) + 120

      NonceStore.track_nonce(nonce_expired, {:issued, past})
      NonceStore.track_nonce(nonce_valid, {:issued, future})

      NonceStore.cleanup()

      assert [] = :ets.lookup(NonceStore.table_name(), nonce_expired)
      assert [{^nonce_valid, _value}] = :ets.lookup(NonceStore.table_name(), nonce_valid)
    end

    test "removes old used nonces (>300s)" do
      nonce = :crypto.strong_rand_bytes(16)
      old_used_at = System.monotonic_time(:second) - 301
      NonceStore.track_nonce(nonce, {:used, old_used_at})

      NonceStore.cleanup()

      assert [] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "keeps recently used nonces" do
      nonce = :crypto.strong_rand_bytes(16)
      recent_used_at = System.monotonic_time(:second)
      NonceStore.track_nonce(nonce, {:used, recent_used_at})

      NonceStore.cleanup()

      assert [{^nonce, _value}] = :ets.lookup(NonceStore.table_name(), nonce)
    end

    test "cleanup is idempotent on empty table" do
      NonceStore.clear()
      assert :ok = NonceStore.cleanup()
    end
  end

  # --- clear/0 ---

  describe "clear/0" do
    test "removes all entries" do
      for _i <- 1..5 do
        nonce = :crypto.strong_rand_bytes(16)
        expires = System.monotonic_time(:second) + 120
        NonceStore.track_nonce(nonce, {:issued, expires})
      end

      assert :ets.info(NonceStore.table_name(), :size) == 5
      assert :ok = NonceStore.clear()
      assert :ets.info(NonceStore.table_name(), :size) == 0
    end

    test "clear is idempotent" do
      assert :ok = NonceStore.clear()
      assert :ok = NonceStore.clear()
    end
  end

  # --- table_name/0 ---

  describe "table_name/0" do
    test "returns Seer.NonceStore" do
      assert NonceStore.table_name() == Seer.NonceStore
    end
  end

  # --- GenServer lifecycle ---

  describe "GenServer lifecycle" do
    test "handles cleanup message without crashing" do
      pid = Process.whereis(NonceStore)
      send(pid, :cleanup)

      await_condition(fn -> Process.alive?(pid) end)
    end

    test "handles unknown messages without crashing" do
      pid = Process.whereis(NonceStore)
      send(pid, :unknown_message)

      await_condition(fn -> Process.alive?(pid) end)
    end
  end
end
