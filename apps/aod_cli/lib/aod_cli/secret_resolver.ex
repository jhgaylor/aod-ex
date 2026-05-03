defmodule AodCli.SecretResolver do
  @moduledoc """
  Behaviour for resolving an external secret reference at apply time.

  Each resolver is bound to a URI prefix (`op://`, `bws://`, etc.).
  Apply walks `spec.secrets` values, finds the resolver whose prefix
  matches, and replaces the value with whatever the resolver returns.

  Implementations:

    * `AodCli.OnePassword` — `op://<vault>/<item>/<field>`
    * `AodCli.Bitwarden`   — `bws://<secret-uuid>`

  Add a third by writing a module that implements this behaviour and
  registering it in `AodCli.SecretResolvers`.
  """

  @doc "URI prefix this resolver claims, e.g. `\"op://\"`."
  @callback prefix() :: String.t()

  @doc """
  Resolve `ref` to plaintext.

  Errors should be returned as `{:error, term}`; the term is later
  passed to `format_error/1` for display.
  """
  @callback read(ref :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Render an error term for the apply CLI's failure dump."
  @callback format_error(term()) :: String.t()
end
