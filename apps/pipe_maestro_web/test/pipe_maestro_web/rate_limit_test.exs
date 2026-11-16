defmodule PipeMaestroWeb.RateLimitTest do
  use ExUnit.Case, async: true

  alias PipeMaestroWeb.RateLimit

  defp sweep do
    send(RateLimit, :sweep)
    :sys.get_state(RateLimit)
  end

  defp entries(key), do: :ets.match_object(RateLimit, {{key, :_}, :_, :_})

  test "a sweep keeps the windows still open" do
    key = {:sweep_test, make_ref()}

    assert :ok = RateLimit.hit(key, 1, :timer.hours(1))
    assert {:error, _} = RateLimit.hit(key, 1, :timer.hours(1))

    sweep()

    assert {:error, _} = RateLimit.hit(key, 1, :timer.hours(1))
  end

  test "a sweep drops the windows that ended" do
    key = {:sweep_test, make_ref()}

    assert :ok = RateLimit.hit(key, 1, 1)
    Process.sleep(5)
    sweep()

    assert entries(key) == []
  end
end
