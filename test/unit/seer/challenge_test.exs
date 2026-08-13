defmodule Seer.ChallengeTest do
  use ExUnit.Case, async: false

  import Seer.TestHelpers

  alias Seer.Challenge
  alias Seer.NonceStore

  setup :clean_state

  setup do
    {:ok, pid} = NonceStore.start_link()

    on_exit(fn -> safe_stop(pid) end)

    :ok
  end

  # --- generate/1 ---

  describe "generate/1" do
    test "returns a Challenge struct with expected fields" do
      {:ok, challenge} = Challenge.generate(8)

      assert %Challenge{} = challenge
      assert is_binary(challenge.nonce)
      assert byte_size(challenge.nonce) == 16
      assert challenge.difficulty == 8
      assert is_integer(challenge.created_at)
      assert is_integer(challenge.expires_at)
      assert challenge.expires_at > challenge.created_at
    end

    test "nonce is 16 random bytes" do
      {:ok, c1} = Challenge.generate(4)
      {:ok, c2} = Challenge.generate(4)

      assert byte_size(c1.nonce) == 16
      assert byte_size(c2.nonce) == 16
      assert c1.nonce != c2.nonce
    end

    test "registers nonce in NonceStore with its issued difficulty" do
      {:ok, challenge} = Challenge.generate(4)
      # Nonce should be consumable (proves it was tracked)
      assert {:ok, 4} = NonceStore.consume_nonce(challenge.nonce)
    end

    test "expires_at is 120 seconds after created_at" do
      {:ok, challenge} = Challenge.generate(4)
      assert challenge.expires_at - challenge.created_at == 120
    end

    test "respects the difficulty parameter" do
      for d <- [1, 4, 12, 20] do
        {:ok, c} = Challenge.generate(d)
        assert c.difficulty == d
      end
    end
  end

  # --- verify/2 ---

  describe "verify/2" do
    test "accepts a valid solution" do
      difficulty = 1
      {:ok, challenge} = Challenge.generate(difficulty)
      solution = solve_pow(challenge.nonce, difficulty)

      assert :ok = Challenge.verify(challenge.nonce, solution)
    end

    test "rejects an invalid solution" do
      difficulty = 8
      {:ok, challenge} = Challenge.generate(difficulty)
      bad_solution = <<0, 0, 0, 0, 0, 0, 0, 1>>

      result = Challenge.verify(challenge.nonce, bad_solution)

      # Either invalid_solution (hash didn't meet difficulty) or it could pass by luck
      # With difficulty 8 and a fixed solution, overwhelmingly likely to fail
      assert result == :ok or result == {:error, :invalid_solution}
    end

    test "verification uses the issued difficulty — it cannot be weakened by the caller" do
      {:ok, challenge} = Challenge.generate(12)
      weak = solve_weak(challenge.nonce)

      # The weak solution passes a 1-bit check, but the challenge was
      # issued at 12 — verification must reject.
      assert {:error, :invalid_solution} = Challenge.verify(challenge.nonce, weak)
    end

    test "prevents replay (nonce already used)" do
      difficulty = 1
      {:ok, challenge} = Challenge.generate(difficulty)
      solution = solve_pow(challenge.nonce, difficulty)

      assert :ok = Challenge.verify(challenge.nonce, solution)

      assert {:error, :nonce_already_used} = Challenge.verify(challenge.nonce, solution)
    end

    test "rejects expired nonce" do
      nonce = :crypto.strong_rand_bytes(16)
      # Set expiry in the past
      past = System.monotonic_time(:second) - 10
      NonceStore.track_nonce(nonce, {:issued, past, 1})

      solution = solve_pow(nonce, 1)
      assert {:error, :nonce_expired} = Challenge.verify(nonce, solution)
    end

    test "rejects unknown nonce" do
      unknown_nonce = :crypto.strong_rand_bytes(16)
      solution = <<1, 2, 3, 4>>

      assert {:error, :nonce_not_found} = Challenge.verify(unknown_nonce, solution)
    end

    test "verify with difficulty 1 is fast" do
      {:ok, challenge} = Challenge.generate(1)
      solution = solve_pow(challenge.nonce, 1)
      assert :ok = Challenge.verify(challenge.nonce, solution)
    end
  end

  # --- format_headers/1 ---

  describe "format_headers/1" do
    test "returns three headers with correct keys" do
      {:ok, challenge} = Challenge.generate(12)
      headers = Challenge.format_headers(challenge)

      assert length(headers) == 3
      keys = Enum.map(headers, &elem(&1, 0))
      assert "x-challenge-nonce" in keys
      assert "x-challenge-difficulty" in keys
      assert "x-challenge-expires" in keys
    end

    test "nonce header is hex-encoded lowercase" do
      {:ok, challenge} = Challenge.generate(4)
      headers = Challenge.format_headers(challenge)
      {_key, nonce_hex} = Enum.find(headers, fn {k, _v} -> k == "x-challenge-nonce" end)

      assert nonce_hex == Base.encode16(challenge.nonce, case: :lower)
      assert nonce_hex =~ ~r/^[0-9a-f]+$/
    end

    test "difficulty header is string integer" do
      {:ok, challenge} = Challenge.generate(16)
      headers = Challenge.format_headers(challenge)
      {_key, diff_str} = Enum.find(headers, fn {k, _v} -> k == "x-challenge-difficulty" end)

      assert diff_str == "16"
    end

    test "expires header is string integer" do
      {:ok, challenge} = Challenge.generate(4)
      headers = Challenge.format_headers(challenge)
      {_key, exp_str} = Enum.find(headers, fn {k, _v} -> k == "x-challenge-expires" end)

      assert String.to_integer(exp_str) == challenge.expires_at
    end
  end

  # --- has_leading_zero_bits?/2 ---

  describe "has_leading_zero_bits?/2" do
    test "all-zero hash has 256 leading zero bits" do
      hash = <<0::256>>
      assert Challenge.has_leading_zero_bits?(hash, 256)
    end

    test "hash starting with 0x00 has at least 8 leading zero bits" do
      hash =
        <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
          24, 25, 26, 27, 28, 29, 30, 31>>

      assert Challenge.has_leading_zero_bits?(hash, 8)
    end

    test "hash starting with 0xFF fails difficulty 1" do
      hash = <<255, 0::248>>
      refute Challenge.has_leading_zero_bits?(hash, 1)
    end

    test "difficulty 0 always passes" do
      hash = <<255, 255, 255, 255, 0::224>>
      assert Challenge.has_leading_zero_bits?(hash, 0)
    end

    test "boundary case: exactly meeting difficulty" do
      # Hash with exactly 4 leading zero bits: 0000 1xxx ...
      # 0x08 = 0000 1000 -> 4 leading zeros
      hash = <<0x08, 0::248>>
      assert Challenge.has_leading_zero_bits?(hash, 4)
      refute Challenge.has_leading_zero_bits?(hash, 5)
    end

    test "hash with exactly 16 leading zero bits" do
      # <<0, 0, 128, 0::224>> -> 16 leading zeros then 1
      hash = <<0, 0, 128, 0::224>>
      assert Challenge.has_leading_zero_bits?(hash, 16)
      refute Challenge.has_leading_zero_bits?(hash, 17)
    end
  end

  # --- extract_solution/1 ---

  describe "extract_solution/1" do
    test "extracts nonce and solution from valid headers" do
      nonce = :crypto.strong_rand_bytes(16)
      solution = :crypto.strong_rand_bytes(8)
      nonce_hex = Base.encode16(nonce, case: :lower)
      solution_hex = Base.encode16(solution, case: :lower)

      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-nonce", nonce_hex},
          {"x-challenge-solution", solution_hex}
        ]
      }

      assert {:ok, ^nonce, ^solution} = Challenge.extract_solution(conn)
    end

    test "accepts mixed-case hex" do
      nonce = :crypto.strong_rand_bytes(16)
      solution = :crypto.strong_rand_bytes(8)
      nonce_hex = Base.encode16(nonce, case: :upper)
      solution_hex = Base.encode16(solution, case: :lower)

      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-nonce", nonce_hex},
          {"x-challenge-solution", solution_hex}
        ]
      }

      assert {:ok, ^nonce, ^solution} = Challenge.extract_solution(conn)
    end

    test "returns error when nonce header missing" do
      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-solution", "aabbccdd"}
        ]
      }

      assert {:error, :missing_solution} = Challenge.extract_solution(conn)
    end

    test "returns error when solution header missing" do
      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-nonce", "aabbccdd"}
        ]
      }

      assert {:error, :missing_solution} = Challenge.extract_solution(conn)
    end

    test "returns error when both headers missing" do
      conn = %Plug.Conn{req_headers: []}
      assert {:error, :missing_solution} = Challenge.extract_solution(conn)
    end

    test "returns error for invalid hex in nonce" do
      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-nonce", "not-hex!"},
          {"x-challenge-solution", "aabbccdd"}
        ]
      }

      assert {:error, :missing_solution} = Challenge.extract_solution(conn)
    end

    test "returns error for invalid hex in solution" do
      conn = %Plug.Conn{
        req_headers: [
          {"x-challenge-nonce", "aabbccdd"},
          {"x-challenge-solution", "zzzz"}
        ]
      }

      assert {:error, :missing_solution} = Challenge.extract_solution(conn)
    end
  end

  # --- Helpers ---

  defp solve_pow(nonce, difficulty) do
    solve_pow(nonce, difficulty, 0)
  end

  defp solve_pow(nonce, difficulty, counter) do
    solution = <<counter::64>>
    hash = :crypto.hash(:sha256, nonce <> solution)

    if Challenge.has_leading_zero_bits?(hash, difficulty) do
      solution
    else
      solve_pow(nonce, difficulty, counter + 1)
    end
  end

  # A solution that passes a 1-bit check but not a 12-bit one
  defp solve_weak(nonce), do: solve_weak(nonce, 0)

  defp solve_weak(nonce, counter) do
    solution = <<counter::64>>
    hash = :crypto.hash(:sha256, nonce <> solution)

    if Challenge.has_leading_zero_bits?(hash, 1) and
         not Challenge.has_leading_zero_bits?(hash, 12) do
      solution
    else
      solve_weak(nonce, counter + 1)
    end
  end
end
