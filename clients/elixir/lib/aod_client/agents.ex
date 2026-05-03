defmodule AodClient.Agents do
  alias AodClient.Api

  def list(client), do: Api.get(client, "/agents")
  def get(client, id), do: Api.get(client, "/agents/#{id}")
  def create(client, fields), do: Api.post(client, "/agents", Map.new(fields))
  def update(client, id, fields), do: Api.put(client, "/agents/#{id}", Map.new(fields))
  def delete(client, id), do: Api.delete(client, "/agents/#{id}")
end
