defmodule Cache do
  @moduledoc """
  A self hydrating cache with custom storage support

  The cache allow to register keys and function where each function will 
  compute the cache value for the corresponding key.

  Also each key have a ttl - time to live - which define the time after
  the key will expire if the compute function constantly fail.

  Compute functions will auto refresh cache value on an refresh interval

  When getting a value from the cache if there is no value but a compute function
  is already running the function will wait a timeout interval for the compute
  function to finish

  Usage

  ```
  Cache.start_link()

  Cache.register_function(fn -> {:ok, 1} end, :my_key, 100_000, 1000)

  Cache.get(:my_key, 500)
  ```

  By default Cache use StoreEts storage, which use ets to store values

  Example how to use different storage

  `Cache.start_link(store_module: CustomStore, store_args: [:table_name])`

  For more info how to define a new Store please see Cache.Store

  For more informations how to configure StoreEts please see Cache.Store.StoreEts
  """
  use GenServer

  @type result ::
          {:ok, any()}
          | {:error, :timeout}
          | {:error, :not_registered}

  def start_link(opts \\ [store_module: Cache.Store.StoreEts, store_args: [:cache_storage]]) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    store_module =
      opts
      |> Keyword.get(:store_module)

    args =
      opts
      |> Keyword.get(:store_args)

    store = apply(store_module, :init, args)

    {:ok, workers_supervisor} = Task.Supervisor.start_link()

    initial_state = %{
      store: %{
        store_module: store_module,
        store: store
      },
      workers_supervisor: workers_supervisor,
      keys: %{}
    }

    {:ok, initial_state}
  end

  @doc ~s"""
  Registers a function that will be computed periodically to update the cache.
  Arguments:
    - `fun`: a 0-arity function that computes the value and returns either
      `{:ok, value}` or `{:error, reason}`.
    - `key`: associated with the function and is used to retrieve the stored
    value.
    - `ttl` ("time to live"): how long (in milliseconds) the value is stored
      before it is discarded if the value is not refreshed.
    - `refresh_interval`: how often (in milliseconds) the function is
      recomputed and the new value stored. `refresh_interval` must be strictly
      smaller than `ttl`. After the value is refreshed, the `ttl` counter is
      restarted.
  The value is stored only if `{:ok, value}` is returned by `fun`. If `{:error,
  reason}` is returned, the value is not stored and `fun` must be retried on
  the next run.
  """
  @spec register_function(
          fun :: (() -> {:ok, any()} | {:error, any()}),
          key :: any,
          ttl :: non_neg_integer(),
          refresh_interval :: non_neg_integer()
        ) :: :ok | {:error, :already_registered}
  def register_function(fun, key, ttl, refresh_interval)
      when is_function(fun, 0) and is_integer(ttl) and ttl > 0 and
             is_integer(refresh_interval) and
             refresh_interval < ttl do
    GenServer.call(__MODULE__, {:register_function, fun, key, ttl, refresh_interval})
  end

  @doc ~s"""
  Get the value associated with `key`.
  Details:
    - If the value for `key` is stored in the cache, the value is returned
      immediately.
    - If a recomputation of the function is in progress, the last stored value
      is returned.
    - If the value for `key` is not stored in the cache but a computation of
      the function associated with this `key` is in progress, wait up to
      `timeout` milliseconds. If the value is computed within this interval,
      the value is returned. If the computation does not finish in this
      interval, `{:error, :timeout}` is returned.
    - If `key` is not associated with any function, return `{:error,
      :not_registered}`
  """
  @spec get(any(), non_neg_integer(), Keyword.t()) :: result
  def get(key, timeout \\ 30_000, _opts \\ []) when is_integer(timeout) and timeout > 0 do
    GenServer.call(__MODULE__, {:get, key, timeout})
  end

  @impl true
  def handle_call({:register_function, fun, key, ttl, refresh_interval}, _from, state) do
    {result, new_state} =
      with keys <- state.keys,
           false <- Map.has_key?(keys, key) do
        key_entry = %{
          worker: fun,
          ttl: ttl,
          refresh_interval: refresh_interval,
          invalidator: nil,
          worker_task: nil
        }

        new_keys = keys |> Map.put(key, key_entry)

        new_state = %{state | keys: new_keys}
        start_worker(key, 0)
        {:ok, new_state}
      else
        true -> {{:error, :already_registered}, state}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:get, key, timeout}, _from, state) do
    key_entry = state.keys |> Map.get(key)

    {result, new_state} =
      with %{} <- key_entry,
           {:ok, value} <- get_value_from_store(state, key) do
        {{:ok, value}, state}
      else
        nil ->
          {{:error, :not_registered}, state}

        {:error, :not_found} ->
          result = wait_for_worker(key_entry.worker_task, timeout)
          new_state = set_state_for_worker_result(key, result, state)
          {result, new_state}
      end

    {:reply, result, new_state}
  end

  @impl true

  def handle_call({:quit, reason}, _from, state) do
    {:stop, reason, state}
  end

  @impl true
  def handle_cast({:start_worker, key}, state) do
    new_state =
      with key_entry <- state.keys |> Map.get(key),
           true <- key_entry != nil do
        supervisor = state.workers_supervisor

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            result = key_entry.worker.()
            {:worker_done, key, result}
          end)

        new_key_entry = key_entry |> Map.put(:worker_task, task)

        %{state | keys: state.keys |> Map.put(key, new_key_entry)}
      else
        _ -> state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:invalidate_key, key}, state) do
    new_state = %{state | keys: state.keys |> Map.delete(key)}
    delete_from_store(state, key)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({_ref, {:worker_done, key, result}}, state) do
    new_state = set_state_for_worker_result(key, result, state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_, state) do
    # Ignore all other Task mmessages
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    delete_store(state)
  end

  def set_state_for_worker_result(key, result, state) do
    key_entry = state.keys |> Map.get(key)

    new_key_entry =
      with {:ok, value} <- result do
        store_value(state, key, value)

        cancel_invalidator(key_entry.invalidator)

        invalidator = start_invalidator(key, key_entry.ttl)

        %{key_entry | invalidator: invalidator, worker_task: nil}
      else
        _ ->
          %{key_entry | worker_task: nil}
      end

    start_worker(key, key_entry.refresh_interval)

    new_state = %{state | keys: state.keys |> Map.put(key, new_key_entry)}

    new_state
  end

  defp start_worker(key, delay) do
    spawn(fn ->
      if delay > 0 do
        Process.sleep(delay)
      end

      GenServer.cast(__MODULE__, {:start_worker, key})
    end)
  end

  defp wait_for_worker(nil, _timeout), do: {:error, :timeout}

  defp wait_for_worker(task, timeout) do
    with {:ok, {:worker_done, _, {:ok, value}}} <- Task.yield(task, timeout) do
      {:ok, value}
    else
      _err ->
        {:error, :timeout}
    end
  end

  defp start_invalidator(key, ttl) do
    Process.send_after(self(), {:invalidate_key, key}, ttl)
  end

  defp cancel_invalidator(nil), do: nil

  defp cancel_invalidator(invalidator) do
    Process.cancel_timer(invalidator)
  end

  defp store_value(state, key, value) do
    apply(state.store.store_module, :store, [state.store.store, key, value])
  end

  defp get_value_from_store(state, key) do
    apply(state.store.store_module, :get, [state.store.store, key])
  end

  defp delete_from_store(state, key) do
    apply(state.store.store_module, :delete, [state.store.store, key])
  end

  defp delete_store(state) do
    apply(state.store.store_module, :delete_store, [state.store.store])
  end
end
