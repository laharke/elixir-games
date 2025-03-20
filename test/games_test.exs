defmodule GamesTest do
  use ExUnit.Case
  doctest Games

  test "greets the world" do
    assert Games.hello() == :world, "Esto es hello world test skere"
  end

  describe "worlde/1" do
    test "All  Green" do
      assert Games.Wordle.feedback("ABCDE", "ABCDE") == [:green, :green, :green, :green, :green]
    end

    test "All  Yellow" do
      assert Games.Wordle.feedback("ABDCE", "EDCBA") == [:yellow, :yellow, :yellow, :yellow, :yellow]
    end

    test "All  Grey" do
      assert Games.Wordle.feedback("ABCDE", "JKLNO") == [:grey, :grey, :grey, :grey, :grey]
    end

    test "All  Colors" do
      assert Games.Wordle.feedback("ABCDE", "ABJED") == [:green, :green, :grey, :yellow, :yellow]
    end

  end


end
