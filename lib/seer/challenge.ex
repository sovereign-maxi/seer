defmodule Seer.Challenge do
  @moduledoc """
  Hashcash-style Proof-of-Work challenge generation and verification.

  Generates challenges with a random nonce and configurable difficulty.
  Verification checks SHA256(nonce <> solution) for leading zero bits
  using integer threshold comparison (constant-time, no early exit).
  """

  alias Seer.NonceStore

  defstruct [:nonce, :difficulty, :created_at, :expires_at]

  @type t :: %__MODULE__{
          nonce: binary(),
          difficulty: non_neg_integer(),
          created_at: integer(),
          expires_at: integer()
        }

  @ttl_seconds 120
  @max_header_hex_len 256

  @doc """
  Generates a new PoW challenge and registers the nonce.

  Returns `{:ok, challenge}` or `{:error, :unavailable}` if the
  NonceStore is not running.
  """
  @spec generate(non_neg_integer()) :: {:ok, t()} | {:error, :unavailable}
  def generate(difficulty) do
    nonce = :crypto.strong_rand_bytes(16)
    now = System.monotonic_time(:second)
    expires_at = now + @ttl_seconds

    case NonceStore.track_nonce(nonce, {:issued, expires_at}) do
      :ok ->
        {:ok,
         %__MODULE__{
           nonce: nonce,
           difficulty: difficulty,
           created_at: now,
           expires_at: expires_at
         }}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc """
  Verifies a PoW solution against a nonce and difficulty.

  Atomically consumes the nonce to prevent replay. The nonce is
  consumed BEFORE checking the solution — an invalid solution burns
  the nonce. This is intentional: it prevents brute-force grinding
  against a single challenge. Clients must request a new challenge
  on failure.
  """
  @spec verify(binary(), binary(), non_neg_integer()) ::
          :ok
          | {:error, :invalid_solution | :nonce_expired | :nonce_already_used | :nonce_not_found}
  def verify(nonce, solution, difficulty) do
    with :ok <- NonceStore.consume_nonce(nonce) do
      hash = :crypto.hash(:sha256, nonce <> solution)

      if has_leading_zero_bits?(hash, difficulty) do
        :ok
      else
        {:error, :invalid_solution}
      end
    end
  end

  @doc "Returns HTTP headers for a 402 PoW challenge response."
  @spec format_headers(t()) :: [{String.t(), String.t()}]
  def format_headers(%__MODULE__{} = challenge) do
    [
      {"x-challenge-nonce", Base.encode16(challenge.nonce, case: :lower)},
      {"x-challenge-difficulty", Integer.to_string(challenge.difficulty)},
      {"x-challenge-expires", Integer.to_string(challenge.expires_at)}
    ]
  end

  @doc "Extracts nonce and solution from request headers."
  @spec extract_solution(Plug.Conn.t()) :: {:ok, binary(), binary()} | {:error, :missing_solution}
  def extract_solution(conn) do
    with [nonce_hex] when byte_size(nonce_hex) <= @max_header_hex_len <-
           Plug.Conn.get_req_header(conn, "x-challenge-nonce"),
         [solution_hex] when byte_size(solution_hex) <= @max_header_hex_len <-
           Plug.Conn.get_req_header(conn, "x-challenge-solution"),
         {:ok, nonce} <- Base.decode16(nonce_hex, case: :mixed),
         {:ok, solution} <- Base.decode16(solution_hex, case: :mixed) do
      {:ok, nonce, solution}
    else
      _error -> {:error, :missing_solution}
    end
  end

  @doc """
  Checks if a hash has at least `difficulty` leading zero bits.

  Uses integer bit-shift for exact arithmetic (no floating-point
  precision loss at high bit widths) and constant-time comparison.
  """
  @spec has_leading_zero_bits?(binary(), non_neg_integer()) :: boolean()
  def has_leading_zero_bits?(hash, difficulty) when is_binary(hash) and difficulty >= 0 do
    bits = bit_size(hash)

    if difficulty > bits do
      false
    else
      threshold = Bitwise.bsl(1, bits - difficulty)
      :binary.decode_unsigned(hash) < threshold
    end
  end
end
