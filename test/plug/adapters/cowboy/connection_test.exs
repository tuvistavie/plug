defmodule Plug.Adapters.Cowboy.ConnectionTest do
  use ExUnit.Case, async: true

  alias  Plug.Conn
  import Plug.Connection

  ## Cowboy setup for testing

  setup_all do
    dispatch = [{ :_, [ {:_, Plug.Adapters.Cowboy.Handler, __MODULE__ } ] }]
    env = [dispatch: :cowboy_router.compile(dispatch)]
    { :ok, _pid } = :cowboy.start_http(__MODULE__, 100, [port: 8001], [env: env])
    :ok
  end

  teardown_all do
    :ok = :cowboy.stop_listener(__MODULE__)
    :ok
  end

  def call(conn, []) do
    function = binary_to_atom Enum.first(conn.path_info) || "root"
    apply __MODULE__, function, [conn]
  rescue
    exception ->
      receive do
        { :plug_conn, :sent } ->
          :erlang.raise(:error, exception, :erlang.get_stacktrace)
      after
        0 ->
          send(conn, 500, exception.message <> "\n" <>
                          Exception.format_stacktrace(System.stacktrace))
      end
  end

  ## Tests

  def root(Conn[] = conn) do
    assert conn.method == "HEAD"
    assert conn.path_info == []
    assert conn.query_string == "foo=bar&baz=bat"
    conn
  end

  def build(Conn[] = conn) do
    assert { Plug.Adapters.Cowboy.Connection, _ } = conn.adapter
    assert conn.path_info == ["build", "foo", "bar"]
    assert conn.query_string == ""
    assert conn.scheme == :http
    assert conn.host == "127.0.0.1"
    assert conn.port == 8001
    assert conn.method == "GET"
    conn
  end

  test "builds a connection" do
    assert { 204, _, _ } = request :head, "/?foo=bar&baz=bat"
    assert { 204, _, _ } = request :get, "/build/foo/bar"
    assert { 204, _, _ } = request :get, "//build//foo//bar"
  end

  def headers(conn) do
    assert conn.req_headers["foo"] == "bar"
    assert conn.req_headers["baz"] == "bat"
    conn
  end

  test "stores request headers" do
    assert { 204, _, _ } = request :get, "/headers", [{ "foo", "bar" }, { "baz", "bat" }]
  end

  def send_200(conn) do
    assert conn.state == :unsent
    conn = send(conn, 200, "OK")
    assert conn.state == :sent
    conn
  end

  def send_500(conn) do
    conn
    |> delete_resp_header("cache-control")
    |> put_resp_header("x-sample", "value")
    |> send(500, "ERROR")
  end

  test "sends a response with status, headers and body" do
    assert { 200, headers, "OK" } = request :get, "/send_200"
    assert headers["cache-control"] == "max-age=0, private, must-revalidate"
    assert { 500, headers, "ERROR" } = request :get, "/send_500"
    assert headers["cache-control"] == nil
    assert headers["x-sample"] == "value"
  end

  test "sends skips body on head" do
    assert { 200, _, "" } = request :head, "/send_200"
  end

  def stream_req_body(conn) do
    { adapter, state } = conn.adapter
    expected = :binary.copy("abcdefghij", 100_000)
    assert { ^expected, state } = read_req_body({ :ok, "", state }, "", adapter)
    assert { :done, state } = adapter.stream_req_body(state, 100_000)
    conn.adapter({ adapter, state })
  end

  defp read_req_body({ :ok, buffer, state }, acc, adapter) do
    read_req_body(adapter.stream_req_body(state, 100_000), acc <> buffer, adapter)
  end

  defp read_req_body({ :done, state }, acc, _adapter) do
    { acc, state }
  end

  test "reads body" do
    body = :binary.copy("abcdefghij", 100_000)
    assert { 204, _, "" } = request :get, "/stream_req_body", [], body
    assert { 204, _, "" } = request :post, "/stream_req_body", [], body
  end

  def multipart(conn) do
    { :ok, conn } = Plug.Parsers.call(conn, parsers: [Plug.Parsers.MULTIPART], limit: 8_000_000)
    assert conn.params["name"] == "hello"

    assert Plug.Upload.File[] = file = conn.params["pic"]
    assert File.read!(file.path) == "hello\n\n"
    assert file.content_type == "text/plain"
    assert file.filename == "foo.txt"

    conn
  end

  test "parses multipart requests" do
    multipart = "------WebKitFormBoundaryw58EW1cEpjzydSCq\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nhello\r\n------WebKitFormBoundaryw58EW1cEpjzydSCq\r\nContent-Disposition: form-data; name=\"pic\"; filename=\"foo.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\n\n\r\n------WebKitFormBoundaryw58EW1cEpjzydSCq\r\nContent-Disposition: form-data; name=\"commit\"\r\n\r\nCreate User\r\n------WebKitFormBoundaryw58EW1cEpjzydSCq--\r\n"
    headers =
      [{ "Content-Type", "multipart/form-data; boundary=----WebKitFormBoundaryw58EW1cEpjzydSCq" },
       { "Content-Length", size(multipart) }]

    assert { 204, _, _ } = request :get, "/multipart", headers, multipart
    assert { 204, _, _ } = request :get, "/multipart?name=overriden", headers, multipart
  end

  ## Helpers

  defp request(verb, path, headers // [], body // "") do
    { :ok, status, headers, client } =
      :hackney.request(verb, "http://127.0.0.1:8001" <> path, headers, body, [])
    { :ok, body, _ } = :hackney.body(client)
    { status, headers, body }
  end
end
