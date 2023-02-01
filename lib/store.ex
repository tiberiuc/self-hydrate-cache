defmodule Cache.Store do
  @moduledoc """
  Define a behaviour for different storage implementation for cache

  Init is used to initialize the storage and must return the store configuration
  that will be passed as first argument to all the other functions

  `store` - set a value for a key in the store

  `get` - get the value for a key from the store

  `delete` - delete the value for the key from the store

  `delete_store` - delete all the data associated with the store and free memory
  """

  @callback init(any()) :: any()
  @callback store(any(), any(), any()) :: nil
  @callback get(any(), any()) :: {:ok, any()} | {:error, :not_found}
  @callback delete(any(), any()) :: nil
  @callback delete_store(any()) :: nil
end
