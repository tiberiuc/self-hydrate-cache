defmodule CacheTest do
  use ExUnit.Case, async: false

  setup_all do
    Cache.start_link()
    :ok
  end

  defp start_mock_service() do
    {:ok, pid} = Agent.start(fn -> 1 end)
    pid
  end

  defp get_from_mock_service(pid) do
    Agent.get_and_update(pid, &{&1, &1 + 1})
  end

  test "should register a new function and populate data after registration" do
    fun = fn -> {:ok, :done} end

    assert :ok = Cache.register_function(fun, :new_key, 100_000, 1000)
    assert {:ok, :done} = Cache.get(:new_key, 900)
  end

  test "should not register an existing function" do
    fun = fn -> {:ok, 1} end

    assert :ok = Cache.register_function(fun, :existing_key, 100_000, 1000)

    assert {:error, :already_registered} =
             Cache.register_function(fun, :existing_key, 100_000, 1000)
  end

  test "should send {:error, :not_registered} for unknown keys" do
    assert {:error, :not_registered} = Cache.get(:not_existing_key, 100)
  end

  test "should auto re-compute value after refresh interval" do
    service = start_mock_service()

    fun = fn ->
      value = get_from_mock_service(service)
      {:ok, value}
    end

    assert :ok = Cache.register_function(fun, :auto_key, 100_000, 1000)

    assert {:ok, 1} = Cache.get(:auto_key, 400)
    Process.sleep(1200)
    assert {:ok, 2} = Cache.get(:auto_key, 400)
  end

  test "should send last value after an {:error, reason} in refresh function" do
    service = start_mock_service()

    fun = fn ->
      value = get_from_mock_service(service)

      if value == 2 do
        {:error, :no_reason}
      else
        {:ok, value}
      end
    end

    assert :ok = Cache.register_function(fun, :error_key, 100_000, 1000)

    assert {:ok, 1} = Cache.get(:error_key, 400)
    Process.sleep(1200)
    assert {:ok, 1} = Cache.get(:error_key, 400)
    Process.sleep(1200)
    assert {:ok, 3} = Cache.get(:error_key, 400)
  end

  test "should sent {:error, :timeout} if key is not stored and computation is in progress but does not finish in timeout" do
    fun = fn ->
      Process.sleep(2000)
      {:ok, 1}
    end

    assert :ok = Cache.register_function(fun, :timeout_key, 100_000, 1000)

    assert {:error, :timeout} = Cache.get(:timeout_key, 400)
  end

  test "should not crash when refresh function raise an error" do
    service = start_mock_service()

    fun = fn ->
      value = get_from_mock_service(service)

      if value == 2 do
        raise "--- TEST --- Huge error"
      else
        {:ok, value}
      end
    end

    assert :ok = Cache.register_function(fun, :raise_error_key, 100_000, 1000)

    assert :ok =
             Cache.register_function(
               fn -> {:ok, "my second value"} end,
               :second_key,
               10_000,
               1000
             )

    assert {:ok, 1} = Cache.get(:raise_error_key, 400)
    Process.sleep(1200)
    assert {:ok, 1} = Cache.get(:raise_error_key, 400)
    assert {:ok, "my second value"} = Cache.get(:second_key, 400)
  end

  test "should expire a key after ttl" do
    service = start_mock_service()

    fun = fn ->
      value = get_from_mock_service(service)

      if value == 1 do
        {:ok, value}
      else
        {:error, :unknown}
      end
    end

    assert :ok = Cache.register_function(fun, :expire_key, 3000, 1000)

    assert {:ok, 1} = Cache.get(:expire_key, 400)
    Process.sleep(4000)
    assert {:error, :not_registered} = Cache.get(:expire_key, 400)
  end
end
