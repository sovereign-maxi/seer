defmodule Seer.Circuit.Extractor do
  @moduledoc """
  Extracts a hashed Tor circuit identifier from a connection.

  Always derives the circuit ID from the peer `{ip, port}` tuple. Tor
  routes every external circuit to the local HTTP listener via loopback,
  so the raw `conn.remote_ip` is always `127.0.0.1` from the application's
  point of view — but the ephemeral source port allocated by Tor differs
  per circuit and is therefore a reasonable per-circuit surrogate.

  ## Why not trust `X-Tor-Circuit`?

  An earlier design read the `X-Tor-Circuit` HTTP header when the peer
  was loopback, on the theory that a trusted local proxy would inject it.
  This was unsafe in practice: because every Tor request arrives on
  loopback, the header is attacker-controlled, and rotating the header
  value per request trivially defeats the per-circuit rate limiter.

  If a deployment wants header-based extraction (e.g., a custom sidecar
  that reads Tor's control port and injects a signed circuit tag), set
  `config :seer, :trust_circuit_header, true` — explicit opt-in only.
  """

  @doc """
  Extracts a circuit ID hash from a Plug connection.

  Returns `{:ok, hash}`. Always succeeds — falls back to peer address.
  """
  @spec extract(Plug.Conn.t()) :: {:ok, binary()}
  def extract(conn) do
    case maybe_extract_from_header(conn) do
      {:ok, raw_id} -> {:ok, hash(raw_id)}
      :skip -> extract_from_peer(conn)
    end
  end

  @doc "Returns a deterministic test circuit ID hash."
  @spec test_circuit_id() :: binary()
  def test_circuit_id do
    :crypto.hash(:sha256, "test-circuit")
  end

  # --- Private ---

  # Header-based extraction is OFF by default. Enable only if you have a
  # trusted local injector — raw external requests over Tor will arrive
  # on loopback and could otherwise spoof the header freely.
  defp maybe_extract_from_header(conn) do
    if Application.get_env(:seer, :trust_circuit_header, false) and localhost?(conn) do
      case Plug.Conn.get_req_header(conn, "x-tor-circuit") do
        [value] when byte_size(value) <= 256 -> {:ok, value}
        _other -> :skip
      end
    else
      :skip
    end
  end

  defp extract_from_peer(conn) do
    %{address: address, port: port} = Plug.Conn.get_peer_data(conn)
    addr_str = address |> :inet.ntoa() |> to_string()

    # Use bracket notation for IPv6 to prevent ambiguity with port separator.
    # IPv4: "127.0.0.1:8080", IPv6: "[::1]:8080"
    raw_id =
      if tuple_size(address) == 8 do
        "[#{addr_str}]:#{port}"
      else
        "#{addr_str}:#{port}"
      end

    {:ok, hash(raw_id)}
  end

  defp localhost?(conn) do
    conn.remote_ip == {127, 0, 0, 1} or conn.remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  defp hash(raw_id) do
    :crypto.hash(:sha256, raw_id)
  end
end
