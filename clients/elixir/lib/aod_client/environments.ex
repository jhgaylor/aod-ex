defmodule AodClient.Environments do
  alias AodClient.Api

  def list(client), do: Api.get(client, "/environments")
  def get(client, id), do: Api.get(client, "/environments/#{id}")
  def create(client, fields), do: Api.post(client, "/environments", Map.new(fields))
  def update(client, id, fields), do: Api.put(client, "/environments/#{id}", Map.new(fields))
  def delete(client, id), do: Api.delete(client, "/environments/#{id}")

  def add_secret(client, env_id, key, value),
    do: Api.post(client, "/environments/#{env_id}/secrets", %{key: key, value: value})

  def remove_secret(client, env_id, key),
    do: Api.delete(client, "/environments/#{env_id}/secrets/#{key}")
end
