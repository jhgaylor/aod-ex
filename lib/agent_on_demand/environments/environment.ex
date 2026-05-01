defmodule AgentOnDemand.Environments.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  alias AgentOnDemand.Environments.Secret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @networking ~w(unrestricted limited)

  schema "environments" do
    field :name, :string
    field :packages, :map, default: %{}
    field :env_vars, :map, default: %{}
    field :setup_script, :string, default: ""
    field :networking_type, :string, default: "unrestricted"
    field :networking_config, :map, default: %{}
    field :repositories, {:array, :map}, default: []
    has_many :secrets, Secret
    timestamps(type: :utc_datetime)
  end

  def changeset(env, attrs) do
    env
    |> cast(attrs, [
      :name,
      :packages,
      :env_vars,
      :setup_script,
      :networking_type,
      :networking_config,
      :repositories
    ])
    |> validate_required([:name])
    |> validate_inclusion(:networking_type, @networking)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_change(:repositories, &validate_repositories/2)
    |> unique_constraint(:name)
  end

  defp validate_repositories(_field, list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"url" => url, "mount_path" => mount}
      when is_binary(url) and is_binary(mount) and url != "" and mount != "" ->
        if String.starts_with?(mount, "/") and String.starts_with?(url, "https://") do
          []
        else
          [repositories: "url must be https:// and mount_path must be absolute"]
        end

      _ ->
        [repositories: "each entry needs `url` (https://...) and `mount_path` (/abs/path)"]
    end)
  end

  defp validate_repositories(_, _), do: []
end
