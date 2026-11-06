defmodule PipeMaestro.Integrations.Labels do
  @moduledoc """
  The platform's labels on a linked repository, under its prefix
  (`docs/specs/integracoes.md`, section 5): the trigger's own and one per
  state of the task the issue became.
  """

  alias PipeMaestro.Tasks.Task

  @states [
    {"triando", "fbca04", "O PipeMaestro está triando a issue"},
    {"em-andamento", "1d76db", "Uma tarefa do PipeMaestro está rodando"},
    {"aguardando-decisao", "d93f0b", "A tarefa espera uma decisão de alguém"},
    {"pronto", "0e8a16", "O pull request está pronto para revisão"},
    {"cancelada", "cccccc", "A tarefa foi cancelada"}
  ]

  @doc "Every label of the prefix: `%{name, color, description}`."
  @spec defaults(String.t()) :: [%{name: String.t(), color: String.t(), description: String.t()}]
  def defaults(prefix) do
    [%{name: prefix, color: "5319e7", description: "Pede ao PipeMaestro para trabalhar na issue"}] ++
      for {state, color, description} <- @states,
          do: %{name: "#{prefix}:#{state}", color: color, description: description}
  end

  @doc "The state labels of the prefix, which replace one another."
  @spec state_labels(String.t()) :: [String.t()]
  def state_labels(prefix), do: for({state, _, _} <- @states, do: "#{prefix}:#{state}")

  @doc "The state label for a task in `status` (`:triaging` before there is a task)."
  @spec for_status(String.t(), Task.status() | :triaging) :: String.t() | nil
  def for_status(prefix, status) do
    case status do
      s when s in [:triaging, :queued] -> "#{prefix}:triando"
      :running -> "#{prefix}:em-andamento"
      :awaiting_decision -> "#{prefix}:aguardando-decisao"
      :succeeded -> "#{prefix}:pronto"
      :canceled -> "#{prefix}:cancelada"
      _other -> nil
    end
  end
end
