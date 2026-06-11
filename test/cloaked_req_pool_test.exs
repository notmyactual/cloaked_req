defmodule CloakedReq.PoolTest do
  @moduledoc """
  Verifies the caller-facing connection-pool controls: dropping a scoped pool
  group and flushing the whole client cache. Both evict cached clients so the
  next request in the affected scope dials a fresh connection.
  """

  use ExUnit.Case, async: true

  alias CloakedReq.Native

  test "flush_pool/0 returns :ok" do
    assert CloakedReq.flush_pool() == :ok
  end

  test "drop_pool_group/1 accepts a binary group" do
    assert CloakedReq.drop_pool_group("worker_1") == :ok
  end

  test "drop_pool_group/1 accepts an atom group" do
    assert CloakedReq.drop_pool_group(:worker_1) == :ok
  end

  test "drop_pool_group/1 raises ArgumentError for nil" do
    assert_raise ArgumentError, ~r/non-nil binary or atom/, fn ->
      CloakedReq.drop_pool_group(nil)
    end
  end

  test "drop_pool_group/1 raises ArgumentError for a non-binary/non-atom group" do
    assert_raise ArgumentError, ~r/non-nil binary or atom/, fn ->
      CloakedReq.drop_pool_group(123)
    end
  end

  test "Native.flush_pool/0 returns :ok" do
    assert Native.flush_pool() == :ok
  end

  test "Native.drop_pool_group/1 returns :ok for a binary group" do
    assert Native.drop_pool_group("worker_1") == :ok
  end
end
