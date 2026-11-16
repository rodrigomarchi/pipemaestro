defmodule PipeMaestroWeb.UserRegistrationController do
  @moduledoc """
  Creates the account of someone signing up on their own (ADR 0058); the form
  itself is `RegistrationLive`. A new account is signed in right away.
  """
  use PipeMaestroWeb, :controller

  alias PipeMaestro.Accounts
  alias PipeMaestroWeb.{RateLimit, UserAuth}

  @labels %{name: "nome", email: "e-mail", password: "senha"}

  @doc "Creates the account posted by the sign-up form and signs it in."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => params}) do
    with :ok <- RateLimit.check(:signup, {:ip, conn.remote_ip}),
         {:ok, user} <- Accounts.register_user(params) do
      conn
      |> put_flash(:info, "Conta criada! Agora dê um nome ao seu workspace.")
      |> UserAuth.log_in_user(user)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Não foi possível criar a conta: #{describe(changeset)}.")
        |> redirect(to: ~p"/signup?#{back_params(params)}")

      {:error, _retry_after} ->
        conn
        |> put_flash(:error, "Muitos cadastros deste endereço. Tente mais tarde.")
        |> redirect(to: ~p"/signup")
    end
  end

  defp describe(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{Map.get(@labels, field, field)} #{&1}")
    end)
    |> Enum.join("; ")
  end

  defp back_params(params) do
    [
      name: String.slice(params["name"] || "", 0, 120),
      email: String.slice(params["email"] || "", 0, 160)
    ]
  end
end
