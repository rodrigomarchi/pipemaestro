defmodule PipeMaestro.Tasks.Engine do
  @moduledoc """
  The gate between stages: given how a stage's job ended, what happens next.
  Pure, so the pipeline's transitions read in one place:

    * `:passed` — the job succeeded, answered `status: "ok"`, wrote its
      artifact and met its gates.
    * `{:paused, reason}` — the same, but one of the stage's rules matched the
      structured output, or the runner's delivery (commit, push, pull request)
      failed: a person decides how to go on.
    * `{:blocked, reason}` — the agent answered `status: "bloqueado"`: it needs
      a person, so there is no retry.
    * `{:retry, error}` — something went wrong (the CLI failed, no structured
      output, no artifact, a gate not met) and the stage has attempts left.
    * `{:exhausted, error}` — the same, with no attempts left.
    * `:canceled` — the job was canceled.
  """

  alias PipeMaestro.Jobs.Job
  alias PipeMaestro.Pipelines.Stage

  @type outcome ::
          :passed
          | :canceled
          | {:paused, String.t()}
          | {:blocked, String.t()}
          | {:retry, String.t()}
          | {:exhausted, String.t()}

  @doc "The outcome of attempt `attempt` of `stage`, run as `job`."
  @spec gate(Job.t(), Stage.t(), pos_integer()) :: outcome()
  def gate(%Job{status: :canceled}, _stage, _attempt), do: :canceled

  def gate(%Job{} = job, %Stage{} = stage, attempt) do
    case check(job) do
      :passed -> delivered(job) || rules(job.structured_output, stage.rules)
      {:blocked, reason} -> {:blocked, reason}
      {:error, error} when attempt < stage.max_attempts -> {:retry, error}
      {:error, error} -> {:exhausted, error}
    end
  end

  defp check(%Job{status: :succeeded, structured_output: %{"status" => "bloqueado"} = output}),
    do: {:blocked, output["resumo"] || "O agente pediu uma decisão sem dizer o motivo."}

  defp check(
         %Job{status: :succeeded, structured_output: %{"status" => "ok"}, artifact: artifact} =
           job
       )
       when is_binary(artifact) and artifact != "" do
    case Enum.find(job.gates || [], &(&1["passed"] == false)) do
      nil -> :passed
      gate -> {:error, gate_error(gate)}
    end
  end

  defp check(%Job{status: :succeeded, structured_output: %{"status" => "ok"}} = job),
    do: {:error, "A etapa terminou sem escrever o artefato #{job.context["artifact_path"]}."}

  defp check(%Job{status: :succeeded}),
    do: {:error, "A etapa terminou sem a saída estruturada (status e resumo)."}

  defp check(%Job{} = job), do: {:error, job.error || "A execução da etapa falhou."}

  defp gate_error(%{"command" => command, "expect" => "pass", "exit_code" => code}),
    do: "O gate `#{command}` não foi atendido: esperava passar e saiu com código #{code}."

  defp gate_error(%{"command" => command}),
    do: "O gate `#{command}` não foi atendido: esperava falhar e passou."

  # The stage met everything, but the runner could not commit, push or open
  # the pull request: going on would end the task with nothing delivered.
  defp delivered(%Job{delivery: %{"error" => error}}) when is_binary(error) do
    error = error |> String.split() |> Enum.join(" ") |> String.slice(0, 300)
    {:paused, "a entrega da plataforma falhou (#{error})"}
  end

  defp delivered(_job), do: nil

  defp rules(output, rules) do
    case rule_pause(output, rules) do
      nil -> :passed
      reason -> {:paused, reason}
    end
  end

  @doc "Why one of `rules` pauses on `output`, or `nil` when none matches."
  @spec rule_pause(map() | nil, [map()] | nil) :: String.t() | nil
  def rule_pause(output, rules) do
    case Enum.find(rules || [], &matches?(&1, output)) do
      nil -> nil
      rule -> "a regra #{rule["field"]} #{rule["op"]} #{rule["value"]} se aplicou"
    end
  end

  defp matches?(%{"field" => field, "op" => op, "value" => value}, output) when is_map(output) do
    equal = Map.has_key?(output, field) and to_string(output[field]) == value
    if op == "==", do: equal, else: Map.has_key?(output, field) and not equal
  end

  defp matches?(_rule, _output), do: false

  @doc """
  What the next attempt of a stage is told about the one that failed: the
  error, what the agent said it did, and the output of the gates not met.
  """
  @spec feedback(String.t() | nil, String.t() | nil, [map()] | nil) :: String.t()
  def feedback(error, summary, gates) do
    failed =
      for %{"passed" => false} = gate <- gates || [] do
        "Saída de `#{gate["command"]}` (código #{gate["exit_code"]}):\n#{tail(gate["output"])}"
      end

    [
      error && "Erro: #{error}",
      summary && "O que a tentativa disse ter feito: #{summary}"
      | failed
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp tail(nil), do: ""
  defp tail(output) when byte_size(output) <= 2_000, do: output
  defp tail(output), do: "…" <> binary_part(output, byte_size(output) - 2_000, 2_000)
end
