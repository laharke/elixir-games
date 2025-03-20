defmodule Games do

    def main(_args) do
      loop()
    end

    defp loop do
      IO.puts("\nSelect a game to play:")
      IO.puts("1. Guessing Game")
      IO.puts("2. Rock Paper Scissors")
      IO.puts("3. Wordle")
      IO.puts("Type 'stop' to exit.")

      case IO.gets("> ") |> String.trim() do
        "1" -> Games.GuessingGame.play()
        "2" -> Games.RockPaperScissors.play()
        "3" -> Games.Wordle.play()
        "stop" -> IO.puts("Goodbye!") && System.halt(0)
        _ -> IO.puts("Invalid choice, please try again.")
      end

      unless String.downcase(IO.gets("\nPlay again? (y/n): ") |> String.trim()) == "n" do
        loop()
      end
    end
end


defmodule Games.RockPaperScissors do
  @choices [:rock, :paper, :scissors]

  @spec play() :: no_return()
  def play do
    ai_choice = Enum.random(@choices)
    user_choice = get_user_choice()

    IO.puts("AI Choice: #{ai_choice}")
    result = determine_winner(user_choice, ai_choice)
    IO.puts(result)
  end

  defp get_user_choice do
    IO.gets("Choose rock, paper, or scissors: ")
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  defp determine_winner(choice, choice), do: "It's a tie!"
  defp determine_winner(:rock, :scissors), do: "You win! rock beats scissors."
  defp determine_winner(:scissors, :paper), do: "You win! scissors beats paper."
  defp determine_winner(:paper, :rock), do: "You win! paper beats rock."
  defp determine_winner(_, _), do: "You lose!."
end



defmodule Games.GuessingGame do

  @spec play() :: no_return()
  def play do
    guess = IO.gets("Guess a nubmer between 1 and 10?\n") |> Integer.parse() |> elem(0)
    randomNumber = Enum.random(1..10)

    IO.inspect(randomNumber)
    checks(guess, randomNumber)

  end

  @spec play(integer()) :: String.t()
  def play(randomNumber) do
    guess = IO.gets("") |> Integer.parse() |> elem(0)
    IO.inspect(randomNumber)
    checks(guess, randomNumber)
  end

  @spec checks(integer(), integer()) :: String.t()
  def checks(guess, randomNumber) do
    if guess == randomNumber do
      IO.inspect("You win!")
    else

      indication =
      if guess > randomNumber do
        "Too high!"
      else
        "Too low!"
      end

      IO.inspect(indication)
      play(randomNumber)
    end
  end
end

defmodule Games.Wordle do

  @spec play() :: no_return()
  def play do
    word = Enum.random(["toast", "tarts", "hello", "beats"])
    IO.inspect(word)
    chances = 6
    play(word, chances)
  end

  @spec play(String.t(), 0) :: String.t()
  def play(word, 0) do
    IO.puts("Game over! The correct word was: #{word}")
  end

  @spec play(String.t(), integer()) :: String.t()
  def play(word, turn) do
    guess = IO.gets("Enter a five letter word:?\n")

    feedback_list = feedback(guess, word)
    IO.inspect(feedback_list)

    case Enum.all?(feedback_list, &(&1 == :green)) do
      true -> IO.puts("You won!")
      false ->
        IO.puts("Try again! Turns left: #{turn - 1}")
        play(word, turn - 1)
    end

  end


  #Feedback recibe dos string, una guess y una palabra y devuelve una atom list con los colores que corresponden
  @spec feedback(String.t(), String.t()) :: [atom()]
  def feedback(guess, word) do
    #Feedback va a recibir aaaaa, aaaab

    guess = guess |> String.trim() |> String.graphemes()
    word = word |> String.split("", trim: true)

    #Agarro los indices que son Grey
    greys = guess -- word

    greysIndexs = Enum.flat_map(greys, fn x ->
      guess
      |> Enum.with_index()
      |> Enum.filter(fn {letter, _} -> letter == x end)
      |> Enum.map(fn {_, index} -> index end)
    end)

    #Hardcodeo el range porque son 5 letter words siempre, si tiras un count podes usar otras palabras
    answer = Enum.map(0..4, fn i ->
      if Enum.at(guess, i) == Enum.at(word, i) do
        #answer2 = List.replace_at(answer, i, :green)
        :green
      else
        #Aca puedo poner osea si no estan en el mismo lugar puedo hacer un IF any else no esta y listo ya esta
        if Enum.member?(greysIndexs, i) do
          :grey
        else
          :yellow
        end
      end
    end)

    answer
  end



end
