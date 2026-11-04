defmodule PipeMaestroRunner.Delivery do
  @moduledoc """
  Delivers a task's stage that passed (`PipeMaestroProtocol.Job`
  `delivery`), always the same way, whatever the agent did:

    1. commits what changed in the worktree, leaving out the paths the setup
       cloned (no commit when nothing changed);
    2. pushes the task's branch to `origin`;
    3. opens the task's draft pull request, or updates its title and body,
       and marks it ready when asked (the last stage);
    4. comments on the task's issue.

  Steps 3 and 4 use the GitHub CLI (`gh`, or `$GH_BIN`) with the credentials
  of whoever runs the runner. A step that fails is reported (`"error"`) and
  the ones that depend on it are skipped; nothing raises.
  """

  @doc """
  Delivers in the worktree `dir`, leaving `exclude` out of the commit.
  Options: `:gh` (the GitHub CLI's path) and `:env` (extra environment for
  git and gh). Returns `%{"commit", "pushed", "pr_url", "commented", "error"}`.
  """
  @spec deliver(Path.t(), map(), [String.t()], keyword()) :: map()
  def deliver(dir, delivery, exclude, opts \\ []) do
    ctx = %{dir: dir, gh: Keyword.get_lazy(opts, :gh, &gh/0), env: Keyword.get(opts, :env, [])}

    %{"commit" => nil, "pushed" => false, "pr_url" => nil, "commented" => false}
    |> step(fn report -> commit(ctx, delivery["commit_message"], exclude, report) end)
    |> step(fn report -> if delivery["push"], do: push(ctx, report), else: {:ok, report} end)
    |> step(fn report -> pull_request(ctx, delivery["pr"], report) end)
    |> step(fn report -> comment(ctx, delivery["issue_comment"], report) end)
  end

  # Each step either goes on or stops the ones after it with an error.
  defp step(%{"error" => _} = report, _fun), do: report

  defp step(report, fun) do
    case fun.(report) do
      {:ok, report} -> report
      {:error, message} -> Map.put(report, "error", message)
    end
  end

  defp commit(ctx, message, exclude, report) do
    pathspec = ["--", "." | Enum.map(exclude, &":(exclude)#{&1}")]

    with {:ok, _} <- git(ctx, ["add", "--all" | pathspec]),
         false <- match?({:ok, _}, git(ctx, ["diff", "--cached", "--quiet"])),
         {:ok, _} <- git(ctx, identity(ctx) ++ ["commit", "--quiet", "-m", message]),
         {:ok, sha} <- git(ctx, ["rev-parse", "HEAD"]) do
      {:ok, %{report | "commit" => String.trim(sha)}}
    else
      # Nothing staged: nothing to commit.
      true -> {:ok, report}
      {:error, output} -> {:error, "commit: #{output}"}
    end
  end

  # A machine without a git identity still commits, as the control plane.
  defp identity(ctx) do
    case git(ctx, ["config", "user.email"]) do
      {:ok, _email} ->
        []

      {:error, _none} ->
        ["-c", "user.name=PipeMaestro", "-c", "user.email=control-plane@localhost"]
    end
  end

  defp push(ctx, report) do
    case git(ctx, ["push", "--quiet", "--set-upstream", "origin", "HEAD"]) do
      {:ok, _} -> {:ok, %{report | "pushed" => true}}
      {:error, output} -> {:error, "push: #{output}"}
    end
  end

  defp pull_request(_ctx, nil, report), do: {:ok, report}

  defp pull_request(%{gh: nil}, _pr, _report),
    do: {:error, "pr: o GitHub CLI (gh) não está instalado neste runner"}

  defp pull_request(ctx, pr, report) do
    title = pr["title"]
    body = pr["body"] || ""

    result =
      case run(ctx, ctx.gh, ["pr", "view", "--json", "url", "-q", ".url"]) do
        {:ok, url} ->
          with {:ok, _} <- run(ctx, ctx.gh, ["pr", "edit", "--title", title, "--body", body]),
               do: {:ok, String.trim(url)}

        {:error, _none} ->
          with {:ok, output} <-
                 run(ctx, ctx.gh, ["pr", "create", "--draft", "--title", title, "--body", body]),
               do: {:ok, output |> String.split() |> List.last()}
      end

    with {:ok, url} <- result,
         {:ok, _} <- if(pr["ready"], do: run(ctx, ctx.gh, ["pr", "ready"]), else: {:ok, nil}) do
      {:ok, %{report | "pr_url" => url}}
    else
      {:error, output} -> {:error, "pr: #{output}"}
    end
  end

  defp comment(_ctx, nil, report), do: {:ok, report}

  defp comment(ctx, %{"url" => url, "body" => body}, report) do
    case ctx.gh && run(ctx, ctx.gh, ["issue", "comment", url, "--body", body]) do
      {:ok, _} -> {:ok, %{report | "commented" => true}}
      {:error, output} -> {:error, "comentário na issue: #{output}"}
      nil -> {:error, "comentário na issue: o GitHub CLI (gh) não está instalado neste runner"}
    end
  end

  defp gh, do: System.get_env("GH_BIN") || System.find_executable("gh")

  defp git(ctx, args), do: run(ctx, "git", ["-C", ctx.dir | args])

  defp run(ctx, command, args) do
    case System.cmd(command, args, cd: ctx.dir, env: ctx.env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
