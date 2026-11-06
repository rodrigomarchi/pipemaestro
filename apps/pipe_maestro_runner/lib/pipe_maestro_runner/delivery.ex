defmodule PipeMaestroRunner.Delivery do
  @moduledoc """
  Delivers a task's stage that passed (`PipeMaestroProtocol.Job`
  `delivery`), after the platform's checks (`PipeMaestroRunner.Checks`) and
  the gates. The runner never commits: what the stage did is in the commits
  the agent made, and the checks made sure nothing was left out. Then:

    1. pushes the task's branch to `origin` (HEAD, which the checks found on
       the task's branch and holding what origin has: a fast-forward, or
       nothing to do when the agent already pushed);
    2. opens the task's draft pull request, or adopts the open one, writing
       only the platform's block of its description
       (`PipeMaestroProtocol.PrText`), and marks it ready when asked
       (the last stage);
    3. comments on the task's issue.

  Steps 2 and 3 go where the repository lives:

  - **Forgejo or Gitea** (the `origin` host answers its API): through the API,
    signed in as `git push` is (`PipeMaestroRunner.Delivery.Forgejo`). A
    draft is a `"WIP: "` title.
  - **GitHub, or anything else:** the GitHub CLI (`gh`, or `$GH_BIN`), with
    the credentials of whoever runs the runner.

  A step that fails is reported (`"error"`) and the ones that depend on it are
  skipped; nothing raises.
  """

  alias PipeMaestroProtocol.PrText
  alias PipeMaestroRunner.Delivery.Forgejo

  @doc """
  Delivers in the worktree `dir`. Options: `:gh` (the GitHub CLI's path),
  `:env` (extra environment for git, gh and the Forgejo credentials) and
  `:forgejo_api_base` (the Forgejo API's base URL instead of
  `https://<host>`, for tests). Returns `%{"commit", "pushed", "pr_url",
  "commented", "error"}`, `"commit"` being the commit delivered.
  """
  @spec deliver(Path.t(), map(), keyword()) :: map()
  def deliver(dir, delivery, opts \\ []) do
    ctx = %{
      dir: dir,
      gh: Keyword.get_lazy(opts, :gh, &gh/0),
      env: Keyword.get(opts, :env, []),
      forgejo_api_base: opts[:forgejo_api_base]
    }

    %{"commit" => head(ctx), "pushed" => false, "pr_url" => nil, "commented" => false}
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

  defp head(ctx) do
    case git(ctx, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> String.trim(sha)
      {:error, _none} -> nil
    end
  end

  defp push(ctx, report) do
    case git(ctx, ["push", "--quiet", "--set-upstream", "origin", "HEAD"]) do
      {:ok, _} -> {:ok, %{report | "pushed" => true}}
      {:error, output} -> {:error, "push: #{output}"}
    end
  end

  defp pull_request(_ctx, nil, report), do: {:ok, report}

  defp pull_request(ctx, pr, report) do
    case origin_forgejo(ctx) do
      {:ok, repo} -> forgejo_pull_request(ctx, repo, pr, report)
      :not_forgejo -> github_pull_request(ctx, pr, report)
    end
  end

  defp forgejo_pull_request(ctx, repo, pr, report) do
    with {:ok, branch} <- git(ctx, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, url} <-
           Forgejo.pull_request(
             repo,
             String.trim(branch),
             pr["title"],
             pr["block"] || "",
             pr["ready"] == true
           ) do
      {:ok, %{report | "pr_url" => url}}
    else
      {:error, output} -> {:error, "pr: #{output}"}
    end
  end

  defp github_pull_request(%{gh: nil}, _pr, _report),
    do: {:error, "pr: o GitHub CLI (gh) não está instalado neste runner"}

  defp github_pull_request(ctx, pr, report) do
    block = pr["block"] || ""

    result =
      case run(ctx, ctx.gh, ["pr", "view", "--json", "url", "-q", ".url"]) do
        {:ok, url} -> update_github_pr(ctx, String.trim(url), block)
        {:error, _none} -> create_github_pr(ctx, pr["title"], block)
      end

    with {:ok, url} <- result,
         {:ok, _} <- if(pr["ready"], do: run(ctx, ctx.gh, ["pr", "ready"]), else: {:ok, nil}) do
      {:ok, %{report | "pr_url" => url}}
    else
      {:error, output} -> {:error, "pr: #{output}"}
    end
  end

  # The branch's open pull request, whoever opened it: only the platform's
  # block of its description changes.
  defp update_github_pr(ctx, url, block) do
    with {:ok, body} <- run(ctx, ctx.gh, ["pr", "view", "--json", "body", "-q", ".body"]),
         {:ok, _} <- edit_github_body(ctx, String.trim_trailing(body, "\n"), block),
         do: {:ok, url}
  end

  defp edit_github_body(ctx, body, block) do
    case PrText.body(body, block) do
      ^body -> {:ok, nil}
      new_body -> run(ctx, ctx.gh, ["pr", "edit", "--body", new_body])
    end
  end

  defp create_github_pr(ctx, title, block) do
    args = ["pr", "create", "--draft", "--title", title, "--body", PrText.wrap(block)]

    with {:ok, output} <- run(ctx, ctx.gh, args),
         do: {:ok, output |> String.split() |> List.last()}
  end

  defp comment(_ctx, nil, report), do: {:ok, report}

  defp comment(ctx, %{"url" => url, "body" => body}, report) do
    result =
      case issue_forgejo(ctx, url) do
        {:ok, repo} -> with :ok <- Forgejo.comment(repo, url, body), do: {:ok, nil}
        :not_forgejo -> github_comment(ctx, url, body)
      end

    case result do
      {:ok, _} -> {:ok, %{report | "commented" => true}}
      {:error, output} -> {:error, "comentário na issue: #{output}"}
    end
  end

  defp github_comment(%{gh: nil}, _url, _body),
    do: {:error, "o GitHub CLI (gh) não está instalado neste runner"}

  defp github_comment(ctx, url, body),
    do: run(ctx, ctx.gh, ["issue", "comment", url, "--body", body])

  # The remote as configured, before any insteadOf rewriting.
  defp origin_forgejo(ctx) do
    case git(ctx, ["config", "--get", "remote.origin.url"]) do
      {:ok, url} -> forgejo(ctx, String.trim(url))
      {:error, _none} -> :not_forgejo
    end
  end

  defp issue_forgejo(ctx, url) do
    case Regex.run(~r{^(https?://[^/]+/[^/]+/[^/]+)/issues/\d+/?$}, url) do
      [_, repository] -> forgejo(ctx, repository)
      nil -> :not_forgejo
    end
  end

  defp forgejo(ctx, url) do
    Forgejo.repo(url,
      api_base: ctx.forgejo_api_base,
      auth: &Forgejo.credentials(&1, ctx.dir, ctx.env)
    )
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
