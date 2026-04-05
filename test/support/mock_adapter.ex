defmodule Seer.Test.MockAdapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(_state, _status, _headers, _body), do: {:ok, nil, %{}}

  @impl Plug.Conn.Adapter
  def send_file(_state, _status, _headers, _path, _offset, _length), do: {:ok, nil, %{}}

  @impl Plug.Conn.Adapter
  def send_chunked(_state, _status, _headers), do: {:ok, nil, %{}}

  @impl Plug.Conn.Adapter
  def chunk(_state, _body), do: {:ok, nil, %{}}

  @impl Plug.Conn.Adapter
  def read_req_body(_state, _opts), do: {:ok, "", %{}}

  @impl Plug.Conn.Adapter
  def inform(_state, _status, _headers), do: {:ok, %{}}

  @impl Plug.Conn.Adapter
  def upgrade(_state, _protocol, _opts), do: {:ok, %{}}

  @impl Plug.Conn.Adapter
  def push(_state, _path, _headers), do: {:ok, %{}}

  @impl Plug.Conn.Adapter
  def get_peer_data(state), do: state.peer_data

  @impl Plug.Conn.Adapter
  def get_http_protocol(_state), do: :"HTTP/1.1"

  @impl Plug.Conn.Adapter
  def get_ssl_data(_state), do: %{}

  @impl Plug.Conn.Adapter
  def get_sock_data(_state), do: %{}
end
