defmodule Cache.Store.StoreEts do
  @moduledoc """
    Implement a store for the Cache that use ets internal

    `init` - always get the name of the table for the ets used to store values

    Example

    `table_name = StoreEts.init(:my_custom_table)`
  """
  @behaviour Cache.Store

  @impl true
  @spec init(atom) :: atom
  def init(table) do
    :ets.new(table, [:set, :protected, :named_table])
    table
  end

  @impl true
  @spec store(atom | :ets.tid(), any, any) :: nil
  def store(table, key, value) do
    :ets.insert(table, {key, value})
    nil
  end

  @impl true
  @spec get(atom | :ets.tid(), any) :: {:ok, any()} | {:error, :not_found}
  def get(table, key) do
    with [{_, value} | _] <- :ets.lookup(table, key) do
      {:ok, value}
    else
      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  @spec delete(atom | :ets.tid(), any) :: nil
  def delete(table, key) do
    :ets.delete(table, key)
    nil
  end

  @impl true
  @spec delete_store(atom | :ets.tid()) :: nil
  def delete_store(table) do
    :ets.delete(table)
    nil
  end
end
