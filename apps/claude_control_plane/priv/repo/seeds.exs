# Development data: an operator, two workspaces, their users and the
# ready-made pipelines.
#
#     mix run priv/repo/seeds.exs
#
# Safe to run again: existing records are kept.

alias ClaudeControlPlane.{Accounts, Backoffice, Pipelines, Workspaces}

password = "senha-de-dev-123"

operator =
  Backoffice.list_operators() |> Enum.find(&(&1.email == "operador@local.test")) ||
    elem(
      Backoffice.create_operator(%{
        email: "operador@local.test",
        name: "Operador Local",
        password: password
      }),
      1
    )

workspace = fn name, slug ->
  Enum.find(Workspaces.list_workspaces(), &(&1.slug == slug)) ||
    elem(Workspaces.create_workspace(%{name: name, slug: slug}), 1)
end

user = fn email, name ->
  Accounts.get_user_by_email(email) ||
    elem(Accounts.create_user(%{email: email, name: name, password: password}), 1)
end

acme = workspace.("Acme Engineering", "acme")
globex = workspace.("Globex", "globex")
ana = user.("ana@acme.dev", "Ana Lima")
bruno = user.("bruno@acme.dev", "Bruno Costa")

for {ws, member} <- [{acme, ana}, {acme, bruno}, {globex, bruno}] do
  Workspaces.add_member(ws, member)
end

for ws <- [acme, globex], do: Pipelines.create_defaults(ws)

IO.puts("""

Dados de desenvolvimento (senha de todos: #{password})
  Backoffice  http://localhost:4000/backoffice/login   #{operator.email}
  App         http://localhost:4000/login              #{ana.email}   (1 workspace)
                                                       #{bruno.email} (2 workspaces)
""")
