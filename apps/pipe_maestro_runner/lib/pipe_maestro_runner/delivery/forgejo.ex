defmodule PipeMaestroRunner.Delivery.Forgejo do
  @moduledoc """
  The pull request and the issue comment of a delivery
  (`PipeMaestroRunner.Delivery`) on a Forgejo (or Gitea), through its API.

  - **Draft:** a draft is a title starting with `"WIP: "`, Forgejo's own
    convention. Marking it ready is dropping the prefix.
  - **Text:** an open pull request of the branch is adopted, whoever opened
    it; only the platform's block of its description and the draft prefix
    change (`PipeMaestroRunner.Delivery.PrText`).
  - **Credentials:** the same ones `git push` uses for the host
    (`git credential fill`, never prompting), or a `FORGEJO_TOKEN` in the
    environment (a workspace secret).
  """

  alias PipeMaestroRunner.Delivery.PrText

  @draft_prefix "WIP: "
  @page_size 50
  @max_pages 10

  @typedoc "A repository on a Forgejo: its API base and how to sign in."
  @type repo :: %{api: String.t(), host: String.t(), auth: auth()}

  @type auth :: {:basic, String.t(), String.t()} | {:token, String.t()} | nil

  @doc """
  The repository behind `origin_url` (`https://host/owner/name(.git)`,
  `git@host:owner/name.git` or `ssh://...`), when its host answers as a
  Forgejo or Gitea (`/api/v1/version`, asked signed in: a private instance
  answers nobody else); `:not_forgejo` for GitHub, a local path or anything
  else. Options: `:auth` (`credentials/3`, given the host) and `:api_base`
  (instead of `https://<host>`, for tests).
  """
  @spec repo(String.t(), keyword()) :: {:ok, repo()} | :not_forgejo
  def repo(origin_url, opts \\ []) do
    with {:ok, host, path} <- parse(origin_url),
         false <- host == "github.com",
         base = opts[:api_base] || "https://#{host}",
         auth = auth_for(opts[:auth], host),
         true <- forgejo?(base, auth) do
      {:ok, %{api: "#{base}/api/v1/repos/#{path}", host: host, auth: auth}}
    else
      _other -> :not_forgejo
    end
  end

  defp auth_for(fun, host) when is_function(fun, 1), do: fun.(host)
  defp auth_for(_none, _host), do: nil

  @doc "The host and `owner/name` of a remote URL."
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse(url) do
    url = String.trim(url)

    case Regex.run(~r{^(?:https?|ssh)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+?)(?:\.git)?/?$}, url) do
      [_, host, path] ->
        owner_name(host, path)

      nil ->
        case Regex.run(~r{^[^@/\s]+@([^:/]+):(.+?)(?:\.git)?/?$}, url) do
          [_, host, path] -> owner_name(host, path)
          nil -> :error
        end
    end
  end

  defp owner_name(host, path) do
    case String.split(path, "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, String.downcase(host), path}
      _other -> :error
    end
  end

  defp forgejo?(base, auth) do
    case Req.get(base <> "/api/v1/version", [headers: auth_header(auth)] ++ request_options()) do
      {:ok, %Req.Response{status: 200, body: %{"version" => _}}} -> true
      _other -> false
    end
  end

  @doc """
  Signs in to `host` as `git push` does (`git credential fill` in `dir`), or
  with `FORGEJO_TOKEN` from `env`.
  """
  @spec credentials(String.t(), Path.t(), [{String.t(), String.t()}]) :: auth()
  def credentials(host, dir, env) do
    case credential_fill(host, dir, env) do
      {:ok, user, password} ->
        {:basic, user, password}

      :none ->
        token = List.keyfind(env, "FORGEJO_TOKEN", 0, {nil, System.get_env("FORGEJO_TOKEN")})

        case elem(token, 1) do
          token when token in [nil, ""] -> nil
          token -> {:token, token}
        end
    end
  end

  defp credential_fill(host, dir, env) do
    script = ~s(printf 'protocol=https\\nhost=%s\\n\\n' "$1" | git -C "$2" credential fill)
    env = [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_ASKPASS", "true"} | env]

    case System.cmd("sh", ["-c", script, "sh", host, dir], env: env, stderr_to_stdout: false) do
      {output, 0} ->
        fields =
          for line <- String.split(output, "\n"),
              [key, value] <- [String.split(line, "=", parts: 2)],
              into: %{},
              do: {key, value}

        if fields["password"] in [nil, ""],
          do: :none,
          else: {:ok, fields["username"] || "", fields["password"]}

      _no_credential ->
        :none
    end
  end

  @doc """
  Opens the pull request of `branch` (a draft, titled `title`, with `block`
  as its description), or adopts the open one and writes `block` in its
  description; with `ready`, without the draft prefix. Returns its URL.
  """
  @spec pull_request(repo(), String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, String.t()}
  def pull_request(repo, branch, title, block, ready) do
    with {:ok, %{"default_branch" => base}} <- request(repo, :get, ""),
         {:ok, pr} <-
           find_or_create(
             repo,
             base,
             branch,
             PrText.title(title, not ready, @draft_prefix),
             block
           ),
         {:ok, pr} <- update(repo, pr, block, ready) do
      {:ok, pr["html_url"]}
    end
  end

  defp find_or_create(repo, base, branch, title, block) do
    case open_pull_request(repo, branch, 1) do
      {:ok, %{} = pr} ->
        {:ok, pr}

      {:ok, nil} ->
        with {:ok, pr} <-
               request(repo, :post, "/pulls", %{
                 title: title,
                 body: PrText.wrap(block),
                 head: branch,
                 base: base
               }),
             do: {:ok, Map.put(pr, "created", true)}

      {:error, message} ->
        {:error, message}
    end
  end

  # The open pull request whose head is `branch`. Searched page by page: a
  # branch name with a slash does not fit the API's /pulls/{base}/{head}.
  defp open_pull_request(_repo, _branch, page) when page > @max_pages, do: {:ok, nil}

  defp open_pull_request(repo, branch, page) do
    case request(repo, :get, "/pulls?state=open&limit=#{@page_size}&page=#{page}") do
      {:ok, [_ | _] = prs} ->
        case Enum.find(prs, &(get_in(&1, ["head", "ref"]) == branch)) do
          nil -> open_pull_request(repo, branch, page + 1)
          pr -> {:ok, pr}
        end

      {:ok, _empty} ->
        {:ok, nil}

      {:error, message} ->
        {:error, message}
    end
  end

  # An open pull request (the platform's, or one the agent opened) keeps its
  # title and the text outside the platform's block.
  defp update(_repo, %{"created" => true} = pr, _block, _ready), do: {:ok, pr}

  defp update(repo, pr, block, ready) do
    title = PrText.title(pr["title"] || "", not ready, @draft_prefix)
    body = PrText.body(pr["body"], block)

    if title == pr["title"] and body == pr["body"],
      do: {:ok, pr},
      else: request(repo, :patch, "/pulls/#{pr["number"]}", %{title: title, body: body})
  end

  @doc "Comments on the issue at `url` (`https://host/owner/name/issues/N`)."
  @spec comment(repo(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def comment(repo, url, body) do
    case Regex.run(~r{/issues/(\d+)/?$}, url) do
      [_, number] ->
        with {:ok, _} <- request(repo, :post, "/issues/#{number}/comments", %{body: body}),
             do: :ok

      nil ->
        {:error, "não é uma issue: #{url}"}
    end
  end

  defp request(repo, method, path, body \\ nil) do
    options =
      [method: method, url: repo.api <> path, headers: auth_header(repo.auth)] ++
        if(body, do: [json: body], else: []) ++ request_options()

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status} em #{path}: #{message(body)}"}

      {:error, exception} ->
        {:error, "#{path}: #{Exception.message(exception)}"}
    end
  end

  defp message(%{"message" => message}), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp message(body), do: inspect(body)

  defp auth_header({:basic, user, password}),
    do: [{"authorization", "Basic " <> Base.encode64("#{user}:#{password}")}]

  defp auth_header({:token, token}), do: [{"authorization", "token " <> token}]
  defp auth_header(nil), do: []

  defp request_options, do: [retry: false, redirect: false, receive_timeout: 15_000]
end
