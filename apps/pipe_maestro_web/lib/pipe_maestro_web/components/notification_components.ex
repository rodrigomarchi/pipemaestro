defmodule PipeMaestroWeb.NotificationComponents do
  @moduledoc """
  The pieces of the notification center (`PipeMaestroWeb.NotificationCenter`)
  and of the notifications page (`PipeMaestroWeb.NotificationLive`): an item
  of the inbox, an execution under way, and the icon and color of each kind
  of notification.
  """
  use PipeMaestroWeb, :html

  alias PipeMaestro.Notifications.{Execution, Notification}
  alias PipeMaestroWeb.Markdown
  alias PipeMaestroWeb.RunnerComponents

  @doc """
  The icon and the color of a notification's kind. A kind this list does not
  know yet gets a generic bell.
  """
  @spec kind_style(atom()) :: {String.t(), String.t()}
  def kind_style(:task_awaiting_decision),
    do: {"hero-hand-raised", "text-warning-600 dark:text-warning-400"}

  def kind_style(:task_succeeded),
    do: {"hero-check-circle", "text-success-600 dark:text-success-400"}

  def kind_style(:task_failed), do: {"hero-x-circle", "text-danger-600 dark:text-danger-400"}
  def kind_style(:task_canceled), do: {"hero-no-symbol", "text-gray-500 dark:text-gray-400"}

  def kind_style(:proposal_ready),
    do: {"hero-light-bulb", "text-primary-600 dark:text-primary-400"}

  def kind_style(:proposal_failed),
    do: {"hero-exclamation-triangle", "text-danger-600 dark:text-danger-400"}

  def kind_style(_kind), do: {"hero-bell", "text-gray-500 dark:text-gray-400"}

  @doc "Where a notification leads: its task or its proposal."
  @spec path(String.t(), Notification.t()) :: String.t() | nil
  def path(slug, %Notification{task_id: task_id}) when is_binary(task_id),
    do: ~p"/w/#{slug}/tasks/#{task_id}"

  def path(slug, %Notification{job_id: job_id}) when is_binary(job_id),
    do: ~p"/w/#{slug}/proposals/#{job_id}"

  def path(slug, %Notification{}), do: ~p"/w/#{slug}/notifications"

  @doc "The test id of a notification: what it is about and its kind."
  @spec testid(Notification.t()) :: String.t()
  def testid(%Notification{} = n) do
    kind = n.kind |> to_string() |> String.replace("_", "-")
    "notifications-item-#{n.task_id || n.job_id || n.id}-#{kind}"
  end

  @doc """
  One notification: icon, title, its body in short, when, and whether it is
  unread. A click sends `event` with the notification's id to `target`.
  """
  attr :notification, Notification, required: true
  attr :event, :string, default: "open"
  attr :target, :any, default: nil

  @spec notification_item(map()) :: Phoenix.LiveView.Rendered.t()
  def notification_item(assigns) do
    {icon, color} = kind_style(assigns.notification.kind)

    assigns =
      assign(assigns, icon: icon, color: color, unread: is_nil(assigns.notification.read_at))

    ~H"""
    <li role="listitem">
      <button
        type="button"
        phx-click={@event}
        phx-value-id={@notification.id}
        phx-target={@target}
        data-testid={testid(@notification)}
        data-unread={to_string(@unread)}
        class={[
          "flex w-full gap-3 rounded-lg px-3 py-3 text-left transition hover:bg-gray-100 focus-visible:outline-2 focus-visible:outline-primary-500 dark:hover:bg-gray-800",
          @unread && "bg-primary-50/60 dark:bg-primary-950/30"
        ]}
      >
        <.icon name={@icon} class={["mt-0.5 size-5 shrink-0", @color]} />
        <span class="min-w-0 flex-1">
          <span class="flex items-start gap-2">
            <span class={[
              "min-w-0 flex-1 text-sm text-gray-900 dark:text-gray-100",
              @unread && "font-semibold"
            ]}>
              {@notification.title}
            </span>
            <span
              :if={@unread}
              class="mt-1.5 size-2 shrink-0 rounded-full bg-primary-500"
              aria-hidden="true"
            ></span>
            <span :if={@unread} class="sr-only">não lida</span>
          </span>
          <span
            :if={@notification.body}
            class="prose prose-sm mt-1 line-clamp-2 block max-w-none text-gray-600 dark:prose-invert dark:text-gray-400"
          >
            {Markdown.to_html(@notification.body)}
          </span>
          <span class="mt-1 block text-xs text-gray-500 dark:text-gray-400">
            <span
              id={"notification-time-#{@notification.id}"}
              phx-hook="Elapsed"
              data-since={DateTime.to_iso8601(@notification.inserted_at)}
              data-format="ago"
            >
              {RunnerComponents.time_ago(@notification.inserted_at)}
            </span>
          </span>
        </span>
      </button>
    </li>
    """
  end

  @doc """
  The inbox with nothing in it (the panel and the page): the same empty state
  as the other screens' (`<.empty>`), saying what fills it.
  """
  attr :unread_only, :boolean, default: false

  @spec empty_inbox(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_inbox(assigns) do
    ~H"""
    <.empty
      data-testid="notifications-empty-inbox"
      title={if @unread_only, do: "Nenhuma notificação não lida", else: "Nenhuma notificação"}
      description="Quando uma tarefa pausar ou terminar, ou uma proposta ficar pronta, ela aparece aqui."
    >
      <:icon><.icon name="hero-inbox" /></:icon>
    </.empty>
    """
  end

  @doc "Nothing under way: the same empty state as the other screens, with a way to start one."
  attr :slug, :string, required: true

  @spec empty_active(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_active(assigns) do
    ~H"""
    <.empty
      data-testid="notifications-empty-active"
      title="Nada rodando agora"
      description="Quando uma tarefa ou proposta começar, ela aparece aqui com etapa, runner e tempo."
    >
      <:icon><.icon name="hero-moon" /></:icon>
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/w/#{@slug}/tasks"}
          size="sm"
          icon="hero-plus"
          data-testid="notifications-empty-active-create"
        >
          Criar uma tarefa
        </.button>
      </:actions>
    </.empty>
    """
  end

  @doc "How long something has been going: \"3 min 12 s\"."
  @spec elapsed(DateTime.t() | nil, DateTime.t()) :: String.t()
  def elapsed(since, now \\ DateTime.utc_now())
  def elapsed(nil, _now), do: ""

  def elapsed(%DateTime{} = since, now) do
    seconds = max(DateTime.diff(now, since), 0)

    cond do
      seconds < 60 -> "#{seconds} s"
      seconds < 3_600 -> "#{div(seconds, 60)} min #{rem(seconds, 60)} s"
      true -> "#{div(seconds, 3_600)} h #{div(rem(seconds, 3_600), 60)} min"
    end
  end

  @doc "One execution under way: title, stage, runner, who started it and for how long."
  attr :execution, Execution, required: true
  attr :slug, :string, required: true

  @spec execution_item(map()) :: Phoenix.LiveView.Rendered.t()
  def execution_item(assigns) do
    ~H"""
    <li role="listitem" data-testid={"notifications-active-item-#{@execution.id}"}>
      <.link
        navigate={execution_path(@slug, @execution)}
        class="block rounded-lg px-3 py-3 transition hover:bg-gray-100 focus-visible:outline-2 focus-visible:outline-primary-500 dark:hover:bg-gray-800"
      >
        <span class="flex items-start gap-2">
          <span class="min-w-0 flex-1 truncate text-sm font-medium text-gray-900 dark:text-gray-100">
            {@execution.title}
          </span>
          <span
            class="shrink-0 text-xs tabular-nums text-gray-500 dark:text-gray-400"
            id={"execution-elapsed-#{@execution.id}"}
            phx-hook="Elapsed"
            data-since={@execution.started_at && DateTime.to_iso8601(@execution.started_at)}
            data-format="elapsed"
          >
            {elapsed(@execution.started_at)}
          </span>
        </span>
        <span class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-gray-600 dark:text-gray-400">
          <.badge size="xs" color={status_color(@execution.status)} dot>
            {status_label(@execution.status)}
          </.badge>
          <span :if={@execution.type == :task}>
            etapa {@execution.stage} de {@execution.stage_count}
          </span>
          <span :if={@execution.type == :proposal}>proposta · {@execution.proposal_kind}</span>
          <span :if={@execution.runner_name} class="inline-flex items-center gap-1">
            <.icon name="hero-server-stack" class="size-3.5" /> {@execution.runner_name}
          </span>
          <span :if={@execution.creator_name} class="inline-flex items-center gap-1">
            <.icon name="hero-user" class="size-3.5" /> {@execution.creator_name}
          </span>
        </span>
      </.link>
    </li>
    """
  end

  defp status_label(:running), do: "Rodando"
  defp status_label(:awaiting_decision), do: "Aguardando decisão"
  defp status_label(:queued), do: "Na fila"

  defp status_color(:running), do: "info"
  defp status_color(:awaiting_decision), do: "warning"
  defp status_color(:queued), do: "gray"

  defp execution_path(slug, %Execution{type: :task, id: id}), do: ~p"/w/#{slug}/tasks/#{id}"

  defp execution_path(slug, %Execution{type: :proposal, id: id}),
    do: ~p"/w/#{slug}/proposals/#{id}"
end
