defmodule CloakedReq do
  @moduledoc """
  Req adapter powered by Rust `wreq`.

  - `attach/2` — set adapter and merge options
  - `impersonate/2` — set browser profile
  """

  alias CloakedReq.AdapterError
  alias CloakedReq.CookieJar
  alias CloakedReq.Error
  alias CloakedReq.Native
  alias CloakedReq.Request
  alias CloakedReq.Response

  @custom_req_options [:cookie_jar, :impersonate, :insecure_skip_verify, :local_address, :max_body_size, :pool_group]

  @doc """
  Attaches `CloakedReq` adapter behavior to an existing `Req.Request`.

  Supported adapter-relevant options:

  - `:cookie_jar` - `%CloakedReq.CookieJar{}` for automatic cookie persistence
  - `:connect_options` - Req transport options for `:timeout`, `:proxy`, and `:proxy_headers`
  - `:impersonate` - profile atom (e.g. `:chrome_136`, `:"safari_17.4.1"`)
  - `:insecure_skip_verify` - boolean
  - `:local_address` - outbound source IP as string, IPv4 tuple, or IPv6 tuple
  - `:max_body_size` - positive integer or `:unlimited` (default: 10 MB); caps
    both the request body (rejected before sending if larger) and the response
    body (truncated to an error once it exceeds the limit)
  - `:pool_group` - opaque token (binary or atom, default `nil`) scoping the
    connection pool to a logical identity; pair with `drop_pool_group/1` to reset
    a single scope on demand. Use a low-cardinality, stable identity (e.g. a
    worker name): a value that varies per request defeats connection reuse and,
    once the 128-entry client cache fills, evicts other groups' pooled
    connections

  ## Examples

      iex> req = Req.new(url: "https://example.com") |> CloakedReq.attach(impersonate: :chrome_136)
      iex> is_function(req.adapter, 1)
      true
      iex> Req.Request.get_option(req, :impersonate)
      :chrome_136
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) when is_list(options) do
    request
    |> register_options()
    |> Req.Request.merge_options(options)
    |> put_adapter()
  end

  @doc """
  Sets the impersonation profile and configures the `CloakedReq` Req adapter.

  ## Examples

      iex> req = Req.new(url: "https://example.com") |> CloakedReq.impersonate(:chrome_136)
      iex> Req.Request.get_option(req, :impersonate)
      :chrome_136
      iex> is_function(req.adapter, 1)
      true
  """
  @spec impersonate(Req.Request.t(), atom()) :: Req.Request.t()
  def impersonate(%Req.Request{} = request, profile) do
    request
    |> register_options()
    |> Req.Request.put_option(:impersonate, profile)
    |> put_adapter()
  end

  @doc """
  Drops every pooled connection scoped to `group`.

  Evicts the cached client for the given `:pool_group` so the next request in
  that group dials a fresh connection. Use this when the upstream identity behind
  a fixed proxy has rotated and the pooled keep-alive connections would otherwise
  keep reusing the previous identity.

  In-flight requests are not aborted; each holds its own client until it finishes.
  The effect is that subsequent requests in this group start from an empty pool.

  `group` is a binary or atom matching the `:pool_group` request option. `nil`
  and any other type raise `ArgumentError`; there is no scoped drop for the
  default (unscoped) pool — use `flush_pool/0` to reset it.

  Returns `:ok`.

  ## Examples

      req =
        Req.new(url: "https://example.com")
        |> CloakedReq.attach(impersonate: :chrome_136, pool_group: "worker_3")

      # ... after the upstream identity rotates:
      CloakedReq.drop_pool_group("worker_3")
  """
  @spec drop_pool_group(binary() | atom()) :: :ok
  def drop_pool_group(group) when is_binary(group) do
    Native.drop_pool_group(group)
  end

  def drop_pool_group(group) when is_atom(group) and not is_nil(group) do
    group |> Atom.to_string() |> Native.drop_pool_group()
  end

  def drop_pool_group(other) do
    raise ArgumentError,
          "drop_pool_group/1 expects a non-nil binary or atom matching a :pool_group, got: #{inspect(other)}"
  end

  @doc """
  Flushes the entire client cache, dropping all pooled connections.

  The global counterpart to `drop_pool_group/1`: every cached client is evicted
  and all idle pooled connections close, so the next request anywhere builds a
  fresh client. In-flight requests are not aborted. For multi-group callers,
  prefer `drop_pool_group/1` so resetting one group does not disturb another
  group's pooled connections.

  Returns `:ok`.
  """
  @spec flush_pool() :: :ok
  def flush_pool do
    Native.flush_pool()
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    jar = Req.Request.get_option(request, :cookie_jar, nil)

    with :ok <- validate_cookie_jar(jar),
         jar_ref = if(jar, do: jar.ref),
         {:ok, {payload, body}} <- Request.to_native_payload(request),
         {:ok, response_meta, response_body} <- Native.perform_request(payload, body, jar_ref),
         {:ok, req_response} <- Response.from_native(response_meta, response_body) do
      {request, req_response}
    else
      {:error, %Error{} = error} ->
        {request, AdapterError.exception(error)}
    end
  end

  @spec validate_cookie_jar(nil | CookieJar.t()) :: :ok | {:error, Error.t()}
  defp validate_cookie_jar(nil), do: :ok
  defp validate_cookie_jar(%CookieJar{}), do: :ok

  defp validate_cookie_jar(_value) do
    {:error, Error.new(:invalid_request, "cookie_jar must be a %CloakedReq.CookieJar{}")}
  end

  @spec register_options(Req.Request.t()) :: Req.Request.t()
  defp register_options(%Req.Request{} = request) do
    Req.Request.register_options(request, @custom_req_options)
  end

  @spec put_adapter(Req.Request.t()) :: Req.Request.t()
  defp put_adapter(%Req.Request{} = request) do
    %{request | adapter: &run/1}
  end
end
