defmodule StoreEtsTest do
  use ExUnit.Case
  doctest Cache.Store.StoreEts

  alias Cache.Store.StoreEts

  test "create a new ets store" do
    store = StoreEts.init(:cache_table)

    assert store == :cache_table
    StoreEts.delete_store(store)
  end

  test "add a new value to the store and retrieve it" do
    store = StoreEts.init(:cache_table)

    StoreEts.store(store, :my_key, "value")

    assert {:ok, "value"} == StoreEts.get(store, :my_key)

    StoreEts.delete_store(store)
  end

  test "update a key in the store and retrieve it" do
    store = StoreEts.init(:cache_table)

    StoreEts.store(store, :my_key, "value")
    assert {:ok, "value"} == StoreEts.get(store, :my_key)

    StoreEts.store(store, :my_key, "new value")
    assert {:ok, "new value"} == StoreEts.get(store, :my_key)

    StoreEts.delete_store(store)
  end

  test "should return error when trying to get a key that don't exists" do
    store = StoreEts.init(:cache_table)

    assert {:error, :not_found} == StoreEts.get(store, :my_key)

    StoreEts.delete_store(store)
  end
end
