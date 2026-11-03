defmodule ClaudeControlPlane.SecretsTest do
  use ClaudeControlPlane.DataCase, async: true

  import ClaudeControlPlane.Fixtures

  alias ClaudeControlPlane.{Repo, Secrets}
  alias ClaudeControlPlane.Secrets.Secret

  test "keeps secrets encrypted, lists only names, and gives them out as env" do
    workspace = workspace_fixture()

    assert {:ok, %Secret{name: "GRAFANA_TOKEN"}} =
             Secrets.put(workspace, "GRAFANA_TOKEN", "glsa_123")

    assert {:ok, _} = Secrets.put(workspace, "OUTRO", "x")
    assert {:ok, _} = Secrets.put(workspace, "GRAFANA_TOKEN", "glsa_456")

    assert Enum.map(Secrets.list(workspace), & &1.name) == ["GRAFANA_TOKEN", "OUTRO"]
    assert Secrets.env(workspace) == %{"GRAFANA_TOKEN" => "glsa_456", "OUTRO" => "x"}

    stored = Repo.get_by!(Secret, workspace_id: workspace.id, name: "GRAFANA_TOKEN")
    refute stored.encrypted_value =~ "glsa_456"

    assert :ok = Secrets.delete(workspace, "OUTRO")
    assert Map.keys(Secrets.env(workspace)) == ["GRAFANA_TOKEN"]
    assert Secrets.env(workspace_fixture()) == %{}
  end

  test "refuses names the runner needs or that are not variables, and empty values" do
    workspace = workspace_fixture()
    assert {:error, %{errors: [name: _]}} = Secrets.put(workspace, "PATH", "x")
    assert {:error, %{errors: [name: _]}} = Secrets.put(workspace, "minusculo", "x")
    assert {:error, %{errors: [value: _]}} = Secrets.put(workspace, "BOM", "")
  end
end
