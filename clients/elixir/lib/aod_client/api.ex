defmodule AodClient.Api do
  @moduledoc false
  # Internal: HTTP wrapper that all resource modules call into.

  alias AodClient

  def get(client, path), do: request(client, :get, path, nil)
  def post(client, path, body \\ nil), do: request(client, :post, path, body)
  def put(client, path, body), do: request(client, :put, path, body)
  def delete(client, path), do: request(client, :delete, path, nil)

  defp request(%AodClient{} = client, method, path, body) do
    opts = [method: method, url: path]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(client.req, opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, unwrap(resp.body)}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp unwrap(%{"data" => data}), do: data
  defp unwrap(other), do: other
end
