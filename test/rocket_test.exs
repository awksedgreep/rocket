defmodule RocketTest do
  use ExUnit.Case
  doctest Rocket

  test "greets the world" do
    assert Rocket.hello() == :world
  end
end
