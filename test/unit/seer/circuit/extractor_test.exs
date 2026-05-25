defmodule Seer.Circuit.ExtractorTest do
  use ExUnit.Case, async: true

  alias Seer.Circuit.Extractor

  defp mock_conn(remote_ip, headers, peer_data \\ nil) do
    adapter_state =
      if peer_data do
        %{peer_data: peer_data}
      else
        %{peer_data: %{address: remote_ip, port: 0}}
      end

    %Plug.Conn{
      remote_ip: remote_ip,
      req_headers: headers,
      adapter: {Seer.Test.MockAdapter, adapter_state}
    }
  end

  # --- extract/1 ---

  # Header-based extraction is an opt-in feature (disabled by default to
  # prevent X-Tor-Circuit spoofing from loopback Tor hidden services).
  # These tests enable the flag explicitly to cover the opt-in path.
  setup context do
    if context[:trust_header] do
      Application.put_env(:seer, :trust_circuit_header, true)
      on_exit(fn -> Application.delete_env(:seer, :trust_circuit_header) end)
    end

    :ok
  end

  describe "extract/1" do
    @tag :trust_header
    test "extracts circuit ID from X-Tor-Circuit header on localhost (IPv4)" do
      conn = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", "abc123"}])

      assert {:ok, hash} = Extractor.extract(conn)
      assert hash == :crypto.hash(:sha256, "abc123")
      assert byte_size(hash) == 32
    end

    @tag :trust_header
    test "extracts circuit ID from X-Tor-Circuit header on localhost (IPv6)" do
      conn = mock_conn({0, 0, 0, 0, 0, 0, 0, 1}, [{"x-tor-circuit", "circuit-xyz"}])

      assert {:ok, hash} = Extractor.extract(conn)
      assert hash == :crypto.hash(:sha256, "circuit-xyz")
    end

    test "by default, ignores X-Tor-Circuit header even from localhost (prevents spoofing)" do
      conn =
        mock_conn(
          {127, 0, 0, 1},
          [{"x-tor-circuit", "spoofed"}],
          %{address: {127, 0, 0, 1}, port: 54_321}
        )

      assert {:ok, hash} = Extractor.extract(conn)
      # Should fall back to peer data: the header is not trusted by default.
      refute hash == :crypto.hash(:sha256, "spoofed")
      assert hash == :crypto.hash(:sha256, "127.0.0.1:54321")
    end

    test "ignores X-Tor-Circuit header from non-localhost" do
      conn =
        mock_conn(
          {10, 0, 0, 5},
          [{"x-tor-circuit", "spoofed"}],
          %{address: {10, 0, 0, 5}, port: 12_345}
        )

      assert {:ok, hash} = Extractor.extract(conn)
      # Should NOT use the header; should use peer address
      refute hash == :crypto.hash(:sha256, "spoofed")
      assert hash == :crypto.hash(:sha256, "10.0.0.5:12345")
    end

    test "falls back to peer data when no header on localhost" do
      conn =
        mock_conn(
          {127, 0, 0, 1},
          [],
          %{address: {127, 0, 0, 1}, port: 54_321}
        )

      assert {:ok, hash} = Extractor.extract(conn)
      assert hash == :crypto.hash(:sha256, "127.0.0.1:54321")
    end

    test "uses peer data for remote IP connections" do
      conn =
        mock_conn(
          {192, 168, 1, 100},
          [],
          %{address: {192, 168, 1, 100}, port: 9999}
        )

      assert {:ok, hash} = Extractor.extract(conn)
      assert hash == :crypto.hash(:sha256, "192.168.1.100:9999")
    end

    @tag :trust_header
    test "hashes are deterministic for same input" do
      conn1 = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", "same-circuit"}])
      conn2 = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", "same-circuit"}])

      assert {:ok, h1} = Extractor.extract(conn1)
      assert {:ok, h2} = Extractor.extract(conn2)
      assert h1 == h2
    end

    @tag :trust_header
    test "different circuit IDs produce different hashes" do
      conn1 = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", "circuit-a"}])
      conn2 = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", "circuit-b"}])

      assert {:ok, h1} = Extractor.extract(conn1)
      assert {:ok, h2} = Extractor.extract(conn2)
      refute h1 == h2
    end

    test "rejects oversized X-Tor-Circuit header (>256 bytes)" do
      long_value = String.duplicate("x", 257)

      conn =
        mock_conn(
          {127, 0, 0, 1},
          [{"x-tor-circuit", long_value}],
          %{address: {127, 0, 0, 1}, port: 11_111}
        )

      assert {:ok, hash} = Extractor.extract(conn)
      # Should have fallen back to peer data, not used the oversized header
      refute hash == :crypto.hash(:sha256, long_value)
      assert hash == :crypto.hash(:sha256, "127.0.0.1:11111")
    end

    @tag :trust_header
    test "accepts X-Tor-Circuit header at exactly 256 bytes" do
      value_256 = String.duplicate("a", 256)
      conn = mock_conn({127, 0, 0, 1}, [{"x-tor-circuit", value_256}])

      assert {:ok, hash} = Extractor.extract(conn)
      assert hash == :crypto.hash(:sha256, value_256)
    end

    # Peer data always contains address/port per Plug spec,
    # so no error case exists; dialyzer confirms this.
  end

  # --- test_circuit_id/0 ---

  describe "test_circuit_id/0" do
    test "returns a 32-byte SHA256 hash" do
      id = Extractor.test_circuit_id()
      assert byte_size(id) == 32
    end

    test "is deterministic" do
      assert Extractor.test_circuit_id() == Extractor.test_circuit_id()
    end

    test "equals SHA256 of 'test-circuit'" do
      expected = :crypto.hash(:sha256, "test-circuit")
      assert Extractor.test_circuit_id() == expected
    end
  end
end
