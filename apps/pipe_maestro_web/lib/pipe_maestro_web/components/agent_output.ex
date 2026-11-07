defmodule PipeMaestroWeb.AgentOutput do
  @moduledoc """
  What an agent answered at the end of a run, shown for a person to read. The
  answer is either Markdown or JSON (a stage's structured output:
  `{"status": "ok", "resumo": "..."}`). JSON objects become their fields, in
  the agent's order: the status as a badge, text as Markdown, a list of texts
  as a list, anything else as indented JSON. Anything else is Markdown.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestroWeb.Markdown

  @typedoc "An answer, read: an object's fields, other JSON indented, or Markdown."
  @type parsed ::
          {:fields, [{String.t(), term()}]} | {:json, String.t()} | {:markdown, String.t()}

  @doc """
  Reads an answer: a JSON object as its fields in order, a JSON array as
  indented JSON, any other text as Markdown.
  """
  @spec parse(String.t()) :: parsed()
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    with true <- String.starts_with?(trimmed, ["{", "["]),
         {:ok, decoded} <- Jason.decode(trimmed, objects: :ordered_objects) do
      case decoded do
        %Jason.OrderedObject{values: values} -> {:fields, values}
        other -> {:json, pretty(other)}
      end
    else
      _not_json -> {:markdown, text}
    end
  end

  @doc "An answer, read with `parse/1` and shown accordingly."
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  @spec agent_output(map()) :: Phoenix.LiveView.Rendered.t()
  def agent_output(assigns) do
    assigns = assign(assigns, :parsed, parse(assigns.text))

    ~H"""
    <div id={@id} phx-hook="Highlight" class={@class} data-format={elem(@parsed, 0)} {@rest}>
      <.parsed parsed={@parsed} />
    </div>
    """
  end

  attr :parsed, :any, required: true

  defp parsed(%{parsed: {:markdown, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class={prose()}>{Markdown.to_html(@text)}</div>
    """
  end

  defp parsed(%{parsed: {:json, json}} = assigns) do
    assigns = assign(assigns, :json, json)

    ~H"""
    <.json_block json={@json} />
    """
  end

  defp parsed(%{parsed: {:fields, fields}} = assigns) do
    {status, rest} = split_status(fields)
    assigns = assign(assigns, status: status, fields: rest)

    ~H"""
    <div class="space-y-3">
      <.badge
        :if={@status}
        size="sm"
        variant="soft"
        color={status_color(@status)}
        label={@status}
        data-testid="agent-output-status"
      />
      <div :for={{key, value} <- @fields} data-testid={"agent-output-field-#{key}"}>
        <p class="mb-1 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
          {label(key)}
        </p>
        <.value value={value} />
      </div>
    </div>
    """
  end

  attr :value, :any, required: true

  defp value(%{value: text} = assigns) when is_binary(text) do
    ~H"""
    <div class={prose()}>{Markdown.to_html(@value)}</div>
    """
  end

  defp value(%{value: nil} = assigns) do
    ~H"""
    <p class="text-sm text-gray-500 dark:text-gray-400">—</p>
    """
  end

  defp value(%{value: scalar} = assigns) when is_number(scalar) or is_boolean(scalar) do
    ~H"""
    <p class="font-mono text-sm text-gray-900 dark:text-white">{to_string(@value)}</p>
    """
  end

  defp value(%{value: []} = assigns) do
    ~H"""
    <p class="text-sm text-gray-500 dark:text-gray-400">Nenhum.</p>
    """
  end

  defp value(%{value: [_ | _] = items} = assigns) when is_list(items) do
    if Enum.all?(items, &is_binary/1) do
      ~H"""
      <ul class="list-disc space-y-1 pl-5 text-sm text-gray-900 dark:text-gray-100">
        <li :for={item <- @value}>{Markdown.inline_html(item)}</li>
      </ul>
      """
    else
      assigns = assign(assigns, :json, pretty(items))

      ~H"""
      <.json_block json={@json} />
      """
    end
  end

  defp value(assigns) do
    assigns = assign(assigns, :json, pretty(assigns.value))

    ~H"""
    <.json_block json={@json} />
    """
  end

  attr :json, :string, required: true

  defp json_block(assigns) do
    ~H"""
    <pre class="max-h-96 overflow-auto rounded-lg bg-gray-50 px-3 py-2 text-xs dark:bg-gray-950"><code class="language-json text-gray-800 dark:text-gray-100">{@json}</code></pre>
    """
  end

  defp prose,
    do:
      "prose prose-sm max-w-none dark:prose-invert prose-h1:text-lg prose-h2:text-base prose-h3:text-sm"

  defp split_status(fields) do
    case List.keytake(fields, "status", 0) do
      {{"status", status}, rest} when is_binary(status) -> {status, rest}
      _none -> {nil, fields}
    end
  end

  defp status_color(status) when status in ~w(ok sucesso concluido concluído), do: "success"
  defp status_color(status) when status in ~w(bloqueado pendente), do: "warning"
  defp status_color(status) when status in ~w(erro falhou falha), do: "danger"
  defp status_color(_status), do: "gray"

  defp label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp pretty(value), do: Jason.encode!(value, pretty: true)
end
