defmodule OpenapiBench.ApiSmokeTest do
  @moduledoc """
  Proves the SUT is a real HTTP server serving the KV contract over a socket,
  before any generated code exists. This is the cluster-1 baseline: faithful
  CRUD round-trips, 404 on a missing key, and the bug flag dropping writes.
  """
  use ExUnit.Case, async: false

  alias OpenapiBench.HttpClient
  alias OpenapiBench.Server

  setup do
    {200, _} = HttpClient.request(:post, Server.base_url() <> "/__reset__", %{bug: false})
    :ok
  end

  test "PUT then GET round-trips the stored value" do
    base = Server.base_url()

    assert {200, %{"key" => 2, "value" => 42}} =
             HttpClient.request(:put, base <> "/kv/2", %{value: 42})

    assert {200, %{"key" => 2, "value" => 42}} =
             HttpClient.request(:get, base <> "/kv/2")
  end

  test "GET on an unset key is 404" do
    assert {404, %{"error" => "not_found"}} =
             HttpClient.request(:get, Server.base_url() <> "/kv/3")
  end

  test "a later PUT overwrites the value" do
    base = Server.base_url()
    HttpClient.request(:put, base <> "/kv/1", %{value: 7})
    HttpClient.request(:put, base <> "/kv/1", %{value: 8})

    assert {200, %{"value" => 8}} = HttpClient.request(:get, base <> "/kv/1")
  end

  test "with the bug flag set, PUT answers 200 but silently drops the write" do
    base = Server.base_url()
    {200, _} = HttpClient.request(:post, base <> "/__reset__", %{bug: true})

    assert {200, %{"key" => 0, "value" => 99}} =
             HttpClient.request(:put, base <> "/kv/0", %{value: 99})

    assert {404, %{"error" => "not_found"}} = HttpClient.request(:get, base <> "/kv/0")
  end
end
